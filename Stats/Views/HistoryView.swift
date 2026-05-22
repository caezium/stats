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
        .init(label: "30d", minutes: 43200),
        .init(label: "90d", minutes: 129600),
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

// Some Network@UsageReader rows are written in a flat shape (`{"upload":N,"download":N}`)
// instead of the live readers' nested `{"bandwidth":{...}}` shape — for example,
// rows imported from an external history source. This mirror decodes the flat case.
private struct NetUsageFlatMirror: Codable {
    let download: Int?
    let upload: Int?
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

/// Picks an x-axis label format and tick stride suited to the visible window.
/// Without this every chart used `.hour().minute()` regardless of range, so
/// the 24h and 7d views collapsed all labels to the same hour:minute. We also
/// pass the resulting tick count to AxisMarks so SwiftUI doesn't auto-pick
/// far-apart label slots that look empty on narrow ranges.
@available(macOS 13.0, *)
struct AxisStyle {
    let format: Date.FormatStyle
    let desiredCount: Int

    static func forRangeMinutes(_ rangeMinutes: Int) -> AxisStyle {
        switch rangeMinutes {
        case ..<60:
            // 5 m → labels every ~1 min, e.g. "14:32"
            return AxisStyle(format: .dateTime.hour().minute(), desiredCount: 5)
        case ..<(6 * 60):
            // 1h–6h → "14:30"
            return AxisStyle(format: .dateTime.hour().minute(), desiredCount: 5)
        case ..<(24 * 60):
            // 6h–24h → "14:00"
            return AxisStyle(format: .dateTime.hour(), desiredCount: 6)
        case ..<(8 * 24 * 60):
            // 24h–7d → "Mon 14" so the user can see day boundaries
            return AxisStyle(format: .dateTime.weekday(.abbreviated).day(), desiredCount: 5)
        case ..<(45 * 24 * 60):
            // 7d–30d → "May 4". Weekday gets noisy at this density.
            return AxisStyle(format: .dateTime.month(.abbreviated).day(), desiredCount: 6)
        default:
            // 30d+ → "May", "Jun", "Jul"
            return AxisStyle(format: .dateTime.month(.abbreviated), desiredCount: 4)
        }
    }
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

    /// Window the snapshot was loaded for, in unix seconds. Used as the chart's
    /// explicit x-domain so a single stray ts (e.g. ts=0 from a malformed key)
    /// can't pollute the visible range and collapse every label to midnight.
    /// Empty snapshot defaults to a tight window around "now" so the chart has
    /// somewhere to render before the first load completes.
    var windowSince: Date = Date().addingTimeInterval(-3600)
    var windowUntil: Date = Date()
}

private enum HistoryLoader {
    // Top-process tables used to be capped at 6h regardless of the chart's
    // selected range, because decoding every row across 30d/90d was costing
    // several seconds and freezing the UI. Stride-sampling solves the same
    // problem — we ask the DB for up to ~720 rows spread evenly across the
    // window, so the cost is bounded at every range while the top-N stays
    // representative. The cap is gone; `tableSince` now matches `since`.

