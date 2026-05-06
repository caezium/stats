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
    public func findTimeSeries(prefix: String, since: Int? = nil, until: Int? = nil) -> [(ts: Int, json: String)] {
        let normalised = prefix.hasSuffix("@") ? prefix : "\(prefix)@"
        guard let dict = self.lldb?.findKeysAndValues(normalised) as? [String: String] else { return [] }

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

    /// Walk the entire store and delete timestamped rows older than the current TTL.
    public func pruneExpired() {
        guard let allKeys = self.lldb?.keys("") as? [String] else { return }
        let cutoff = Date().currentTimeSeconds() - self.ttl
        var toDelete: [String] = []
        for key in allKeys {
            let parts = key.split(separator: "@")
            guard parts.count >= 3 else { continue }
            guard let tail = parts.last, let ts = Int(tail), ts < cutoff else { continue }
            toDelete.append(key)
        }
        if !toDelete.isEmpty {
            self.lldb?.deleteMany(toDelete)
        }
    }

    /// Legacy per-prefix cleanup retained for `setup(...)` callers.
    private func cleanPrefix(_ key: String) {
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
            self?.pruneExpired()
        }
        timer.resume()
        self.pruneTimer = timer
    }
}
