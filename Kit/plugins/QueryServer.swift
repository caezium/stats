//
//  QueryServer.swift
//  Kit
//
//  Localhost JSON query API for the time-series store. The MCP server
//  for Claude Code (and any other external client) hits this.
//
//  Design notes:
//  - Bound to 127.0.0.1 only. The listener is created with NWParameters
//    that pin the local endpoint to loopback, and an additional defensive
//    check rejects any non-loopback peer at accept time.
//  - Speaks a tiny subset of HTTP/1.1 (GET only, single request per
//    connection, Connection: close). No external deps.
//  - All payloads are JSON. Stored values are already JSON strings so
//    they're inlined verbatim into responses.
//

import Foundation
import Network

public final class QueryServer {
    public static let shared = QueryServer()

    public var port: UInt16 {
        UInt16(Store.shared.int(key: "history_query_port", defaultValue: 9276))
    }

    public var enabled: Bool {
        get { Store.shared.bool(key: "history_query_enabled", defaultValue: true) }
        set {
            Store.shared.set(key: "history_query_enabled", value: newValue)
            if newValue { self.start() } else { self.stop() }
        }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "eu.exelban.queryserver")
    private let log = NextLog.shared.copy(category: "QueryServer")

    public func start() {
        guard self.enabled else { return }
        guard self.listener == nil else { return }

        guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
            error("Invalid port: \(self.port)", log: self.log)
            return
        }