    static func load(rangeMinutes: Int) -> HistorySnapshot {
        let now = Int(Date().timeIntervalSince1970)
        let since = now - rangeMinutes * 60
        // Charts and tables both run over the full selected window; the DB
        // layer caps work via seek-stride sampling.
        let tableSince = since
        var snap = HistorySnapshot()

        snap.cpuLoad = sampleSeries(prefix: "CPU@LoadReader", since: since, until: now, type: CPULoadMirror.self) {
            ($0.totalUsage ?? 0) * 100
        }
        snap.ramUsed = sampleSeries(prefix: "RAM@UsageReader", since: since, until: now, type: RAMUsageMirror.self) {
            ($0.used ?? 0) / 1_073_741_824 // bytes -> GiB
        }
        if let last = decodeLatest(prefix: "RAM@UsageReader", type: RAMUsageMirror.self) {
            snap.ramTotal = (last.total ?? 0) / 1_073_741_824
            snap.ramPressure = last.pressure?.value ?? "—"
        }

        snap.battery = sampleSeries(prefix: "Battery@UsageReader", since: since, until: now, type: BatteryMirror.self) {
            ($0.level ?? 0) * 100
        }
        if let last = decodeLatest(prefix: "Battery@UsageReader", type: BatteryMirror.self) {
            snap.batteryCharging = last.isCharging ?? false
            snap.batteryHealth = last.health ?? 0
        }

        snap.temperature = sampleSeries(prefix: "CPU@TemperatureReader", since: since, until: now, type: Double.self) { $0 }

        snap.frequency = sampleSeries(prefix: "CPU@FrequencyReader", since: since, until: now, type: FreqMirror.self) {
            ($0.value ?? 0) / 1000  // MHz -> GHz
        }
        if let last = decodeLatest(prefix: "CPU@FrequencyReader", type: FreqMirror.self) {
            snap.freqP = (last.pCore ?? 0) / 1000
            snap.freqE = (last.eCore ?? 0) / 1000
        }

        // Network usage chart: two value shapes coexist under the same prefix
        // (live `{bandwidth:{...}}` vs flat `{upload,download}` from the importer
        // and the Net readers' explicit insert), so we sample once and decode
        // each row against both shapes. Single pass — the previous implementation
        // ran the decode loop twice and discarded the first result.
        let netRaw = DB.shared.findTimeSeriesSampled(prefix: "Network@UsageReader", since: since, until: now)
        var dn: [ChartPoint] = []; var up: [ChartPoint] = []
        dn.reserveCapacity(netRaw.count)
        up.reserveCapacity(netRaw.count)
        let dec = JSONDecoder()
        for entry in netRaw {
            guard let data = entry.json.data(using: .utf8) else { continue }
            let dnVal: Int, upVal: Int
            if let flat = try? dec.decode(NetUsageFlatMirror.self, from: data),
               flat.download != nil || flat.upload != nil {
                dnVal = flat.download ?? 0
                upVal = flat.upload ?? 0
            } else if let v = try? dec.decode(NetUsageMirror.self, from: data), let bw = v.bandwidth {
                dnVal = bw.download ?? 0
                upVal = bw.upload ?? 0
            } else {
                continue
            }
            let t = Date(timeIntervalSince1970: TimeInterval(entry.ts))
            dn.append(.init(time: t, value: Double(dnVal)))
            up.append(.init(time: t, value: Double(upVal)))
        }
        snap.netDown = dn; snap.netUp = up

        snap.topCPU = topProcessesByPeak(prefix: "CPU@ProcessReader", since: tableSince, n: 10) {
            ProcSampleMirror(name: $0.name, pid: $0.pid, usage: $0.usage)
        }
        snap.topRAM = topProcessesByPeak(prefix: "RAM@ProcessReader", since: tableSince, n: 10) {
            ProcSampleMirror(name: $0.name, pid: $0.pid, usage: $0.usage)
        }
        snap.topNet = topNetByDelta(since: tableSince, n: 10)

        snap.prefixCount = DB.shared.listPrefixes().count
        snap.generatedAt = Date()
        snap.windowSince = Date(timeIntervalSince1970: TimeInterval(since))
        snap.windowUntil = Date(timeIntervalSince1970: TimeInterval(now))
        return snap
    }

    // MARK: helpers

