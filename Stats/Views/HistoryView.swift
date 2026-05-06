//
//  HistoryView.swift
//  Stats
//
//  SwiftUI surface for the History window. Renders aggregate charts from
//  DB.shared.findTimeSeries plus rolled-up top-process lists.
//
//  Decoding strategy: rather than depending on each module's Codable
//  payload type (some are internal, all of them carry more fields than we
//  need), we decode the JSON values as JSONValue or as small local mirror
//  structs that pull only the fields we plot.
//

import SwiftUI
import Kit

#if canImport(Charts)
import Charts
#endif

// MARK: - Time range

struct HistoryRange: Hashable, Identifiable {
    let label: String
    let minutes: Int
    var id: Int { minutes }

    static let all: [HistoryRange] = [
        .init(label: "5m",  minutes: 5),
        .init(label: "1h",  minutes: 60),
        .init(label: "6h",  minutes: 360),
        .init(label: "24h", minutes: 1440),
        .init(label: "7d",  minutes: 10080),
    ]
}

// MARK: - Mirror structs

private struct CPULoadMirror: Codable {
    let totalUsage: Double?
    let idleLoad: Double?
}

private struct RAMUsageMirror: Codable {
    struct Pressure: Codable { let value: String? }
    let used: Double?
    let total: Double?
    let pressure: Pressure?
}

private struct BatteryMirror: Codable {
    let level: Double?
    let isCharging: Bool?
    let health: Int?
    let timeToEmpty: Int?
}

private struct NetUsageMirror: Codable {
    struct Bandwidth: Codable { let download: Int?; let upload: Int? }
    let bandwidth: Bandwidth?
}

private struct FreqMirror: Codable {
    let value: Double?
    let pCore: Double?
    let eCore: Double?
}

private struct ProcSampleMirror: Codable {
    let name: String?
    let pid: Int?
    let usage: Double?
}

private struct NetProcMirror: Codable {
    let name: String?
    let pid: Int?
    let download: Int?
    let upload: Int?
}

// MARK: - Sample types for charts

struct ChartPoint: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
}

struct ProcessRow: Identifiable {
    let id = UUID()
    let name: String
    let primary: Double
    let secondary: Double?

    init(name: String, primary: Double, secondary: Double? = nil) {
        self.name = name; self.primary = primary; self.secondary = secondary
    }
}

// MARK: - Snapshot loaded for a given range

private struct HistorySnapshot {
    var cpuLoad:  [ChartPoint] = []
    var ramUsed:  [ChartPoint] = []
    var ramTotal: Double = 0
    var ramPressure: String = "—"
    var battery:  [ChartPoint] = []
    var batteryCharging: Bool = false
    var batteryHealth: Int = 0
    var temperature: [ChartPoint] = []
    var frequency:   [ChartPoint] = []
    var freqP: Double = 0
    var freqE: Double = 0
    var netDown: [ChartPoint] = []
    var netUp:   [ChartPoint] = []
    var topCPU:  [ProcessRow] = []
    var topRAM:  [ProcessRow] = []
    var topNet:  [ProcessRow] = []
    var generatedAt: Date = Date()
    var prefixCount: Int = 0
}

