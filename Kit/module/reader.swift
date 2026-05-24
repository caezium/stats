//
//  reader.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 10/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

public protocol Reader_p {
    var popup: Bool { get }
    var preview: Bool { get }
    var sleep: Bool { get }
    
    func setup()
    func read()
    func terminate()
    
    func start()
    func pause()
    func stop()
    
    func lock()
    func unlock()
    
    func initStoreValues(title: String)
    func setInterval(_ value: Int)
    func sleepMode(state: Bool)
}

public protocol ReaderInternal_p {
    associatedtype T
    
    var value: T? { get }
    func read()
}

open class Reader<T: Codable>: NSObject, ReaderInternal_p {
    public var log: NextLog {
        NextLog.shared.copy(category: "\(String(describing: self))")
    }
    private let valueQueue = DispatchQueue(label: "eu.exelban.readerActiveQueue")
    private var _value: T?
    public var value: T? {
        get { self.valueQueue.sync { self._value } }
        set { self.valueQueue.sync { self._value = newValue } }
    }
    public var name: String {
        String(NSStringFromClass(type(of: self)).split(separator: ".").last ?? "unknown")
    }
    
    public var interval: Double? = nil
    public var defaultInterval: Int = 1
    public var optional: Bool = false
    public var popup: Bool = false
    public var preview: Bool = false
    public var sleep: Bool = false
    
    public var alignToSecondBoundary: Bool = false
    public var alignOffset: TimeInterval = 0
    
    public var callbackHandler: (T?) -> Void
    
    private let module: ModuleType
    private var history: Bool
    private var repeatTask: Repeater?
    private var locked: Bool = true
    private var initlizalized: Bool = false
    
    private let activeQueue = DispatchQueue(label: "eu.exelban.readerActiveQueue")
    private var _active: Bool = false
    public var active: Bool {
        get { self.activeQueue.sync { self._active } }
        set { self.activeQueue.sync { self._active = newValue } }
    }
    
    private var lastDBWrite: Date? = nil

    /// How often the auto-persist path commits a timestamped row to the lldb
    /// history. 60 s by default — for CPU/RAM/Battery/Temp/Freq the user does
    /// not need per-second granularity in the History view, and the previous
    /// behaviour (`interval * 10` → about every 18 s) accounted for ~15 MB of
    /// the per-prefix weekly storage cost. The live popup still updates at
    /// `interval` (the callback's `callbackHandler` fires every read);
    /// only the on-disk cadence is throttled.
    ///
    /// Readers that need denser history (currently: none — Network does its
    /// own explicit insert at 1 s through `history: false`) can override this
    /// in their construction site.
    public var historyCadenceSeconds: TimeInterval = 60

    /// When the popup is closed (`locked == true`) AND the reader is keeping
    /// itself alive for history (`history: true`), the Repeater still fires
    /// every `interval` seconds (typically 1 s). Each tick may run expensive
    /// per-process kernel calls the user can't even see — the dominant
    /// energy cost of running Stats with history enabled. This multiplier
    /// gates the actual `read()` so we only pay that cost every
    /// `interval * popupClosedIntervalMultiplier` seconds while the popup
    /// is closed. Default 5 cuts CPU ~5× for the snapshot-based readers
    /// (CPU/RAM/Battery/Sensors).
    ///
    /// Net readers (UsageReader / ProcessReader) override to 1 because their
    /// per-app bandwidth math is delta-based — skipping ticks would coarsen
    /// the deltas and inflate "bytes per sample" in the chart.
    public var popupClosedIntervalMultiplier: Int = 5

    private var lastGatedRead: Date?

    private var alignWorkItem: DispatchWorkItem?
    private let alignQueue = DispatchQueue(label: "eu.exelban.readerAlignQueue")

    /// True when the reader takes responsibility for writing its own
    /// timestamped history rows (via explicit `DB.shared.insert(..., ts: true)`
    /// inside `read()`) and therefore needs to keep running in the background
    /// like a `history: true` reader does. Set by callers that pass
    /// `history: false` only to avoid the base-class auto-persist colliding
    /// with their custom schema (e.g. the Net readers: their compact
    /// `{upload,download}` rows would be silently destroyed at tier rollup
    /// if the auto-persist also wrote a `Network_Usage`-shaped row at the
    /// same key). Without this flag those readers go dormant when the
    /// popup closes and the chart's time-series goes dark.
    public var selfPersists: Bool = false

    public init(_ module: ModuleType, popup: Bool = false, preview: Bool = false, history: Bool = true, selfPersists: Bool = false, callback: @escaping (T?) -> Void = {_ in }) {
        self.popup = popup
        self.preview = preview
        self.module = module
        self.history = history
        self.selfPersists = selfPersists
        self.callbackHandler = callback
        
        super.init()
        DB.shared.setup(T.self, "\(module.stringValue)@\(self.name)")
        if let lastValue = DB.shared.findOne(T.self, key: "\(module.stringValue)@\(self.name)") {
            self.value = lastValue
            callback(lastValue)
        }
        self.setup()
        
        debug("Successfully initialize reader", log: self.log)
    }
    
    deinit {
        DB.shared.insert(key: "\(self.module.stringValue)@\(self.name)", value: self.value, ts: self.history)
    }
    
    public func initStoreValues(title: String) {
        guard self.interval == nil else { return }
        let updateInterval = Store.shared.int(key: "\(title)_updateInterval", defaultValue: self.defaultInterval)
        self.interval = Double(updateInterval)
    }
    
