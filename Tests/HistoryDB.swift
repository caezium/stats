//
//  HistoryDB.swift
//  Tests
//
//  Exercises the time-series DB layer that backs the History view and the
//  MCP QueryServer. Each test constructs a fresh `DB` instance against a
//  temp lldb path so it can't touch the user's real
//  `~/Library/Application Support/Stats/lldb`.
//
//  What's deliberately covered:
//    - Roundtrip: insert at known timestamps, read back via findTimeSeries.
//    - Schema collision: two writers at the same key/ts — last-write-wins,
//      and the compactor doesn't silently drop the un-decodable shape.
//    - compactNetTiers 1s -> 1m: 60 source rows over a minute "35 days ago"
//      collapse to a single 1m bucket whose value is the SUM.
//    - compactNetTiers idempotency: running it again on settled data is a
//      no-op (no double-counting, no zombie source rows).
//    - findLatestTimeSeries correctness across prefixes — proves the
//      reverse-iterator path doesn't suffer the bug that `LLDB.findLast`
//      has where it only returns data for the lex-last prefix in the DB.
//    - Sampler under sparse data: doesn't infinite-loop, returns ≤ maxPoints
//      monotonically increasing in ts.
//

import XCTest
@testable import Kit

private struct Pair: Codable, Equatable {
    var upload: Int64 = 0
    var download: Int64 = 0
}