        do {
            let parameters = NWParameters.tcp
            // Pin to loopback so we never accept off-host connections, even if
            // a future macOS firewall change loosens defaults. When the
            // required local endpoint already has a port, we must NOT pass
            // a port to the listener init — that errors with
            // "Local endpoint has port set, cannot override to ...".
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: nwPort
            )

            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    info("QueryServer listening on 127.0.0.1:\(self.port)", log: self.log)
                case .failed(let err):
                    error("QueryServer failed: \(err)", log: self.log)
                    self.listener = nil
                case .cancelled:
                    debug("QueryServer cancelled", log: self.log)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            listener.start(queue: self.queue)
            self.listener = listener
        } catch let err {
            error("QueryServer start error: \(err)", log: self.log)
        }
    }

    public func stop() {
        self.listener?.cancel()
        self.listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        guard self.isLoopback(conn.endpoint) else {
            conn.cancel()
            return
        }
        conn.start(queue: self.queue)
        self.receive(conn, accumulated: Data())
    }

    private func receive(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, recvError in
            guard let self = self else { conn.cancel(); return }

            if let recvError = recvError {
                debug("QueryServer recv error: \(recvError)", log: self.log)
                conn.cancel()
                return
            }

            var buffer = accumulated
            if let data = data { buffer.append(data) }

            if let header = String(data: buffer, encoding: .utf8),
               header.contains("\r\n\r\n") || isComplete {
                self.dispatch(header, on: conn)
                return
            }

            if isComplete {
                conn.cancel()
                return
            }

            self.receive(conn, accumulated: buffer)
        }
    }

    private func dispatch(_ raw: String, on conn: NWConnection) {
        guard let firstLine = raw.split(separator: "\r\n", maxSplits: 1).first else {
            self.send(Self.errorJSON("malformed request"), on: conn); return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            self.send(Self.errorJSON("only GET supported"), on: conn); return
        }
        let target = String(parts[1])
        let split = target.split(separator: "?", maxSplits: 1)
        let path = String(split[0])

        // HTML routes get their own response path so we can stream the file.
        switch path {
        case "/", "/dashboard", "/dashboard/", "/index.html":
            if let html = self.loadDashboardHTML() {
                self.sendHTML(html, on: conn)
            } else {
                self.sendStatus(404, "dashboard not found — see HISTORY_MCP.md", on: conn)
            }
            return
        default:
            self.send(self.route(raw), on: conn)
        }
    }

    private func loadDashboardHTML() -> String? {
        // Search order:
        //  1) Bundled into the app (Resources/dashboard/index.html) when packaged.
        //  2) Source tree dashboard/index.html for dev iteration.
        //  3) ~/Library/Application Support/Stats/dashboard.html as a user override.
        let fm = FileManager.default
        var candidates: [URL] = []

        if let bundled = Bundle(for: type(of: self)).url(forResource: "index", withExtension: "html", subdirectory: "dashboard") {
            candidates.append(bundled)
        }
        if let main = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "dashboard") {
            candidates.append(main)
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            candidates.append(URL(fileURLWithPath: home).appendingPathComponent("Desktop/stats/dashboard/index.html"))
            candidates.append(URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Stats/dashboard.html"))
        }

        for url in candidates {
            if fm.fileExists(atPath: url.path), let html = try? String(contentsOf: url, encoding: .utf8) {
                return html
            }
        }
        return nil
    }

    private func send(_ json: String, on conn: NWConnection) {
        let body = Data(json.utf8)
        let head = """
HTTP/1.1 200 OK\r
Content-Type: application/json; charset=utf-8\r
Content-Length: \(body.count)\r
Cache-Control: no-store\r
Access-Control-Allow-Origin: *\r
Connection: close\r
\r

"""
        var payload = Data(head.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func sendHTML(_ html: String, on conn: NWConnection) {
        let body = Data(html.utf8)
        let head = """
HTTP/1.1 200 OK\r
Content-Type: text/html; charset=utf-8\r
Content-Length: \(body.count)\r
Cache-Control: no-store\r
Connection: close\r
\r

"""
        var payload = Data(head.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func sendStatus(_ code: Int, _ message: String, on conn: NWConnection) {
        let body = Data("\(code) \(message)\n".utf8)
        let head = """
HTTP/1.1 \(code) \(message)\r
Content-Type: text/plain; charset=utf-8\r
Content-Length: \(body.count)\r
Connection: close\r
\r

"""
        var payload = Data(head.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - Routing

    private func route(_ raw: String) -> String {
        guard let firstLine = raw.split(separator: "\r\n", maxSplits: 1).first else {
            return Self.errorJSON("malformed request")
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            return Self.errorJSON("only GET supported")
        }
        let target = String(parts[1])
        let split = target.split(separator: "?", maxSplits: 1)
        let path = String(split[0])
        let query: [String: String] = {
            guard split.count == 2 else { return [:] }
            var dict: [String: String] = [:]
            for pair in split[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                dict[k] = v
            }
            return dict
        }()

        switch path {
        case "/health":
            return "{\"ok\":true,\"app\":\"Stats\",\"port\":\(self.port)}"

        case "/info":
            let prefixes = DB.shared.listPrefixes()
            let retentionDays = Store.shared.int(key: "history_retention_days", defaultValue: 7)
            let now = Date().currentTimeSeconds()
            let payload: [String: Any] = [
                "now": now,
                "retention_days": retentionDays,
                "prefixes": prefixes
            ]
            return Self.jsonString(payload)

        case "/modules":
            return Self.jsonString(["modules": DB.shared.listPrefixes()])

        case "/metrics":
            guard let prefix = query["prefix"], !prefix.isEmpty else {
                return Self.errorJSON("missing 'prefix' query param")
            }
            let since = query["since"].flatMap(Int.init)
            let until = query["until"].flatMap(Int.init)
            let bucket = query["bucket"].flatMap(Int.init)

            let series = DB.shared.findTimeSeries(prefix: prefix, since: since, until: until)
            if let bucket = bucket, bucket > 0 {
                return Self.serializeBucketed(series, bucket: bucket)
            }
            return Self.serializeSeries(series)

        case "/latest":
            guard let prefix = query["prefix"], !prefix.isEmpty else {
                return Self.errorJSON("missing 'prefix' query param")
            }
            if let last = DB.shared.findLatestTimeSeries(prefix: prefix) {
                return "{\"ts\":\(last.ts),\"value\":\(last.json)}"
            }
            return "{\"ts\":null,\"value\":null}"

        default:
            return Self.errorJSON("not found: \(path)")
        }
    }

    // MARK: - Helpers

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let addr):
                return addr.isLoopback
            case .ipv6(let addr):
                return addr.isLoopback
            case .name(let str, _):
                return str == "localhost"
            @unknown default:
                return false
            }
        }
        return false
    }

    private static func errorJSON(_ msg: String) -> String {
        let safe = msg.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"error\":\"\(safe)\"}"
    }

    private static func jsonString(_ obj: Any) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: []),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    /// Stored values are already JSON, so we inline them verbatim into the
    /// outer array rather than re-encoding.
    private static func serializeSeries(_ series: [(ts: Int, json: String)]) -> String {
        var out = "["
        var first = true
        for entry in series {
            if !first { out.append(",") }
            first = false
            out.append("{\"ts\":\(entry.ts),\"value\":")
            out.append(entry.json)
            out.append("}")
        }
        out.append("]")
        return out
    }

    /// Group by `floor(ts / bucket)`, emit one row per bucket containing the last
    /// raw value seen in that window. Cheap downsampling for long-range queries.
    private static func serializeBucketed(_ series: [(ts: Int, json: String)], bucket: Int) -> String {
        guard bucket > 0 else { return serializeSeries(series) }
        var lastByBucket: [Int: (ts: Int, json: String)] = [:]
        for entry in series {
            let b = entry.ts / bucket
            if let existing = lastByBucket[b] {
                if entry.ts > existing.ts { lastByBucket[b] = entry }
            } else {
                lastByBucket[b] = entry
            }
        }
        let bucketed = lastByBucket.values.sorted { $0.ts < $1.ts }
        var out = "["
        var first = true
        for entry in bucketed {
            if !first { out.append(",") }
            first = false
            out.append("{\"ts\":\(entry.ts),\"value\":")
            out.append(entry.json)
            out.append("}")
        }
        out.append("]")
        return out
    }
}