private enum HistoryLoader {
    static func load(rangeMinutes: Int) -> HistorySnapshot {
        let now = Int(Date().timeIntervalSince1970)
        let since = now - rangeMinutes * 60
        var snap = HistorySnapshot()

        snap.cpuLoad = decodeSeries(prefix: "CPU@LoadReader", since: since, type: CPULoadMirror.self) {
            ($0.totalUsage ?? 0) * 100
        }
        snap.ramUsed = decodeSeries(prefix: "RAM@UsageReader", since: since, type: RAMUsageMirror.self) {
            ($0.used ?? 0) / 1_073_741_824 // bytes -> GiB
        }
        if let last = decodeLatest(prefix: "RAM@UsageReader", type: RAMUsageMirror.self) {
            snap.ramTotal = (last.total ?? 0) / 1_073_741_824
            snap.ramPressure = last.pressure?.value ?? "—"
        }

        snap.battery = decodeSeries(prefix: "Battery@UsageReader", since: since, type: BatteryMirror.self) {
            ($0.level ?? 0) * 100
        }
        if let last = decodeLatest(prefix: "Battery@UsageReader", type: BatteryMirror.self) {
            snap.batteryCharging = last.isCharging ?? false
            snap.batteryHealth = last.health ?? 0
        }

        snap.temperature = decodeSeries(prefix: "CPU@TemperatureReader", since: since, type: Double.self) { $0 }

        snap.frequency = decodeSeries(prefix: "CPU@FrequencyReader", since: since, type: FreqMirror.self) {
            ($0.value ?? 0) / 1000  // MHz -> GHz
        }
        if let last = decodeLatest(prefix: "CPU@FrequencyReader", type: FreqMirror.self) {
            snap.freqP = (last.pCore ?? 0) / 1000
            snap.freqE = (last.eCore ?? 0) / 1000
        }

        let net = decodeSeries(prefix: "Network@UsageReader", since: since, type: NetUsageMirror.self) { _ in 0.0 }
            // We need both download/upload separately, so re-run with custom mapping.
        _ = net
        let netRaw = DB.shared.findTimeSeries(prefix: "Network@UsageReader", since: since)
        var dn: [ChartPoint] = []; var up: [ChartPoint] = []
        for entry in netRaw {
            guard let data = entry.json.data(using: .utf8),
                  let v = try? JSONDecoder().decode(NetUsageMirror.self, from: data) else { continue }
            let t = Date(timeIntervalSince1970: TimeInterval(entry.ts))
            dn.append(.init(time: t, value: Double(v.bandwidth?.download ?? 0)))
            up.append(.init(time: t, value: Double(v.bandwidth?.upload ?? 0)))
        }
        snap.netDown = dn; snap.netUp = up

        snap.topCPU = topProcessesByPeak(prefix: "CPU@ProcessReader", since: since, n: 10) {
            ProcSampleMirror(name: $0.name, pid: $0.pid, usage: $0.usage)
        }
        snap.topRAM = topProcessesByPeak(prefix: "RAM@ProcessReader", since: since, n: 10) {
            ProcSampleMirror(name: $0.name, pid: $0.pid, usage: $0.usage)
        }
        snap.topNet = topNetByDelta(since: since, n: 10)

        snap.prefixCount = DB.shared.listPrefixes().count
        snap.generatedAt = Date()
        return snap
    }

    // MARK: helpers

    private static func decodeSeries<T: Codable>(
        prefix: String, since: Int, type: T.Type, extract: (T) -> Double?
    ) -> [ChartPoint] {
        let raw = DB.shared.findTimeSeries(prefix: prefix, since: since)
        var out: [ChartPoint] = []
        out.reserveCapacity(raw.count)
        let dec = JSONDecoder()
        for entry in raw {
            guard let data = entry.json.data(using: .utf8) else { continue }
            do {
                let value = try dec.decode(T.self, from: data)
                if let n = extract(value), n.isFinite {
                    out.append(.init(time: Date(timeIntervalSince1970: TimeInterval(entry.ts)), value: n))
                }
            } catch {
                continue
            }
        }
        return out
    }