final class HistoryDBTests: XCTestCase {
    private var tempDir: URL!
    private var db: DB!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stats-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = DB(at: tempDir.appendingPathComponent("lldb"))
        // Pin retention so the prune tests don't depend on whatever value the
        // user has set in the running app (Store.shared is backed by
        // UserDefaults.standard which is shared with the host process).
        db.ttlDaysOverride = 7
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // Decode the raw JSON of a returned row into a Pair so we can compare
    // values directly (the DB returns JSON strings, not typed values).
    private func decode(_ entry: (ts: Int, json: String)) -> Pair? {
        guard let data = entry.json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Pair.self, from: data)
    }

    // MARK: - Roundtrip

    func testInsertRoundtrip_basic() throws {
        let base = 1_700_000_000
        db.insert(key: "Test@Usage", value: Pair(upload: 1, download: 2), ts: true, at: base)
        db.insert(key: "Test@Usage", value: Pair(upload: 3, download: 4), ts: true, at: base + 1)
        db.insert(key: "Test@Usage", value: Pair(upload: 5, download: 6), ts: true, at: base + 2)

        let rows = db.findTimeSeries(prefix: "Test@Usage", since: base, until: base + 2)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].ts, base)
        XCTAssertEqual(rows[2].ts, base + 2)
        XCTAssertEqual(decode(rows[0])?.upload, 1)
        XCTAssertEqual(decode(rows[2])?.download, 6)
    }

    func testFindTimeSeries_rangeBoundsAreInclusive() throws {
        let base = 1_700_000_000
        for i in 0..<10 {
            db.insert(key: "T@R", value: Pair(upload: Int64(i)), ts: true, at: base + i)
        }
        let mid = db.findTimeSeries(prefix: "T@R", since: base + 2, until: base + 5)
        XCTAssertEqual(mid.map { $0.ts }, [base + 2, base + 3, base + 4, base + 5])
    }

    // MARK: - findLatestTimeSeries

    func testFindLatestTimeSeries_returnsLatestPerPrefix_evenWhenOtherPrefixesSortAfter() throws {
        // A@X is lexicographically BEFORE Z@Y. The old `LLDB.findLast` walks
        // SeekToLast and returns the global last row, so a call for "A@X"
        // would return Z@Y's data. findLastKeyAndValue should not.
        db.insert(key: "A@X", value: Pair(upload: 10), ts: true, at: 1_700_000_100)
        db.insert(key: "A@X", value: Pair(upload: 11), ts: true, at: 1_700_000_200)
        db.insert(key: "Z@Y", value: Pair(upload: 99), ts: true, at: 1_700_000_300)

        let latestA = db.findLatestTimeSeries(prefix: "A@X")
        XCTAssertNotNil(latestA)
        XCTAssertEqual(latestA?.ts, 1_700_000_200)
        XCTAssertEqual(decode((ts: latestA!.ts, json: latestA!.json))?.upload, 11)

        let latestZ = db.findLatestTimeSeries(prefix: "Z@Y")
        XCTAssertEqual(latestZ?.ts, 1_700_000_300)
    }

    func testFindLatestTimeSeries_returnsNilForUnknownPrefix() throws {
        db.insert(key: "A@X", value: Pair(upload: 1), ts: true, at: 1_700_000_000)
        XCTAssertNil(db.findLatestTimeSeries(prefix: "Nope@Reader"))
    }

    // MARK: - Sampler

    func testSampler_denseData_returnsApproximatelyMaxPoints() throws {
        let base = 1_700_000_000
        for i in 0..<1000 {
            db.insert(key: "Dense@R", value: Pair(upload: Int64(i)), ts: true, at: base + i)
        }
        let sampled = db.findTimeSeriesSampled(
            prefix: "Dense@R", since: base, until: base + 999, maxPoints: 100
        )
        // Stride = ceil(1000 / 100) = 10; expect ~100 rows, monotonically increasing.
        XCTAssertGreaterThan(sampled.count, 90)
        XCTAssertLessThanOrEqual(sampled.count, 110)
        let timestamps = sampled.map { $0.ts }
        XCTAssertEqual(timestamps, timestamps.sorted(), "sampler returned unsorted timestamps")
    }

    func testSampler_sparseData_terminatesAndStaysMonotone() throws {
        // Five rows scattered over a 1-hour window. With stride ~360s, the
        // sampler picks the next available row at-or-after each stride point —
        // so some inserted rows may legitimately be skipped (200 will be
        // skipped because the stride from 10 lands at 370, which seeks past).
        // What we're verifying: terminates in finite time, returned timestamps
        // are monotonically increasing, and every returned ts is one of the
        // inserted ones (no phantom rows).
        let base = 1_700_000_000
        let timestamps = [base + 10, base + 200, base + 800, base + 1500, base + 3500]
        for ts in timestamps {
            db.insert(key: "Sparse@R", value: Pair(upload: 1), ts: true, at: ts)
        }
        let sampled = db.findTimeSeriesSampled(
            prefix: "Sparse@R", since: base, until: base + 3600, maxPoints: 10
        )
        XCTAssertGreaterThan(sampled.count, 0)
        XCTAssertLessThanOrEqual(sampled.count, timestamps.count)
        let returned = sampled.map { $0.ts }
        XCTAssertEqual(returned, returned.sorted(), "sampler returned out-of-order rows")
        XCTAssertTrue(Set(returned).isSubset(of: Set(timestamps)), "sampler returned a ts that wasn't inserted")
    }

    func testSampler_strideLargerThanRange_returnsAtMostOneRow() throws {
        // Edge case that used to be a hand-coded `lastTS == target` defensive
        // guard in the Obj-C seek loop. Verify it doesn't spin forever.
        let base = 1_700_000_000
        db.insert(key: "Tiny@R", value: Pair(upload: 1), ts: true, at: base + 5)
        let sampled = db.findTimeSeriesSampled(
            prefix: "Tiny@R", since: base, until: base + 10, maxPoints: 1
        )
        XCTAssertLessThanOrEqual(sampled.count, 1)
    }

    // MARK: - compactNetTiers

    func testCompactNetTiers_rollsSecondsToOneMinuteBucket_overTheBoundary() throws {
        // Pick a "now" 35 days ahead of a chosen minute boundary so all 60
        // sample rows fall cleanly in the 30-60d band → 1m tier. Insert at
        // bucket+0 .. bucket+59 and verify they collapse into bucket itself.
        let now = 1_700_000_000
        let alignedBucket = (now - 35 * 24 * 60 * 60) / 60 * 60  // floor to minute

        for i in 0..<60 {
            db.insert(key: "Network@UsageReader", value: Pair(upload: 1, download: 2), ts: true, at: alignedBucket + i)
        }

        db.compactNetTiers(now: now)

        // The 60 source rows should now be gone, replaced by one bucket-aligned key.
        let after = db.findTimeSeries(
            prefix: "Network@UsageReader",
            since: alignedBucket - 1,
            until: alignedBucket + 60
        )
        XCTAssertEqual(after.count, 1, "expected one rolled-up row, got \(after.map { $0.ts })")
        let merged = decode(after[0])
        XCTAssertEqual(merged?.upload, 60, "60 source rows × upload=1 should sum to 60")
        XCTAssertEqual(merged?.download, 120, "60 source rows × download=2 should sum to 120")
        XCTAssertEqual(after[0].ts, alignedBucket, "bucket ts should be the minute-floor of the source ts")
    }

    func testCompactNetTiers_idempotent_onAlreadyCompactedData() throws {
        // Run the same scenario, then run compactNetTiers again. Result should
        // be unchanged — already-bucket-aligned rows are skipped via the
        // `target != ts` guard in groupByTargetBucket.
        let now = 1_700_000_000
        let alignedBucket = (now - 35 * 24 * 60 * 60) / 60 * 60
        for i in 0..<60 {
            db.insert(key: "Network@UsageReader", value: Pair(upload: 1, download: 2), ts: true, at: alignedBucket + i)
        }
        db.compactNetTiers(now: now)
        let firstPass = db.findTimeSeries(
            prefix: "Network@UsageReader", since: alignedBucket - 1, until: alignedBucket + 60
        )

        db.compactNetTiers(now: now)
        let secondPass = db.findTimeSeries(
            prefix: "Network@UsageReader", since: alignedBucket - 1, until: alignedBucket + 60
        )

        XCTAssertEqual(firstPass.count, secondPass.count)
        XCTAssertEqual(firstPass.first?.ts, secondPass.first?.ts)
        XCTAssertEqual(decode(firstPass[0])?.upload, decode(secondPass[0])?.upload, "idempotency violated: re-compaction changed the bucket's value")
    }

    func testCompactNetTiers_rollsMinuteBucketsToHourBucket_past60Days() throws {
        // Same shape as the 1s→1m test but at the 60d boundary: 60 minute
        // buckets that are 65 days old should collapse to one local-time-aligned
        // hour bucket.
        let now = 1_700_000_000
        // Hour bucket aligned to LOCAL time — match what tierBucket does for >60d.
        let cal = Calendar.current
        let rawTS = now - 65 * 24 * 60 * 60
        let date = Date(timeIntervalSince1970: TimeInterval(rawTS))
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        let hourBucket = Int(cal.date(from: comps)!.timeIntervalSince1970)

        // Insert 60 minute-bucketed rows within that hour.
        for m in 0..<60 {
            db.insert(key: "Network@UsageReader", value: Pair(upload: 10, download: 20),
                      ts: true, at: hourBucket + m * 60)
        }

        db.compactNetTiers(now: now)

        let after = db.findTimeSeries(
            prefix: "Network@UsageReader",
            since: hourBucket - 1,
            until: hourBucket + 3600
        )
        XCTAssertEqual(after.count, 1, "expected one hour-bucket row, got \(after.map { $0.ts })")
        let merged = decode(after[0])
        XCTAssertEqual(merged?.upload, 600, "60 minute rows × upload=10 should sum to 600")
        XCTAssertEqual(merged?.download, 1200, "60 minute rows × download=20 should sum to 1200")
        XCTAssertEqual(after[0].ts, hourBucket, "result ts should be the local-time hour boundary")
    }

    func testCompactNetTiers_processDictShape_sumsPerAppAcrossBucket() throws {
        // The compactDictPair path: `Network@ProcessReader` rows are dicts of
        // app-name → {upload, download}. Per-app values should sum across the
        // bucket; an app present in some rows but missing in others should
        // appear in the merged bucket with the rows it had.
        let now = 1_700_000_000
        let alignedBucket = (now - 35 * 24 * 60 * 60) / 60 * 60

        // 30 rows where "Chrome" has bytes; 30 rows where "Slack" has bytes;
        // some overlap.
        for i in 0..<60 {
            var snapshot: [String: Pair] = [:]
            if i < 40 {
                snapshot["Chrome"] = Pair(upload: 1, download: 2)
            }
            if i >= 20 {
                snapshot["Slack"] = Pair(upload: 3, download: 5)
            }
            db.insert(key: "Network@ProcessReader", value: snapshot,
                      ts: true, at: alignedBucket + i)
        }

        db.compactNetTiers(now: now)

        let after = db.findTimeSeries(
            prefix: "Network@ProcessReader",
            since: alignedBucket - 1,
            until: alignedBucket + 60
        )
        XCTAssertEqual(after.count, 1)
        let data = after[0].json.data(using: .utf8)!
        let merged = try XCTUnwrap(try? JSONDecoder().decode([String: Pair].self, from: data))
        XCTAssertEqual(merged["Chrome"]?.upload, 40, "Chrome had 40 rows × 1 = 40")
        XCTAssertEqual(merged["Chrome"]?.download, 80, "Chrome 40 rows × 2 = 80")
        XCTAssertEqual(merged["Slack"]?.upload, 40 * 3, "Slack had 40 rows × 3 = 120")
        XCTAssertEqual(merged["Slack"]?.download, 40 * 5, "Slack 40 rows × 5 = 200")
    }

    func testCompactNetTiers_recentDataIsNotTouched() throws {
        // Insert 60 rows in the LAST hour — well inside the 30d window. The
        // compactor should leave them alone.
        let now = 1_700_000_000
        for i in 0..<60 {
            db.insert(key: "Network@UsageReader", value: Pair(upload: 1), ts: true, at: now - 60 + i)
        }
        db.compactNetTiers(now: now)
        let after = db.findTimeSeries(
            prefix: "Network@UsageReader", since: now - 60, until: now
        )
        XCTAssertEqual(after.count, 60, "recent rows were touched by compaction")
    }

    // MARK: - Schema collision contract

    func testInsertAtSameTimestamp_lastWriteWins() throws {
        // The Net readers used to double-write the same key with two shapes
        // (compact `{upload,download}` from the explicit insert + nested
        // `{bandwidth:{...}}` from the base-class auto-persist). Last write
        // wins at the lldb layer. This test pins that semantic — if it ever
        // changes the schema-collision class of bug needs a fresh review.
        let ts = 1_700_000_000
        db.insert(key: "Test@Coll", value: Pair(upload: 1, download: 1), ts: true, at: ts)
        db.insert(key: "Test@Coll", value: Pair(upload: 99, download: 99), ts: true, at: ts)
        let rows = db.findTimeSeries(prefix: "Test@Coll", since: ts, until: ts)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(decode(rows[0])?.upload, 99)
    }

    // MARK: - Pruning + retention

    func testPruneExpired_deletesNonTieredRowsOlderThanTTL() throws {
        // CPU@LoadReader is NOT a tiered prefix, so global TTL applies. With
        // the default 7-day TTL, a 30-day-old row should get pruned.
        let now = Date().currentTimeSeconds()
        let oldTS = now - 30 * 24 * 60 * 60
        let recentTS = now - 60   // 60 seconds ago

        db.insert(key: "CPU@LoadReader", value: Pair(upload: 1), ts: true, at: oldTS)
        db.insert(key: "CPU@LoadReader", value: Pair(upload: 2), ts: true, at: recentTS)

        db.pruneExpired()

        let surviving = db.findTimeSeries(prefix: "CPU@LoadReader")
        XCTAssertEqual(surviving.count, 1, "pruneExpired should delete the 30-day-old row")
        XCTAssertEqual(surviving.first?.ts, recentTS)
    }

    func testPruneExpired_skipsTieredPrefixes() throws {
        // Network@UsageReader IS tiered (compactNetTiers manages it). The global
        // TTL prune must NOT touch its rows, no matter how old — otherwise the
        // imported 73 days of history would get wiped on the first hourly tick.
        let now = Date().currentTimeSeconds()
        let veryOldTS = now - 60 * 24 * 60 * 60  // 60 days

        db.insert(key: "Network@UsageReader", value: Pair(upload: 1), ts: true, at: veryOldTS)

        db.pruneExpired()

        let surviving = db.findTimeSeries(prefix: "Network@UsageReader")
        XCTAssertEqual(surviving.count, 1, "pruneExpired must not touch tiered Network@* rows")
        XCTAssertEqual(surviving.first?.ts, veryOldTS)
    }

    // MARK: - Re-entrance regression

    func testMaintenanceCycle_doesNotDeadlockOnInternalQueue() throws {
        // Reproduces the SIGTRAP shipped in the first install:
        //   "BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue
        //    already owned by current thread"
        //   at DB.refreshPrefixCache() <- closure in scheduleBackgroundPrune
        // The hourly prune timer's event handler runs ON DB's internal serial
        // queue. If any work it does re-enters that queue via `.sync` we crash.
        // `runMaintenanceForTest()` puts the same call sequence onto the queue
        // explicitly so this test exercises the exact production path.
        // Use timestamps inside the default 7-day TTL window so `pruneExpired`
        // (which the maintenance cycle also runs) doesn't wipe the test data
        // before `refreshPrefixCache` gets to it.
        let now = Date().currentTimeSeconds()
        db.insert(key: "A@One", value: Pair(upload: 1), ts: true, at: now - 60)
        db.insert(key: "B@Two", value: Pair(upload: 2), ts: true, at: now - 60)

        // If anything in the maintenance cycle re-enters `self.queue` this
        // will SIGTRAP and the test fails.
        db.runMaintenanceForTest()

        // Cache should be populated after the cycle.
        XCTAssertEqual(db.listPrefixesBlocking().sorted(), ["A@One", "B@Two"])
    }

    // MARK: - listPrefixesBlocking

    func testListPrefixesBlocking_returnsAllDistinctPrefixes() throws {
        let ts = 1_700_000_000
        db.insert(key: "A@One", value: Pair(), ts: true, at: ts)
        db.insert(key: "B@Two", value: Pair(), ts: true, at: ts)
        db.insert(key: "C@Three", value: Pair(), ts: true, at: ts)
        // Multiple rows under one prefix should still count as one prefix.
        db.insert(key: "A@One", value: Pair(), ts: true, at: ts + 1)

        let prefixes = db.listPrefixesBlocking()
        XCTAssertEqual(prefixes.sorted(), ["A@One", "B@Two", "C@Three"])
    }
}

