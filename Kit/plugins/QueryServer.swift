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

            // We only need the request line + headers to route a GET.
            if let header = String(data: buffer, encoding: .utf8),
               header.contains("\r\n\r\n") || isComplete {
                let response = self.route(header)
                self.send(response, on: conn)
                return
            }

            if isComplete {
                conn.cancel()
                return
            }

            self.receive(conn, accumulated: buffer)
        }
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
            // Blocking: MCP `health` and `summarize_period` rely on the full prefix
            // list to drive their workflow. Returning empty during the cold-start
            // cache window would silently produce wrong agent output.
            let prefixes = DB.shared.listPrefixesBlocking()
            let retentionDays = Store.shared.int(key: "history_retention_days", defaultValue: 7)
            let now = Date().currentTimeSeconds()

            // Per-prefix staleness — for each prefix, the most recent
            // timestamped row's age in seconds. Lets the History view warn
            // about dead readers (e.g. the FrequencyReader Task deadlock
            // bug) without restarting Stats. `nil`/missing entry means we
            // couldn't find any timestamped row at all for that prefix —
            // distinct from "old data": brand-new prefixes show up here.
            var staleness: [[String: Any]] = []
            staleness.reserveCapacity(prefixes.count)
            for prefix in prefixes {
                if let latest = DB.shared.findLatestTimeSeries(prefix: prefix) {
                    staleness.append([
                        "prefix": prefix,
                        "latest_ts": latest.ts,
                        "age_seconds": max(0, now - latest.ts)
                    ])
                } else {
                    staleness.append([
                        "prefix": prefix,
                        "latest_ts": NSNull(),
                        "age_seconds": NSNull()
                    ])
                }
            }

            let payload: [String: Any] = [
                "now": now,
                "retention_days": retentionDays,
                "prefixes": prefixes,
                "readers": staleness
            ]
            return Self.jsonString(payload)

        case "/modules":
            return Self.jsonString(["modules": DB.shared.listPrefixesBlocking()])

        case "/metrics":
            guard let prefix = query["prefix"], !prefix.isEmpty else {
                return Self.errorJSON("missing 'prefix' query param")
            }
            let since = query["since"].flatMap(Int.init)
            let until = query["until"].flatMap(Int.init)
            let bucket = query["bucket"].flatMap(Int.init)

            // When the caller passes `bucket`, route through the streaming stride
            // sampler instead of materializing the whole range. A 7-day query on
            // Network@ProcessReader is ~600k rows × ~1KB; pulling it all into the
            // QueryServer's address space just to group by floor(ts/bucket) and
            // throw most of it away was the same freeze as the History view.
            // Stride-sampled retrieval pays only for the rows it returns.
            if let bucket = bucket, bucket > 0 {
                let now = Date().currentTimeSeconds()
                let lo = max(0, since ?? 0)
                let hi = until ?? now
                let series = DB.shared.findTimeSeriesByStride(
                    prefix: prefix, since: lo, until: hi, strideSec: bucket
                )
                return Self.serializeSeries(series)
            }

            let series = DB.shared.findTimeSeries(prefix: prefix, since: since, until: until)
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

    // (Bucketed serialization moved into the query layer: `/metrics?bucket=N`
    //  now routes to `DB.findTimeSeriesByStride` so the QueryServer never has
    //  to materialize a multi-GB raw window just to throw most of it away.)
}