    /// Stride-sampled series for a chart. The DB layer caps the row count via
    /// seek-stride sampling so wide ranges (24h, 7d) don't materialize 100k+
    /// JSON strings on the main thread. ~720 points per chart is well above
    /// what's distinguishable at typical chart widths.
    private static func sampleSeries<T: Codable>(
        prefix: String, since: Int, until: Int, type: T.Type, extract: (T) -> Double?
    ) -> [ChartPoint] {
        let raw = DB.shared.findTimeSeriesSampled(prefix: prefix, since: since, until: until)
        var out: [ChartPoint] = []
        out.reserveCapacity(raw.count)
        let dec = JSONDecoder()
        for entry in raw {
            guard let data = entry.json.data(using: .utf8) else { continue }
            guard let value = try? dec.decode(T.self, from: data),
                  let n = extract(value), n.isFinite else { continue }
            out.append(.init(time: Date(timeIntervalSince1970: TimeInterval(entry.ts)), value: n))
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
        // Stride-sampled so top-N works over 30d/90d windows without decoding
        // millions of JSON rows. Peak is a max-aggregate and stays meaningful
        // under sampling — a spike of >1% lasts long enough to hit one of the
        // ~720 sampled rows at any feasible range. The previous implementation
        // used `findTimeSeries` and a hard 6 h table cap, which made wide
        // ranges show "what was hot in the last 6 h" instead of in the range.
        let now = Int(Date().timeIntervalSince1970)
        let raw = DB.shared.findTimeSeriesSampled(prefix: prefix, since: since, until: now)
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
        // Stride-sampled (see `topProcessesByPeak`). For cumulative byte
        // counters the first/last delta is robust to sampling: missing a few
        // seconds at the window's edge is noise compared to the total. The
        // dict-shape (bucket-totals from the importer / tier rollups) sums
        // across samples — sampling under-counts proportionally but the
        // relative ranking between apps is preserved.
        let now = Int(Date().timeIntervalSince1970)
        let raw = DB.shared.findTimeSeriesSampled(prefix: "Network@ProcessReader", since: since, until: now)
        struct Agg { var dn: Double = 0; var up: Double = 0 }
        var byName: [String: Agg] = [:]

        // Two value shapes coexist under this prefix:
        //  1. Live writes from ProcessReader's auto-persist:
        //       [{"name":..., "pid":..., "download":N, "upload":N}, ...]
        //     These are cumulative-since-process-start, so we compute first/last
        //     deltas per (pid, name).
        //  2. Imported / aggregated rows: per-bucket totals already, shape is
        //       {"<name>": {"download":N, "upload":N}, ...}
        //     Each row is its own delta, so we just sum across rows.
        struct Key: Hashable { let pid: Int; let name: String }
        var first: [Key: NetProcMirror] = [:]
        var last:  [Key: NetProcMirror] = [:]

        for entry in raw {
            guard let data = entry.json.data(using: .utf8) else { continue }
            if let arr = try? JSONDecoder().decode([NetProcMirror].self, from: data) {
                for p in arr {
                    guard let name = p.name, let pid = p.pid else { continue }
                    let k = Key(pid: pid, name: name)
                    if first[k] == nil { first[k] = p }
                    last[k] = p
                }
            } else if let dict = try? JSONDecoder().decode([String: NetProcMirror].self, from: data) {
                for (name, p) in dict {
                    var cur = byName[name] ?? Agg()
                    cur.dn += Double(p.download ?? 0)
                    cur.up += Double(p.upload ?? 0)
                    byName[name] = cur
                }
            }
        }

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
    @State private var loadGen: Int = 0             // bumped each time a new load starts
    @State private var auto = true
    @State private var refreshTask: Task<Void, Never>? = nil
    @State private var loadTask: Task<Void, Never>? = nil

    private static let bytesFmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .binary; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 600), spacing: 18)],
                          alignment: .leading, spacing: 18) {
                    // Primary metric + secondary line model: every card answers
                    // "what is it right now?" in a single big number, with
                    // anything else as a quiet caption underneath. The chart
                    // is context for the number, not the headline.
                    chartCard(
                        "CPU usage",
                        points: snapshot.cpuLoad,
                        primary: snapshot.cpuLoad.last.map { String(format: "%.1f%%", $0.value) } ?? "—",
                        secondary: snapshot.cpuLoad.last.map { _ in "across all cores" },
                        tint: .blue, yFormat: pctFormatter,
                        emptyIcon: "cpu", emptyMessage: "No CPU samples yet"
                    )
                    chartCard(
                        "RAM used",
                        points: snapshot.ramUsed,
                        primary: snapshot.ramUsed.last.map { String(format: "%.1f GB", $0.value) } ?? "—",
                        secondary: snapshot.ramUsed.last.map { _ in
                            String(format: "of %.0f GB · pressure %@", snapshot.ramTotal, snapshot.ramPressure)
                        },
                        tint: .green, yFormat: gbFormatter,
                        emptyIcon: "memorychip", emptyMessage: "No RAM samples yet"
                    )
                    netCard
                    chartCard(
                        "Battery",
                        points: snapshot.battery,
                        primary: snapshot.battery.last.map { String(format: "%.0f%%", $0.value) } ?? "—",
                        secondary: snapshot.battery.last.map { _ in
                            "health \(snapshot.batteryHealth)%\(snapshot.batteryCharging ? " · charging" : "")"
                        },
                        tint: .purple, yFormat: pctFormatter,
                        emptyIcon: "bolt.slash", emptyMessage: "Power info unavailable"
                    )
                    chartCard(
                        "CPU temperature",
                        points: snapshot.temperature,
                        primary: snapshot.temperature.last.map { String(format: "%.1f°C", $0.value) } ?? "—",
                        secondary: nil,
                        tint: .red, yFormat: tempFormatter,
                        emptyIcon: "thermometer.medium", emptyMessage: "No temperature samples"
                    )
                    chartCard(
                        "CPU frequency",
                        points: snapshot.frequency,
                        primary: snapshot.frequency.last.map { String(format: "%.2f GHz", $0.value) } ?? "—",
                        secondary: snapshot.frequency.last.map { _ in
                            String(format: "P %.2f · E %.2f", snapshot.freqP, snapshot.freqE)
                        },
                        tint: .cyan, yFormat: ghzFormatter,
                        emptyIcon: "waveform.path", emptyMessage: "No frequency samples"
                    )
                }
                .padding(18)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 600), spacing: 18)],
                          alignment: .leading, spacing: 18) {
                    processCard("Top CPU", subtitle: "by peak %", rows: snapshot.topCPU) {
                        String(format: "%.1f%%", $0.primary)
                    }
                    processCard("Top RAM", subtitle: "by peak", rows: snapshot.topRAM) {
                        Self.bytesFmt.string(fromByteCount: Int64($0.primary))
                    }
                    processCard("Top network", subtitle: "by total transfer", rows: snapshot.topNet) {
                        let dn = Self.bytesFmt.string(fromByteCount: Int64($0.primary))
                        let up = Self.bytesFmt.string(fromByteCount: Int64($0.secondary ?? 0))
                        return "↓\(dn)  ↑\(up)"
                    }
                }
                .padding([.horizontal, .bottom], 18)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { reload(); startAuto() }
        .onDisappear { stopAuto() }
        .onChange(of: range) { _ in
            reload()
            // Re-arm the auto-refresh at the new range's cadence (5m wants
            // ~2 s, 7d wants ~60 s). Without this the refresh keeps ticking
            // at whatever cadence the last range picked.
            if auto { startAuto() }
        }
        .onChange(of: auto) { v in if v { startAuto() } else { stopAuto() } }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Picker("Range", selection: $range) {
                ForEach(HistoryRange.all) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            // Inline spinner: visible while a load is in flight so range
            // changes and refreshes feel acknowledged instead of frozen.
            // Width reserved when idle (opacity 0) so layout doesn't jump.
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .opacity(loading ? 1 : 0)
                .frame(width: 16)

            Spacer()

            // Relative "last updated" ticks every second via TimelineView so the
            // user has a live sense of data freshness without us re-running the
            // whole load. Reads `snapshot.generatedAt` which is set once per
            // successful load.
            TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                HStack(spacing: 10) {
                    Text(Self.relativeTimeShort(snapshot.generatedAt, now: ctx.date))
                        .monospacedDigit()
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(snapshot.prefixCount) streams")
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(Int(DB.shared.ttl / 86400))d retained")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)

            // Auto-refresh state shown as a subtle toggleable badge instead
            // of a checkbox — clearer at-a-glance, more native.
            Toggle(isOn: $auto) {
                HStack(spacing: 4) {
                    Image(systemName: auto ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .imageScale(.small)
                    Text(auto ? "Live" : "Paused")
                }
            }
            .toggleStyle(.button)
            .controlSize(.small)

            Button { reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// "just now" / "5s ago" / "12m ago". Lets the toolbar communicate freshness
    /// without overloading the user with a wall-clock timestamp they then have
    /// to mentally subtract from now.
    static func relativeTimeShort(_ then: Date, now: Date = Date()) -> String {
        let delta = max(0, Int(now.timeIntervalSince(then)))
        switch delta {
        case ..<3:   return "just now"
        case ..<60:  return "\(delta)s ago"
        case ..<3600:
            return "\(delta / 60)m ago"
        case ..<86400:
            return "\(delta / 3600)h ago"
        default:
            return "\(delta / 86400)d ago"
        }
    }

    // MARK: chart cards

    private func chartCard(
        _ title: String,
        points: [ChartPoint],
        primary: String,
        secondary: String?,
        tint: Color,
        yFormat: NumberFormatter,
        emptyIcon: String = "tray",
        emptyMessage: String = "No data in this window"
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Eyebrow label: small, all-caps, with a tint dot for at-a-glance
            // metric recognition (matches the chart line color below).
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
            }
            .padding(.bottom, 2)

            // Primary: the BIG number. Title2 + tabular nums so it reads as
            // the headline of the card, not a label inside it.
            Text(primary)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            // Secondary: quiet contextual line. Stable height (reserves room
            // even when nil) so cards don't jitter when data lands.
            Text(secondary ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.bottom, 6)

            let style = AxisStyle.forRangeMinutes(range.minutes)
            Chart(points) { p in
                LineMark(x: .value("t", p.time), y: .value("v", p.value))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("t", p.time), y: .value("v", p.value))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            // Pin the visible window to what the user asked for; without this
            // a single bad-ts row would stretch the implicit domain to 1970
            // and collapse every x-axis label to "00:00".
            .chartXScale(domain: snapshot.windowSince...snapshot.windowUntil)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: style.desiredCount)) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel(format: style.format, centered: false)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let dv = v.as(Double.self) {
                            Text(yFormat.string(from: NSNumber(value: dv)) ?? "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .frame(height: 140)
            .chartPlotStyle { content in
                content.background(Color.clear)
            }
            // Soft cue that the chart is stale during a load. Slow fade, not
            // a flash — matches the perceptual rhythm of the auto-refresh.
            .opacity(loading ? 0.55 : 1.0)
            .animation(.easeInOut(duration: 0.18), value: loading)
            .overlay {
                if points.isEmpty { gentleEmpty(icon: emptyIcon, message: emptyMessage) }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 0.5))
    }

    private var netCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(.orange).frame(width: 6, height: 6)
                Circle().fill(.pink).frame(width: 6, height: 6)
                Text("NETWORK THROUGHPUT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
            }
            .padding(.bottom, 2)

            let dn = snapshot.netDown.last?.value ?? 0
            let up = snapshot.netUp.last?.value ?? 0
            let total = dn + up

            // Primary: total throughput, big. Secondary: split per-direction
            // with proper arrows + tinted bullets. Reads at a glance instead
            // of the previous cramped "X KB/s ↓Y ↑Z" one-liner.
            Text("\(Self.bytesFmt.string(fromByteCount: Int64(total)))/s")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 12) {
                Label {
                    Text(Self.bytesFmt.string(fromByteCount: Int64(dn)))
                        .monospacedDigit()
                } icon: { Image(systemName: "arrow.down").foregroundStyle(.orange) }
                Label {
                    Text(Self.bytesFmt.string(fromByteCount: Int64(up)))
                        .monospacedDigit()
                } icon: { Image(systemName: "arrow.up").foregroundStyle(.pink) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)

            let style = AxisStyle.forRangeMinutes(range.minutes)
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
            .chartXScale(domain: snapshot.windowSince...snapshot.windowUntil)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: style.desiredCount)) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel(format: style.format)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let dv = v.as(Double.self) {
                            Text(Self.bytesFmt.string(fromByteCount: Int64(dv)) + "/s")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .frame(height: 140)
            .opacity(loading ? 0.55 : 1.0)
            .animation(.easeInOut(duration: 0.18), value: loading)
            .overlay {
                if snapshot.netDown.isEmpty && snapshot.netUp.isEmpty {
                    gentleEmpty(icon: "wifi.slash", message: "No network activity")
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 0.5))
    }

    private func processCard(_ title: String, subtitle: String, rows: [ProcessRow], format: @escaping (ProcessRow) -> String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title + subtitle eyebrow. The subtitle ("by peak %", "by total
            // transfer") makes it clear what the sort order means without
            // requiring the user to hover or guess.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 2)

            if rows.isEmpty {
                // Match the chart cards' gentle empty state — same icon
                // style, same height-ish reservation, so the layout doesn't
                // collapse when a column has no data.
                gentleEmpty(icon: "list.bullet", message: "No process activity")
                    .frame(height: 100)
            } else {
                // Rank index + name + value, tabular alignment. Numeric
                // column right-aligned with monospaced digits so they
                // visually stack into a column the eye can scan.
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                        HStack(spacing: 10) {
                            Text("\(idx + 1)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .frame(width: 16, alignment: .leading)
                            Text(row.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(format(row))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.callout)
                        .padding(.vertical, 6)
                        if row.id != rows.last?.id {
                            Divider().opacity(0.6)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 0.5))
    }

    /// A friendlier empty state: SF Symbol + short message in tertiary text.
    /// Replaces the old `Text("no samples in window")` which read as a
    /// debug log line and felt error-ish. Sized to sit comfortably inside
    /// a chart frame as an overlay or inside a process card as a panel.
    private func gentleEmpty(icon: String, message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: lifecycle

    /// `silent: true` skips toggling the visible loading state — used for the
    /// auto-refresh tick so it doesn't make the spinner flicker every few
    /// seconds. User-initiated reloads (button, range change, first appear)
    /// pass false so the spinner + chart-dim cue is visible.
    private func reload(silent: Bool = false) {
        // Switching ranges while a load is in flight used to be ignored
        // (`guard !loading else { return }`), which made the time-range
        // picker feel broken: the user clicks 7d, nothing visible happens
        // because the still-running 5m load owns the lock. Cancel-and-replace
        // instead, so each click owns the fresh load and stale results
        // silently lose the gen race when they try to land.
        loadTask?.cancel()
        let myGen = loadGen + 1
        loadGen = myGen
        if !silent { loading = true }
        let rangeMinutes = range.minutes
        loadTask = Task.detached(priority: .userInitiated) { [myGen] in
            let snap = HistoryLoader.load(rangeMinutes: rangeMinutes)
            if Task.isCancelled { return }
            await MainActor.run {
                // A newer load was kicked off while we were running. Drop our
                // result — the newer one will deliver the right snapshot.
                if myGen != self.loadGen { return }
                self.snapshot = snap
                self.loading = false
            }
        }
    }

    /// How often the auto-refresh should fire, scaled by the visible range.
    /// 5m and 1h views feel near-real-time; wider windows don't need to
    /// repeatedly re-decode tens of thousands of rows just to nudge the chart.
    private var autoRefreshInterval: TimeInterval {
        switch range.minutes {
        case ..<60:           return 2
        case ..<(6 * 60):     return 5
        case ..<(24 * 60):    return 15
        case ..<(8 * 24 * 60): return 60
        // 7d+ ranges don't visibly change in <5 min; idle the refresh
        // so we're not re-running stride scans over 90 days every minute.
        default:              return 300
        }
    }

    private func startAuto() {
        stopAuto()
        let interval = autoRefreshInterval
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                if auto { reload(silent: true) }
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