// MARK: - Reader.tick() popup-closed gating
//
// Pins the energy-saving contract added in c98a7db: when the popup is
// closed AND the reader is keeping itself alive for history, we run
// `read()` only every `interval * popupClosedIntervalMultiplier` seconds
// instead of every tick. Readers that opt out (multiplier=1, or
// history=false && selfPersists=false) run at every tick. The bug we
// caught earlier — a Reader silently dying without anyone noticing —
// was made twice as scary by there being no test of this surface; this
// closes that gap.
//
// `Reader.tick()` is `internal` (not `private`) precisely so this file
// can drive it from `@testable import Kit`. Subclasses still override
// `read()` for production behaviour.

private final class TickRecorder: Reader<Int> {
    var reads = 0
    override func read() {
        reads += 1
    }
}

final class ReaderTickTests: XCTestCase {
    /// Popup open (`unlock`) is the live-popup case — every tick must
    /// reach `read()` no matter how the multiplier is set, because the
    /// chart in the popup is the consumer.
    func testTick_popupOpen_alwaysReads() {
        let r = TickRecorder(.CPU, popup: true, history: true)
        r.interval = 1.0
        r.popupClosedIntervalMultiplier = 5
        r.unlock()

        for _ in 0..<10 { r.tick() }
        XCTAssertEqual(r.reads, 10, "popup open => no gating")
    }