    private static func decodeLatest<T: Codable>(prefix: String, type: T.Type) -> T? {
        guard let entry = DB.shared.findLatestTimeSeries(prefix: prefix),
              let data = entry.json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func topProcessesByPeak(
        prefix: String, since: Int, n: Int,
        extract: (ProcSampleMirror) -> ProcSampleMirror
    ) -> [ProcessRow] {
        let raw = DB.shared.findTimeSeries(prefix: prefix, since: since)
        var peaks: [String: Double] = [:]
        for entry in raw {
            guard let data = entry.json.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([ProcSampleMirror].self, from: data) else { continue }
            for p in arr {
                guard let name = p.name, let v = p.usage else { continue }
                if let cur = peaks[name] { if v > cur { peaks[name] = v } }
                else { peaks[name] = v }
            }
        }
        return peaks
            .map { ProcessRow(name: $0.key, primary: $0.value) }
            .sorted { $0.primary > $1.primary }
            .prefix(n)
            .map { $0 }
    }

    private static func topNetByDelta(since: Int, n: Int) -> [ProcessRow] {
        let raw = DB.shared.findTimeSeries(prefix: "Network@ProcessReader", since: since)
        // first/last by (pid|name), then aggregate by name.
        struct Key: Hashable { let pid: Int; let name: String }
        var first: [Key: NetProcMirror] = [:]
        var last:  [Key: NetProcMirror] = [:]
        for entry in raw {
            guard let data = entry.json.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([NetProcMirror].self, from: data) else { continue }
            for p in arr {
                guard let name = p.name, let pid = p.pid else { continue }
                let k = Key(pid: pid, name: name)
                if first[k] == nil { first[k] = p }
                last[k] = p
            }
        }
        struct Agg { var dn: Double = 0; var up: Double = 0 }
        var byName: [String: Agg] = [:]
        for (k, b) in last {
            let a = first[k] ?? b
            let dn = max(0, Double((b.download ?? 0) - (a.download ?? 0)))
            let up = max(0, Double((b.upload   ?? 0) - (a.upload   ?? 0)))
            var cur = byName[k.name] ?? Agg()
            cur.dn += dn; cur.up += up
            byName[k.name] = cur
        }
        return byName
            .map { (name, agg) in ProcessRow(name: name, primary: agg.dn, secondary: agg.up) }
            .sorted { ($0.primary + ($0.secondary ?? 0)) > ($1.primary + ($1.secondary ?? 0)) }
            .prefix(n)
            .map { $0 }
    }
}

// Allow JSONDecoder().decode(Double.self, from:) for the temperature reader.
extension Double {
    static func _decoded(from json: String) -> Double? {
        guard let d = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Double.self, from: d)
    }
}

// MARK: - The view itself

@available(macOS 13.0, *)
struct HistoryRootView: View {
    @State private var range: HistoryRange = HistoryRange.all[1] // 1h
    @State private var snapshot: HistorySnapshot = HistorySnapshot()
    @State private var loading = false
    @State private var auto = true
    @State private var refreshTask: Task<Void, Never>? = nil

