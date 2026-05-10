//
//  DB.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 03/02/2024
//  Using Swift 5.0
//  Running on macOS 14.3
//
//  Copyright © 2024 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation

public class DB {
    public static let shared = DB()

    private var lldb: LLDB? = nil
    private let queue = DispatchQueue(label: "eu.exelban.db")

    // Retention is configurable via Store under "history_retention_days".
    // Default: 7 days. Used for both periodic pruning and import-time cleanup.
    public var ttl: Int {
        let days = Store.shared.int(key: "history_retention_days", defaultValue: 7)
        return max(1, days) * 24 * 60 * 60
    }

    public var _writeTS: [String: Date] = [:]
    public var writeTS: [String: Date] {
        get { self.queue.sync { self._writeTS } }
        set { self.queue.sync { self._writeTS = newValue } }
    }

    private var _values: [String: Codable] = [:]
    public var values: [String: Codable] {
        get { self.queue.sync { self._values } }
        set { self.queue.sync { self._values = newValue } }
    }

    private var pruneTimer: DispatchSourceTimer?

    init() {
        let fileManager = FileManager.default
        let supportPath = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Stats")
        let tmpPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Stats")

        try? fileManager.createDirectory(at: supportPath, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: tmpPath, withIntermediateDirectories: true, attributes: nil)

        var dbURL: URL?
        var tmpURL: URL?

        if let values = try? supportPath.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory ?? false {
            dbURL = supportPath.appendingPathComponent("lldb")
        }
        if let values = try? tmpPath.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory ?? false {
            tmpURL = tmpPath.appendingPathComponent("lldb")
        }
        if dbURL == nil && tmpURL != nil {
            dbURL = tmpURL
        }

        if let url = dbURL, let lldb = LLDB(url.path) {
            self.lldb = lldb
            self.scheduleBackgroundPrune()
            return
        }
        if let url = tmpURL, let lldb = LLDB(url.path) {
            self.lldb = lldb
            self.scheduleBackgroundPrune()
            return
        }

        print("ERROR INITIALIZE DB")
    }

    deinit {
        self.pruneTimer?.cancel()
        self.lldb?.close()
    }

    public func setup<T: Codable>(_ type: T.Type, _ key: String) {
        self.cleanPrefix(key)
        if let raw = self.lldb?.findOne(key), let value = try? JSONDecoder().decode(type, from: Data(raw.utf8)) {
            self.values[key] = value
        }
    }

    public func insert(key: String, value: Codable, ts: Bool = true, force: Bool = false) {
        self.values[key] = value
        guard let blobData = try? JSONEncoder().encode(value), let str = String(data: blobData, encoding: .utf8) else { return }

        if ts {
            self.lldb?.insert("\(key)@\(Date().currentTimeSeconds())", value: str)
        }

        if !force, let ts = self.writeTS[key], (Date().timeIntervalSince1970-ts.timeIntervalSince1970) < 30 { return }

        self.lldb?.insert(key, value: str)
        self.writeTS[key] = Date()
    }

    public func findOne<T: Decodable>(_ dynamicType: T.Type, key: String) -> T? {
        return self.values[key] as? T
    }

    // MARK: - Public time-series read API (used by QueryServer / MCP layer)

    /// Returns `(timestamp, raw JSON)` tuples for keys matching `<prefix>@<unix_seconds>`.
    /// `prefix` is normally `<module>@<reader>` (no trailing `@`).
    ///
    /// When `since`/`until` are provided, this uses a leveldb range scan bounded by
    /// `<prefix>@<since>` .. `<prefix>@<until>` so the cost is proportional to the
    /// returned window rather than the full prefix. This matters for high-volume
    /// time series like `Net@UsageReader` (millions of rows) — without the bound a
    /// "last hour" query would have to materialize and discard the entire history.
    /// Tier-mixed keys (1s / 1m / 1h all under the same prefix) are returned together;
    /// callers tell tiers apart by inspecting `ts` (e.g. ts % 3600 == 0).
    public func findTimeSeries(prefix: String, since: Int? = nil, until: Int? = nil) -> [(ts: Int, json: String)] {
        let normalised = prefix.hasSuffix("@") ? prefix : "\(prefix)@"

        let dict: [String: String]
        if since != nil || until != nil {
            // Unix seconds are all 10 digits in this era (978307200 through 9999999999,
            // covering 2001..2286), so plain decimal stringification preserves
            // lexicographic == numeric ordering for the range scan.
            let lo = since ?? 0
            let startKey = "\(normalised)\(lo)"
            let endKey: String
            if let until = until {
                endKey = "\(normalised)\(until + 1)"  // exclusive — bump by 1 to include `until`
            } else {
                endKey = "\(normalised)\u{FFFF}"      // sentinel above any digit
            }
            dict = (self.lldb?.findKeysAndValues(inRange: startKey, end: endKey) as? [String: String]) ?? [:]
        } else {
            dict = (self.lldb?.findKeysAndValues(normalised) as? [String: String]) ?? [:]
        }

        var out: [(ts: Int, json: String)] = []
        out.reserveCapacity(dict.count)
        for (key, value) in dict {
            // Only timestamped keys: <module>@<reader>@<unix_seconds>
            guard let tail = key.split(separator: "@").last, let ts = Int(tail) else { continue }
            if let since = since, ts < since { continue }
            if let until = until, ts > until { continue }
            out.append((ts: ts, json: value))
        }
        out.sort { $0.ts < $1.ts }
        return out
    }