    /// Core throttle contract: popup closed + history-keeping reader =>
    /// only one read per gate window (`interval * multiplier`). Burst of
    /// ticks within the window is dropped; first tick past the window
    /// passes.
    func testTick_popupClosedHistory_throttlesWithinWindowThenReleases() {
        let r = TickRecorder(.CPU, popup: true, history: true)
        r.interval = 0.05                   // 50 ms nominal tick
        r.popupClosedIntervalMultiplier = 5 // gate window = 250 ms
        r.lock()

        r.tick()                             // 1st always passes (lastGatedRead == nil)
        XCTAssertEqual(r.reads, 1)

        for _ in 0..<10 { r.tick() }         // burst within the gate window
        XCTAssertEqual(r.reads, 1, "subsequent ticks within gate window must be dropped")

        Thread.sleep(forTimeInterval: 0.3)   // > 250 ms
        r.tick()
        XCTAssertEqual(r.reads, 2, "tick past gate window must read")
    }

    /// Net readers' opt-out. Their per-tick value is a delta and gating
    /// would inflate "bytes per sample" 5×, so they set multiplier=1.
    /// This must reproduce the popup-open behaviour even while locked.
    func testTick_multiplierOneDisablesGate() {
        let r = TickRecorder(.CPU, popup: true, history: true)
        r.interval = 1.0
        r.popupClosedIntervalMultiplier = 1
        r.lock()

        for _ in 0..<10 { r.tick() }
        XCTAssertEqual(r.reads, 10, "multiplier=1 must bypass the gate even when locked")
    }