    private static let bytesFmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .binary; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 600), spacing: 16)],
                          alignment: .leading, spacing: 16) {
                    chartCard("CPU usage", points: snapshot.cpuLoad,
                              latest: snapshot.cpuLoad.last.map { String(format: "%.1f%%", $0.value) } ?? "—",
                              tint: .blue, yFormat: pctFormatter)
                    chartCard("RAM used", points: snapshot.ramUsed,
                              latest: snapshot.ramUsed.last.map { String(format: "%.1f / %.0f GB · %@",
                                                                          $0.value, snapshot.ramTotal, snapshot.ramPressure) } ?? "—",
                              tint: .green, yFormat: gbFormatter)
                    netCard
                    chartCard("Battery", points: snapshot.battery,
                              latest: snapshot.battery.last.map {
                                  String(format: "%.0f%% · health %d%%%@", $0.value, snapshot.batteryHealth,
                                         snapshot.batteryCharging ? " · charging" : "") } ?? "—",
                              tint: .purple, yFormat: pctFormatter)
                    chartCard("CPU temperature", points: snapshot.temperature,
                              latest: snapshot.temperature.last.map { String(format: "%.1f °C", $0.value) } ?? "—",
                              tint: .red, yFormat: tempFormatter)
                    chartCard("CPU frequency", points: snapshot.frequency,
                              latest: snapshot.frequency.last.map {
                                  String(format: "%.2f GHz · P %.2f · E %.2f",
                                         $0.value, snapshot.freqP, snapshot.freqE) } ?? "—",
                              tint: .cyan, yFormat: ghzFormatter)
                }
                .padding(16)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 600), spacing: 16)],
                          alignment: .leading, spacing: 16) {
                    processCard("Top processes — CPU", rows: snapshot.topCPU) {
                        String(format: "%.1f %%", $0.primary)
                    }
                    processCard("Top processes — RAM", rows: snapshot.topRAM) {
                        Self.bytesFmt.string(fromByteCount: Int64($0.primary))
                    }
                    processCard("Top processes — Network", rows: snapshot.topNet) {
                        let dn = Self.bytesFmt.string(fromByteCount: Int64($0.primary))
                        let up = Self.bytesFmt.string(fromByteCount: Int64($0.secondary ?? 0))
                        return "↓ \(dn)   ↑ \(up)"
                    }
                }
                .padding([.horizontal, .bottom], 16)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { reload(); startAuto() }
        .onDisappear { stopAuto() }
        .onChange(of: range) { _ in reload() }
        .onChange(of: auto) { v in if v { startAuto() } else { stopAuto() } }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Range", selection: $range) {
                ForEach(HistoryRange.all) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            Spacer()

            Text("\(snapshot.prefixCount) streams · \(Int(DB.shared.ttl / 86400))d retention")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Toggle("Auto", isOn: $auto)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: chart cards

    private func chartCard(
        _ title: String,
        points: [ChartPoint],
        latest: String,
        tint: Color,
        yFormat: NumberFormatter
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Text(latest)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Chart(points) { p in
                LineMark(x: .value("t", p.time), y: .value("v", p.value))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("t", p.time), y: .value("v", p.value))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let dv = v.as(Double.self) {
                            Text(yFormat.string(from: NSNumber(value: dv)) ?? "")
                        }
                    }
                }
            }
            .frame(height: 160)
            .chartPlotStyle { content in
                content.background(Color.clear)
            }
            .overlay {
                if points.isEmpty { emptyOverlay }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }

    private var netCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NETWORK THROUGHPUT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            let dn = snapshot.netDown.last?.value ?? 0
            let up = snapshot.netUp.last?.value ?? 0
            Text("\(Self.bytesFmt.string(fromByteCount: Int64(dn + up)))/s   ↓\(Self.bytesFmt.string(fromByteCount: Int64(dn)))   ↑\(Self.bytesFmt.string(fromByteCount: Int64(up)))")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Chart {
                ForEach(snapshot.netDown) { p in
                    LineMark(x: .value("t", p.time), y: .value("v", p.value), series: .value("kind", "down"))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                }
                ForEach(snapshot.netUp) { p in
                    LineMark(x: .value("t", p.time), y: .value("v", p.value), series: .value("kind", "up"))
                        .foregroundStyle(.pink)
                        .interpolationMethod(.monotone)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let dv = v.as(Double.self) {
                            Text(Self.bytesFmt.string(fromByteCount: Int64(dv)) + "/s")
                        }
                    }
                }
            }
            .frame(height: 160)
            .overlay {
                if snapshot.netDown.isEmpty && snapshot.netUp.isEmpty { emptyOverlay }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }

    private func processCard(_ title: String, rows: [ProcessRow], format: @escaping (ProcessRow) -> String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            if rows.isEmpty {
                Text("no samples in window")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.vertical, 12)
            } else {
                ForEach(rows) { row in
                    HStack {
                        Text(row.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 12)
                        Text(format(row))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .padding(.vertical, 4)
                    Divider().opacity(row.id == rows.last?.id ? 0 : 1)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }

    private var emptyOverlay: some View {
        Text("no samples in window").foregroundStyle(.secondary).font(.callout)
    }

    // MARK: lifecycle

    private func reload() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let snap = HistoryLoader.load(rangeMinutes: range.minutes)
            await MainActor.run {
                self.snapshot = snap
                self.loading = false
            }
        }
    }

    private func startAuto() {
        stopAuto()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                if auto { reload() }
            }
        }
    }

    private func stopAuto() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}

// MARK: - Formatters

private let pctFormatter: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal
    f.minimumFractionDigits = 0; f.maximumFractionDigits = 0
    f.positiveSuffix = "%"; f.negativeSuffix = "%"
    return f
}()
private let gbFormatter: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal
    f.minimumFractionDigits = 0; f.maximumFractionDigits = 1
    f.positiveSuffix = " GB"; f.negativeSuffix = " GB"
    return f
}()
private let tempFormatter: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal
    f.minimumFractionDigits = 0; f.maximumFractionDigits = 0
    f.positiveSuffix = "°"; f.negativeSuffix = "°"
    return f
}()
private let ghzFormatter: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal
    f.minimumFractionDigits = 1; f.maximumFractionDigits = 2
    f.positiveSuffix = " GHz"; f.negativeSuffix = " GHz"
    return f
}()