    public func callback(_ value: T?) {
        let moduleKey = "\(self.module.stringValue)@\(self.name)"
        self.value = value
        if let value {
            self.callbackHandler(value)
            SystemStats.shared.send(key: moduleKey, value: value)
            // Throttle disk writes to `historyCadenceSeconds` (default 60 s).
            // The popup still gets every read via callbackHandler above; only
            // the on-disk time series is sampled.
            let now = Date()
            if self.lastDBWrite == nil
                || now.timeIntervalSince(self.lastDBWrite!) >= self.historyCadenceSeconds {
                DB.shared.insert(key: moduleKey, value: value, ts: self.history)
                self.lastDBWrite = now
            }
        }
    }
    
    open func read() {}
    open func setup() {}
    open func terminate() {}

    /// Repeater entry point. Wraps `read()` so we can gate the actual work
    /// when the popup is closed and we're only running for history's sake.
    /// Called from the Repeater closures in `startNormalRepeater` /
    /// `startAlignedRepeater` instead of `read()` directly.
    ///
    /// `internal` (rather than `private`) so `Tests/HistoryDB.swift` can drive
    /// the gate directly from `@testable import Kit` — see `ReaderTickTests`.
    /// Not part of the public Reader contract; subclasses still override
    /// `read()`, not this.
    internal func tick() {
        // Fast path — popup open, or this reader has no business writing
        // history rows in the background, or gating is disabled. Always read.
        let keepsHistoryAlive = self.history || self.selfPersists
        guard self.locked, keepsHistoryAlive, self.popupClosedIntervalMultiplier > 1 else {
            self.read()
            self.lastReadAt = Date()
            return
        }
        let interval = self.interval ?? 1.0
        let gateSeconds = interval * Double(self.popupClosedIntervalMultiplier)
        let now = Date()
        if let last = self.lastGatedRead, now.timeIntervalSince(last) < gateSeconds {
            return
        }
        self.lastGatedRead = now
        self.read()
        self.lastReadAt = now
    }

    /// Wall-clock time `tick()` last invoked `read()`. Surfaced via the
    /// QueryServer so consumers (the History view's toolbar, an MCP probe)
    /// can detect a reader that's gone silent without restarting Stats. Nil
    /// until the first successful tick. Not thread-safe — only `tick()`
    /// writes it, and `tick()` runs on the Repeater queue.
    public private(set) var lastReadAt: Date?
    
    open func start() {
        // Upstream behavior: popup/preview readers only run on-demand and
        // bail out early when the popup window is closed (`locked`). For
        // history-enabled readers (including ones that persist their own
        // history via `selfPersists`) we override that — we want the data
        // to accumulate even when the user never opens the popup, otherwise
        // the per-process readers (CPU/RAM/Net/Disk/Battery) end up with
        // a near-empty time series.
        if (self.popup || self.preview) && self.locked && !self.history && !self.selfPersists {
            DispatchQueue.global(qos: .background).async {
                self.read()
            }
            return
        }

        if !self.initlizalized {
            if self.alignToSecondBoundary {
                self.startAlignedRepeater()
            } else {
                self.startNormalRepeater()
                DispatchQueue.global(qos: .background).async { self.read() }
                self.repeatTask?.start()
            }
            self.initlizalized = true
        } else {
            self.repeatTask?.start()
        }

        self.active = true
    }
    
    open func pause() {
        self.alignWorkItem?.cancel()
        self.repeatTask?.pause()
        self.active = false
    }
    
    open func stop() {
        self.alignWorkItem?.cancel()
        self.repeatTask?.pause()
        self.repeatTask = nil
        self.active = false
        self.initlizalized = false
    }
    
    public func setInterval(_ value: Int) {
        debug("Set update interval: \(value) sec", log: self.log)
        self.interval = Double(value)
        
        if self.alignToSecondBoundary {
            self.repeatTask?.pause()
            self.repeatTask = nil
            self.alignWorkItem?.cancel()
            if self.active {
                self.startAlignedRepeater()
            }
        } else {
            self.repeatTask?.reset(seconds: value, restart: true)
        }
    }
    
    public func save(_ value: T) {
        DB.shared.insert(key: "\(self.module.stringValue)@\(self.name)", value: value, ts: self.history, force: true)
    }
    
    private func delayToNextSecondBoundary() -> TimeInterval {
        let now = Date().addingTimeInterval(self.alignOffset)
        let fractional = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1.0)
        let baseDelay = (fractional == 0) ? 0.0 : (1.0 - fractional)
        let safety: TimeInterval = 0.005 // 5ms past the boundary
        return baseDelay + safety
    }
    
    private func startNormalRepeater() {
        guard let interval = self.interval, self.repeatTask == nil else { return }
        
        if !self.popup && !self.preview {
            debug("Set up update interval: \(Int(interval)) sec", log: self.log)
        }
        
        self.repeatTask = Repeater(seconds: Int(interval)) { [weak self] in
            self?.tick()
        }
    }

    private func startAlignedRepeater() {
        guard let interval = self.interval, self.repeatTask == nil else { return }
        
        if !self.popup && !self.preview {
            debug("Set up update interval: \(Int(interval)) sec (aligned)", log: self.log)
        }
        
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }

            self.tick()
            self.repeatTask = Repeater(seconds: Int(interval)) { [weak self] in
                self?.tick()
            }
            self.repeatTask?.start()
        }
        
        self.alignWorkItem?.cancel()
        self.alignWorkItem = work
        self.alignQueue.asyncAfter(deadline: .now() + self.delayToNextSecondBoundary(), execute: work)
    }
    
    public func sleepMode(state: Bool) {
        guard state != self.sleep else { return }

        debug("Sleep mode: \(state ? "on" : "off")", log: self.log)
        self.sleep = state

        if state {
            self.pause()
        } else {
            self.start()
        }
    }
}

extension Reader: Reader_p {
    public func lock() {
        self.locked = true
    }
    
    public func unlock() {
        self.locked = false
    }
}