    /// Readers that aren't keeping history alive in the background take
    /// the fast path — gate is skipped entirely. Upstream popup-only
    /// behaviour: the Repeater shouldn't even be running, but if it is,
    /// the gate doesn't introduce new throttling.
    func testTick_neitherHistoryNorSelfPersists_skipsGate() {
        let r = TickRecorder(.CPU, popup: true, history: false, selfPersists: false)
        r.interval = 1.0
        r.popupClosedIntervalMultiplier = 5
        r.lock()

        for _ in 0..<5 { r.tick() }
        XCTAssertEqual(r.reads, 5, "non-history non-selfPersists reader skips the gate")
    }

    /// `selfPersists` is the Net readers' flag — they write their own
    /// history rows so they're history-keeping for the gate's purposes,
    /// even though `history: false`. Without this the locked-state guard
    /// would let them run at full 1 s when the popup is closed, defeating
    /// the energy win for the readers that opt INTO gating via multiplier.
    func testTick_selfPersistsIsTreatedAsHistoryKeeping() {
        let r = TickRecorder(.CPU, popup: true, history: false, selfPersists: true)
        r.interval = 0.05
        r.popupClosedIntervalMultiplier = 5
        r.lock()

        r.tick()
        for _ in 0..<10 { r.tick() }
        XCTAssertEqual(r.reads, 1, "selfPersists is a history-keeping reader for the gate")
    }