    /// Returns the most recent timestamped value (if any) for a `<module>@<reader>` prefix.
    public func findLatestTimeSeries(prefix: String) -> (ts: Int, json: String)? {
        let normalised = prefix.hasSuffix("@") ? prefix : "\(prefix)@"
        guard let dict = self.lldb?.findKeysAndValues(normalised) as? [String: String] else { return nil }
        var bestTS: Int = Int.min
        var bestJSON: String? = nil
        for (key, value) in dict {
            guard let tail = key.split(separator: "@").last, let ts = Int(tail) else { continue }
            if ts > bestTS { bestTS = ts; bestJSON = value }
        }
        guard let j = bestJSON, bestTS != Int.min else { return nil }
        return (ts: bestTS, json: j)
    }

    /// Lists distinct `<module>@<reader>` prefixes currently present in the store.
    public func listPrefixes() -> [String] {
        guard let allKeys = self.lldb?.keys("") as? [String] else { return [] }
        var seen = Set<String>()
        for k in allKeys {
            let parts = k.split(separator: "@")
            // We want timestamped rows: module@reader@ts → 3+ segments, last is integer.
            guard parts.count >= 3, Int(parts.last!) != nil else { continue }
            // Reconstruct everything except the last segment as the prefix.
            let prefix = parts.dropLast().joined(separator: "@")
            seen.insert(prefix)
        }
        return seen.sorted()
    }

    // MARK: - Cleanup

    // Prefixes that opt out of the global TTL prune because they have tier-aware
    // retention via `compactNetTiers()` (1s -> 1m -> 1h rollup, never deleted).
    // Stored WITHOUT trailing `@` so both call sites (pruneExpired sees full keys
    // like "Net@UsageReader@1234"; cleanPrefix gets the bare top-level
    // "Net@UsageReader") can match correctly.
    private static let tieredRetentionTopLevels: [String] = [
        "Network@UsageReader",
        "Network@ProcessReader"
    ]

    fileprivate static func isTieredFullKey(_ key: String) -> Bool {
        tieredRetentionTopLevels.contains(where: { key.hasPrefix("\($0)@") })
    }
    fileprivate static func isTieredTopLevel(_ topLevel: String) -> Bool {
        tieredRetentionTopLevels.contains(topLevel)
    }

    /// Walk the entire store and delete timestamped rows older than the current TTL.
    /// Keys covered by tier-aware retention (see `compactNetTiers`) are skipped.
    public func pruneExpired() {
        guard let allKeys = self.lldb?.keys("") as? [String] else { return }
        let cutoff = Date().currentTimeSeconds() - self.ttl
        var toDelete: [String] = []
        for key in allKeys {
            if Self.isTieredFullKey(key) { continue }
            let parts = key.split(separator: "@")
            guard parts.count >= 3 else { continue }
            guard let tail = parts.last, let ts = Int(tail), ts < cutoff else { continue }
            toDelete.append(key)
        }
        if !toDelete.isEmpty {
            self.lldb?.deleteMany(toDelete)
        }
    }

    // MARK: - Tier-aware retention for Net@UsageReader / Net@ProcessReader
    //
    // History storage policy for net traffic:
    //   * within 30 days  -> 1-second rows kept verbatim
    //   * 30 ..  60 days  -> 1-minute rows (sources rolled up + deleted)
    //   * older than 60d  -> 1-hour rows, local-time aligned (sources rolled up + deleted)
    //
    // Each rollup uses `LLDB.compactRollup` so the merged target write and the source
    // deletes commit atomically — a crash mid-compaction never doubles or loses data.

    fileprivate struct NetPair: Codable {
        var upload: Int64 = 0
        var download: Int64 = 0
        static func +(a: NetPair, b: NetPair) -> NetPair {
            NetPair(upload: a.upload + b.upload, download: a.download + b.download)
        }
    }

