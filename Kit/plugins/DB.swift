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
    //
    // `ttlDaysOverride` exists strictly so tests can pin the value without
    // mutating `UserDefaults.standard` — `Store.shared` is backed by the
    // standard suite and the test process shares it with the running app, so
    // a user changing retention in the UI used to silently break the prune
    // tests. Production code never sets this.
    public var ttlDaysOverride: Int?

    public var ttl: Int {
        let days = ttlDaysOverride
            ?? Store.shared.int(key: "history_retention_days", defaultValue: 7)
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

    /// Test/embedding init: open lldb at an explicit path with the timer + warmup
    /// off by default. Lets unit tests exercise insert/find/compaction in
    /// isolation from `DB.shared` and from the user's real lldb at
    /// `~/Library/Application Support/Stats/lldb`. `scheduleBackgroundWork: true`
    /// is only useful for embedding scenarios that want the same lifecycle as
    /// the shared instance.
    public init(at path: URL, scheduleBackgroundWork: Bool = false) {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        guard let lldb = LLDB(path.path) else {
            print("ERROR INITIALIZE DB at \(path.path)")
            return
        }
        self.lldb = lldb
        if scheduleBackgroundWork {
            self.scheduleBackgroundPrune()
        }
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

    /// Insert a value under `key`. If `ts: true`, also writes a timestamped row
    /// at `<key>@<unix_seconds>`. The bare key holds the latest-value mirror
    /// used by `findOne(_:key:)` and live popup reads.
    ///
    /// `at:` lets tests (and the netmon importer, if it ever returns) write to
    /// a specific past timestamp instead of "now". Production callers leave it
    /// nil and get `Date().currentTimeSeconds()`.
    public func insert(key: String, value: Codable, ts: Bool = true, force: Bool = false, at: Int? = nil) {
        self.values[key] = value
        guard let blobData = try? JSONEncoder().encode(value), let str = String(data: blobData, encoding: .utf8) else { return }

        if ts {
            let stamp = at ?? Date().currentTimeSeconds()
            // 10-digit unix-seconds assumption is load-bearing for range scans
            // (`findKeysAndValuesInRange`, `sampleByStride`, the U+FFFF sentinel
            // in `findTimeSeries`). Anything shorter or longer breaks lex==
            // numeric ordering. Assert here so a bad caller surfaces in debug;
            // release builds skip the check so a misbehaving timestamp doesn't
            // crash production. (`assert` is no-op in `-O`.)
            assert((1_000_000_000...9_999_999_999).contains(stamp), "DB.insert: timestamp \(stamp) outside 10-digit range; range queries will silently miss this row")
            self.lldb?.insert("\(key)@\(stamp)", value: str)
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
            let lo = max(0, since ?? 0)
            let startKey = "\(normalised)\(lo)"
            let endKey: String
            if let until = until {
                // Exclusive upper bound — bump by 1 to include `until` itself.
                // Saturate at Int.max to avoid overflow on pathological callers.
                let hi = until == Int.max ? Int.max : until + 1
                endKey = "\(normalised)\(hi)"
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
    /// O(log N) — uses a reverse iterator instead of materializing the prefix.
    public func findLatestTimeSeries(prefix: String) -> (ts: Int, json: String)? {
        let normalised = prefix.hasSuffix("@") ? prefix : "\(prefix)@"
        guard let dict = self.lldb?.findLastKeyAndValue(normalised) as? [String: String],
              let (key, value) = dict.first,
              let tail = key.split(separator: "@").last,
              let ts = Int(tail) else { return nil }
        return (ts: ts, json: value)
    }

    /// Returns up to `maxPoints` rows under `prefix` between `since` and `until` (inclusive)
    /// using stride-sampled iterator seeks rather than a full prefix scan. Use this for
    /// chart-series queries — the chart can render at most a few hundred points, so
    /// pulling 600k rows for a 7-day Net@ProcessReader window is wasted work.
    ///
    /// Stride is chosen so the number of returned rows is bounded by `maxPoints`.
    /// Points are evenly spaced in time; an empty bucket simply contributes the next
    /// non-empty row past it (skip-zero gaps don't break the cadence).
    public func findTimeSeriesSampled(prefix: String, since: Int, until: Int? = nil, maxPoints: Int = 720) -> [(ts: Int, json: String)] {
        let now = Date().currentTimeSeconds()
        let hi = until ?? now
        let lo = max(0, since)
        guard hi > lo, maxPoints > 0 else { return [] }
        let stride = max(1, (hi - lo + maxPoints - 1) / maxPoints)  // ceil-divide so we land within budget
        return self.findTimeSeriesByStride(prefix: prefix, since: lo, until: hi, strideSec: stride)
    }

    /// Stride-sampled time-series read with the stride supplied directly by the caller.
    /// Used by MCP `/metrics?bucket=N` so a wide bucketed query pays only the seek cost
    /// for the rows it returns, not a full prefix materialization. Charts use the
    /// `maxPoints`-bounded wrapper above.
    public func findTimeSeriesByStride(prefix: String, since: Int, until: Int, strideSec: Int) -> [(ts: Int, json: String)] {
        let normalised = prefix.hasSuffix("@") ? prefix : "\(prefix)@"
        guard until > since, strideSec > 0 else { return [] }

        guard let raw = self.lldb?.sample(byStride: normalised, from: Int64(since), to: Int64(until), strideSec: Int32(strideSec)) as? [[Any]] else { return [] }

        var out: [(ts: Int, json: String)] = []
        out.reserveCapacity(raw.count)
        for pair in raw {
            guard pair.count == 2,
                  let tsNum = pair[0] as? NSNumber,
                  let json = pair[1] as? String else { continue }
            out.append((ts: tsNum.intValue, json: json))
        }
        return out
    }

    // Cached prefix listing. The full DB scan needed to compute this is O(all keys)
    // — for the Network@* prefixes that's ~1.7M keys, ~1–3 s on first call. The
    // listing is just metadata for the History view's toolbar ("N streams · Md
    // retention"); we can serve a slightly stale list cheaply.
    //
    // IMPORTANT: this state has its own lock, NOT `self.queue`. The hourly
    // prune timer runs on `self.queue` and calls `refreshPrefixCache()` —
    // if the cache writes went through `self.queue.sync` from inside that
    // handler we'd hit `dispatch_sync called on queue already owned by
    // current thread` and SIGTRAP. (We did, in fact. Crash:
    //   "BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue
    //    already owned by current thread"
    // at DB.refreshPrefixCache() <- closure in scheduleBackgroundPrune.)
    private let prefixCacheLock = NSLock()
    private var _cachedPrefixes: [String] = []
    private var _cachedPrefixesAt: Date? = nil

    /// Lists distinct `<module>@<reader>` prefixes currently present in the store.
    /// Returns the cached list immediately if we have one; otherwise kicks off an
    /// async refresh and returns whatever's cached (possibly empty on cold start).
    /// The hourly background timer also refreshes this so it's never far stale.
    /// UI surfaces should use this — they tolerate a brief "0 streams" toolbar
    /// label rather than a 1–3 s freeze on first paint.
    public func listPrefixes() -> [String] {
        prefixCacheLock.lock()
        let cached = _cachedPrefixes
        let cold = _cachedPrefixesAt == nil
        prefixCacheLock.unlock()
        // First call ever — kick off an async populate so subsequent calls are fast.
        // Concurrent triggers are tolerated: refreshPrefixCache writes the result
        // under the prefixCacheLock, and concurrent scans converge on the same
        // sorted list.
        if cold {
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.refreshPrefixCache() }
        }
        return cached
    }

    /// Like `listPrefixes()` but waits for the first scan to complete if the
    /// cache hasn't been populated yet. Used by the MCP-facing QueryServer
    /// (`/info`, `/modules`) where returning an empty list during the cold-start
    /// window would silently break agent tools that iterate prefixes.
    /// Once populated, returns the cached value cheaply on every call; the
    /// hourly timer keeps it fresh.
    public func listPrefixesBlocking() -> [String] {
        prefixCacheLock.lock()
        let bootstrapped = _cachedPrefixesAt != nil
        prefixCacheLock.unlock()
        if !bootstrapped {
            self.refreshPrefixCache()
        }
        prefixCacheLock.lock()
        let cached = _cachedPrefixes
        prefixCacheLock.unlock()
        return cached
    }

    /// Walks every key in the DB to rebuild `_cachedPrefixes`. Cheap callers should
    /// go through `listPrefixes()`; this is exposed only so the background timer
    /// can refresh the cache directly.
    ///
    /// Re-entrant: concurrent invocations are allowed and converge on the same
    /// state (each gets its own leveldb iterator; the final write under
    /// `prefixCacheLock` is atomic). This matters because `listPrefixesBlocking()`
    /// may call this from an MCP request while the startup warmup is still
    /// running on a background queue.
    ///
    /// MUST use `prefixCacheLock`, not `self.queue`, for the cache mutation —
    /// `scheduleBackgroundPrune` runs the timer event handler on `self.queue`
    /// and `self.queue.sync` from there would re-enter and SIGTRAP.
    fileprivate func refreshPrefixCache() {
        guard let allKeys = self.lldb?.keys("") as? [String] else { return }
        var seen = Set<String>()
        for k in allKeys {
            let parts = k.split(separator: "@")
            // We want timestamped rows: module@reader@ts → 3+ segments, last is integer.
            guard parts.count >= 3, Int(parts.last!) != nil else { continue }
            // Reconstruct everything except the last segment as the prefix.
            let prefix = parts.dropLast().joined(separator: "@")
            seen.insert(prefix)
        }
        let sorted = seen.sorted()
        prefixCacheLock.lock()
        _cachedPrefixes = sorted
        _cachedPrefixesAt = Date()
        prefixCacheLock.unlock()
    }

    // MARK: - Cleanup

    // Prefixes (top-level `<module>@<reader>`, no trailing `@`) that opt out of
    // the global TTL prune because they have tier-aware retention via
    // `compactNetTiers()` (1s -> 1m -> 1h rollup, never deleted).
    private static let tieredRetentionTopLevels: [String] = [
        "Network@UsageReader",
        "Network@ProcessReader"
    ]

    /// Single source of truth for "is this key/prefix governed by tiered retention?".
    /// Accepts either a full timestamped key (`Network@UsageReader@1234567890`) or a
    /// bare top-level (`Network@UsageReader`); both should answer the same. Routes
    /// through one matcher so any future delete-by-age surface only needs to call
    /// this rather than reproduce the skip-list.
    fileprivate static func hasTieredRetention(_ keyOrTopLevel: String) -> Bool {
        for tl in tieredRetentionTopLevels {
            if keyOrTopLevel == tl || keyOrTopLevel.hasPrefix("\(tl)@") { return true }
        }
        return false
    }

    /// Walk the entire store and delete timestamped rows older than the current TTL.
    /// Keys covered by tier-aware retention (see `compactNetTiers`) are skipped.
    public func pruneExpired() {
        guard let allKeys = self.lldb?.keys("") as? [String] else { return }
        let cutoff = Date().currentTimeSeconds() - self.ttl
        var toDelete: [String] = []
        for key in allKeys {
            if Self.hasTieredRetention(key) { continue }
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
    // History storage policy for net traffic — configurable by the user via the
    // History storage settings panel. Each value is days; defaults match the
    // pre-configurable hard-coded behaviour (30/30/forever) so existing
    // installs see no change after upgrading.
    //
    //   * within `nativeDays`                       -> 1-second rows kept verbatim
    //   * next  `minuteDays`                        -> 1-minute rows (sources rolled up + deleted)
    //   * next  `hourDays`                          -> 1-hour rows, local-time aligned
    //   * older than nativeDays+minuteDays+hourDays -> dropped
    //
    // `hourDays >= NetTierPolicy.unlimitedSentinel` means "keep forever at the hour
    // tier". Each rollup uses `LLDB.compactRollup` so the merged target write
    // and the source deletes commit atomically — a crash mid-compaction never
    // doubles or loses data.

    public struct NetTierPolicy: Equatable {
        public var nativeDays: Int
        public var minuteDays: Int
        public var hourDays: Int

        /// Any `hourDays` value at or above this is treated as "keep forever";
        /// roughly ~27 years. Chosen so it survives ints-from-defaults round-trip
        /// without overflowing arithmetic in `tierBucket`.
        public static let unlimitedSentinel: Int = 9999

        // Sensible presets the Settings UI surfaces as buttons. The day counts
        // are *durations of each tier's window* (not absolute end-of-tier days),
        // so "full" = 30 d at 1 s + 30 d at 1 m means the 1-minute tier spans
        // days 30–60, matching the pre-configurable hard-coded behaviour.
        public static let compact  = NetTierPolicy(nativeDays: 1,  minuteDays: 6,  hourDays: 23)                    //  ~30 d total
        public static let balanced = NetTierPolicy(nativeDays: 7,  minuteDays: 23, hourDays: 335)                   // ~365 d total
        public static let full     = NetTierPolicy(nativeDays: 30, minuteDays: 30, hourDays: unlimitedSentinel)     // forever, matches old default

        /// Reads the user's current configuration from Store. Falls back to
        /// `.full` (the pre-configurable behaviour) so pre-upgrade installs are
        /// untouched on first read.
        public static func current() -> NetTierPolicy {
            let defaults = NetTierPolicy.full
            return NetTierPolicy(
                nativeDays: max(0, Store.shared.int(key: "history_tier_net_native_days", defaultValue: defaults.nativeDays)),
                minuteDays: max(0, Store.shared.int(key: "history_tier_net_minute_days", defaultValue: defaults.minuteDays)),
                hourDays:   max(0, Store.shared.int(key: "history_tier_net_hour_days",   defaultValue: defaults.hourDays))
            )
        }

        public var isHourTierUnlimited: Bool { self.hourDays >= NetTierPolicy.unlimitedSentinel }
    }

    fileprivate struct NetPair: Codable {
        var upload: Int64 = 0
        var download: Int64 = 0
        static func +(a: NetPair, b: NetPair) -> NetPair {
            NetPair(upload: a.upload + b.upload, download: a.download + b.download)
        }
    }

    /// Returns the action the tiering compactor should take for a row at `ts`:
    ///   * `nil`           — within the native (1 s) window; keep verbatim
    ///   * `> 0`           — bucket-aligned target timestamp to roll into
    ///   * `dropSentinel`  — past all configured tiers; caller should delete
    fileprivate static let dropSentinel: Int = -1

    private func tierBucket(for ts: Int, now: Int, policy: NetTierPolicy = .current()) -> Int? {
        let day = 24 * 60 * 60
        let tNative = now - policy.nativeDays * day
        let tMinute = tNative - policy.minuteDays * day
        // When hourDays is unlimited, drive `tHour` to -∞ so the "expired" check
        // can never trip — equivalent to the pre-configurable behaviour.
        let tHour: Int = policy.isHourTierUnlimited
            ? Int.min
            : tMinute - policy.hourDays * day

        if ts >= tNative { return nil }                    // verbatim
        if ts >= tMinute { return ts - (ts % 60) }         // minute bucket
        if ts >= tHour {
            // hourly bucket aligned to the user's local clock
            let cal = Calendar.current
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
            return cal.date(from: comps).map { Int($0.timeIntervalSince1970) }
        }
        return Self.dropSentinel
    }

    /// The exact body the hourly timer handler runs. Factored out so tests can
    /// execute it under `self.queue.sync` to catch the re-entrant
    /// `dispatch_sync` SIGTRAP this used to throw (see `prefixCacheLock`).
    /// Production calls go through the timer's event handler; tests call
    /// `runMaintenanceForTest()` which puts it on the queue explicitly.
    fileprivate func runMaintenanceCycleOnQueue() {
        self.compactNetTiers()
        self.pruneExpired()
        // Tell leveldb to merge SSTables and drop tombstones. Without this
        // the on-disk store grows to ~10× the working set because every
        // `compactRollup` Delete leaves a tombstone and every latest-value
        // mirror write creates a new version of the same bare key. The
        // hourly call keeps things bounded; it's synchronous on our queue
        // but doesn't block concurrent reads/writes through leveldb itself.
        self.lldb?.compactRange()
        self.refreshPrefixCache()
    }

    /// Test-only: simulate the hourly timer's call site exactly, by running
    /// the maintenance cycle synchronously ON `self.queue`. Any future change
    /// that re-introduces a `self.queue.sync` inside this code path will
    /// re-trigger the SIGTRAP and fail the test.
    public func runMaintenanceForTest() {
        self.queue.sync { self.runMaintenanceCycleOnQueue() }
    }

    /// Run the tier-rollup once. `now:` is injectable for tests that want to
    /// drive the tier boundaries deterministically; production calls pass nil
    /// and pick up `Date().currentTimeSeconds()`. `policy:` is injectable so
    /// tests can pin a known shape — production reads `NetTierPolicy.current()`
    /// once per tick so a UI change picked up by the next hourly maintenance
    /// applies consistently across both prefixes.
    public func compactNetTiers(now: Int? = nil, policy: NetTierPolicy? = nil) {
        let n = now ?? Date().currentTimeSeconds()
        let p = policy ?? NetTierPolicy.current()
        compactSinglePair(prefix: "Network@UsageReader",   now: n, policy: p)
        compactDictPair(prefix:   "Network@ProcessReader", now: n, policy: p)
    }

    /// Result of grouping for tier compaction:
    ///   * `rollups`  — keys to merge into the keyed bucket target
    ///   * `drops`    — keys whose row is past every configured tier; delete outright
    fileprivate struct TierGroups {
        var rollups: [Int: [String]] = [:]
        var drops: [String] = []
    }

    private func groupByTargetBucket(prefix: String, now: Int, policy: NetTierPolicy) -> TierGroups {
        // Only rows whose ts is older than the native (1 s) boundary need rolling
        // up. Bound the scan to `[<prefix>@0, <prefix>@<tNative>)` so we allocate
        // keys only for the slice that's actually due, instead of pulling every
        // key under the prefix and filtering in Swift. At steady state the prefix
        // can hold millions of recent 1 s rows that never get touched.
        let tNative = now - policy.nativeDays * 24 * 60 * 60
        let startKey = "\(prefix)@0"
        let endKey = "\(prefix)@\(tNative)"  // exclusive — keys with ts == tNative stay 1s
        guard let oldKeys = self.lldb?.keys(inRange: startKey, end: endKey) as? [String] else { return TierGroups() }
        var out = TierGroups()
        for key in oldKeys {
            let parts = key.split(separator: "@")
            guard parts.count >= 3, let tail = parts.last, let ts = Int(tail) else { continue }
            guard let target = self.tierBucket(for: ts, now: now, policy: policy) else { continue }
            if target == Self.dropSentinel {
                out.drops.append(key)
            } else if target != ts {
                out.rollups[target, default: []].append(key)
            }
        }
        return out
    }

    private func compactSinglePair(prefix: String, now: Int, policy: NetTierPolicy) {
        let groups = self.groupByTargetBucket(prefix: prefix, now: now, policy: policy)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        for (targetTS, sourceKeys) in groups.rollups {
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
            if self.lldb?.compactRollup(targetKey, value: str, removing: sourceKeys) == false {
                error("compactRollup failed at \(targetKey) (single-pair, \(sourceKeys.count) sources)")
            }
        }
        if !groups.drops.isEmpty {
            self.lldb?.deleteMany(groups.drops)
        }
    }

    private func compactDictPair(prefix: String, now: Int, policy: NetTierPolicy) {
        let groups = self.groupByTargetBucket(prefix: prefix, now: now, policy: policy)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        for (targetTS, sourceKeys) in groups.rollups {
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
            if self.lldb?.compactRollup(targetKey, value: str, removing: sourceKeys) == false {
                error("compactRollup failed at \(targetKey) (dict-pair, \(sourceKeys.count) sources)")
            }
        }
        if !groups.drops.isEmpty {
            self.lldb?.deleteMany(groups.drops)
        }
    }

    /// Legacy per-prefix cleanup retained for `setup(...)` callers.
    /// Tier-managed prefixes opt out — they have their own retention via
    /// `compactNetTiers()` and must not get the global 7-day cutoff applied.
    /// (Without this guard, every reader's setup() at app launch would wipe
    ///  any imported history older than `history_retention_days`.)
    private func cleanPrefix(_ key: String) {
        if Self.hasTieredRetention(key) { return }
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
            // Runs on `self.queue`. Anything called here that takes
            // `self.queue.sync { ... }` will SIGTRAP with
            // "dispatch_sync called on queue already owned by current thread".
            // We hit that exact crash once already — the cache writes now use
            // `prefixCacheLock` precisely so this site stays safe.
            self?.runMaintenanceCycleOnQueue()
        }
        timer.resume()
        self.pruneTimer = timer

        // Warm the prefix cache on a background queue at startup so the History
        // toolbar's "N streams" label can render without a full DB scan on first
        // open. Doing this here (rather than in `init`) keeps the synchronous
        // init path tight — the LLDB handle is already up.
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.refreshPrefixCache() }
    }
}