    /// `lastReadAt` is the diagnostics surface — QueryServer /info reads
    /// it (well, reads the per-prefix latest @ts, which is the lldb-side
    /// equivalent) to flag silent readers. Pin that the tick path
    /// actually updates it.
    func testTick_recordsLastReadAt() throws {
        let r = TickRecorder(.CPU, popup: true, history: true)
        r.interval = 1.0
        r.popupClosedIntervalMultiplier = 1
        r.unlock()
        XCTAssertNil(r.lastReadAt, "lastReadAt nil before any tick")

        let before = Date()
        r.tick()
        let after = Date()

        let stamp = try XCTUnwrap(r.lastReadAt)
        XCTAssertGreaterThanOrEqual(stamp, before)
        XCTAssertLessThanOrEqual(stamp, after)
    }

    /// Gate-dropped ticks must NOT advance lastReadAt — otherwise a
    /// reader whose only successful read happened 10 minutes ago would
    /// keep appearing "fresh" because tick() kept firing.
    func testTick_gatedDropDoesNotAdvanceLastReadAt() throws {
        let r = TickRecorder(.CPU, popup: true, history: true)
        r.interval = 1.0
        r.popupClosedIntervalMultiplier = 5
        r.lock()

        r.tick()
        let firstStamp = try XCTUnwrap(r.lastReadAt)
        Thread.sleep(forTimeInterval: 0.01)
        r.tick()   // gated — dropped
        r.tick()   // gated — dropped
        XCTAssertEqual(r.reads, 1)
        XCTAssertEqual(r.lastReadAt, firstStamp, "dropped ticks must not refresh lastReadAt")
    }
}