    /// Returns the bucket-aligned timestamp for `ts` under the tier policy, or nil
    /// if the row is recent enough that no rollup is required yet.
    private func tierBucket(for ts: Int, now: Int) -> Int? {
        let t30 = now - 30 * 24 * 60 * 60
        let t60 = now - 60 * 24 * 60 * 60
        if ts >= t30 { return nil }                    // within 30d, no rollup
        if ts >= t60 { return ts - (ts % 60) }         // minute bucket
        // hourly bucket aligned to the user's local clock
        let cal = Calendar.current
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        return cal.date(from: comps).map { Int($0.timeIntervalSince1970) }
    }

    public func compactNetTiers() {
        let now = Date().currentTimeSeconds()
        compactSinglePair(prefix: "Network@UsageReader", now: now)
        compactDictPair(prefix: "Network@ProcessReader", now: now)
    }

    private func groupByTargetBucket(prefix: String, now: Int) -> [Int: [String]] {
        guard let allKeys = self.lldb?.keys("\(prefix)@") as? [String] else { return [:] }
        var groups: [Int: [String]] = [:]
        for key in allKeys {
            let parts = key.split(separator: "@")
            guard parts.count >= 3, let tail = parts.last, let ts = Int(tail) else { continue }
            guard let target = self.tierBucket(for: ts, now: now), target != ts else { continue }
            groups[target, default: []].append(key)
        }
        return groups
    }

    private func compactSinglePair(prefix: String, now: Int) {
        let groups = self.groupByTargetBucket(prefix: prefix, now: now)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        for (targetTS, sourceKeys) in groups {
            var merged = NetPair()
            let targetKey = "\(prefix)@\(targetTS)"
            if let existing = self.lldb?.findOne(targetKey), !existing.isEmpty,
               let data = existing.data(using: .utf8),
               let prev = try? decoder.decode(NetPair.self, from: data) {
                merged = merged + prev
            }
            for sk in sourceKeys {
                guard let raw = self.lldb?.findOne(sk), !raw.isEmpty,
                      let data = raw.data(using: .utf8),
                      let p = try? decoder.decode(NetPair.self, from: data) else { continue }
                merged = merged + p
            }
            guard let blob = try? encoder.encode(merged),
                  let str = String(data: blob, encoding: .utf8) else { continue }
            _ = self.lldb?.compactRollup(targetKey, value: str, removing: sourceKeys)
        }
    }

    private func compactDictPair(prefix: String, now: Int) {
        let groups = self.groupByTargetBucket(prefix: prefix, now: now)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        for (targetTS, sourceKeys) in groups {
            var merged: [String: NetPair] = [:]
            let targetKey = "\(prefix)@\(targetTS)"
            if let existing = self.lldb?.findOne(targetKey), !existing.isEmpty,
               let data = existing.data(using: .utf8),
               let prev = try? decoder.decode([String: NetPair].self, from: data) {
                merged.merge(prev, uniquingKeysWith: +)
            }
            for sk in sourceKeys {
                guard let raw = self.lldb?.findOne(sk), !raw.isEmpty,
                      let data = raw.data(using: .utf8),
                      let d = try? decoder.decode([String: NetPair].self, from: data) else { continue }
                merged.merge(d, uniquingKeysWith: +)
            }
            guard let blob = try? encoder.encode(merged),
                  let str = String(data: blob, encoding: .utf8) else { continue }
            _ = self.lldb?.compactRollup(targetKey, value: str, removing: sourceKeys)
        }
    }

    /// Legacy per-prefix cleanup retained for `setup(...)` callers.
    /// Tier-managed prefixes opt out — they have their own retention via
    /// `compactNetTiers()` and must not get the global 7-day cutoff applied.
    /// (Without this guard, every reader's setup() at app launch would wipe
    ///  any imported history older than `history_retention_days`.)
    private func cleanPrefix(_ key: String) {
        if Self.isTieredTopLevel(key) { return }
        guard let keys = self.lldb?.keys(key) as? [String] else { return }
        let cutoff = Date().currentTimeSeconds() - self.ttl
        var toDelete: [String] = []
        keys.forEach { (k: String) in
            if let tail = k.split(separator: "@").last, let ts = Int(tail), ts < cutoff {
                toDelete.append(k)
            }
        }
        self.lldb?.deleteMany(toDelete)
    }

    private func scheduleBackgroundPrune() {
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        // Initial run after 60s to let the app settle, then every hour.
        timer.schedule(deadline: .now() + 60, repeating: 60 * 60)
        timer.setEventHandler { [weak self] in
            self?.compactNetTiers()
            self?.pruneExpired()
        }
        timer.resume()
        self.pruneTimer = timer
    }
}
