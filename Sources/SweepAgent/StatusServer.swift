import Foundation
import Network
import MacCleanKit

/// Read-only JSON endpoint for the Web UI plugin.
///
/// The client plugin runs in the browser and cannot read local files, so the
/// already-running helper serves a tiny loopback HTTP endpoint instead. It is
/// read-only, bound to 127.0.0.1, and sends permissive CORS headers because the
/// Harness page uses a different port.
public final class StatusServer {
    public static let defaultPort: UInt16 = 47901
    /// The listener's handlers capture `self` weakly, so the instance must be
    /// retained for the lifetime of the process.
    public static let shared = StatusServer()

    private let port: UInt16
    private let queue = DispatchQueue(label: "sweep.status")
    private var listener: NWListener?

    // Parsing a 10 MB snapshot on every poll would be wasteful; cache by mtime.
    private struct Cached {
        let mtime: Date?
        let groups: [[String: Any]]
        let total: UInt64
    }
    private var cache: [String: Cached] = [:]

    public init(port: UInt16 = StatusServer.defaultPort) {
        self.port = port
    }

    public func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Loopback only: this endpoint must not be reachable from the LAN.
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: port)!
            )
            // With requiredLocalEndpoint set, the port comes from that endpoint;
            // passing `on:` as well yields EINVAL.
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
            FileHandle.standardError.write(Data("sweep helper: status on http://127.0.0.1:\(port)/status\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("sweep helper: status server failed: \(error)\n".utf8))
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let request = Self.parse(accumulated) {
                self.respond(to: request, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: accumulated)
            }
        }
    }

    /// Minimal HTTP/1.1 request reader: headers, then Content-Length bytes.
    static func parse(_ data: Data) -> WebApp.Request? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[data.startIndex..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }

        let pathWithQuery = requestLine[1]
        let parts = pathWithQuery.components(separatedBy: "?")
        let path = parts.first ?? "/"
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }

        var contentLength = 0
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = separator.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<data.index(bodyStart, offsetBy: contentLength))

        return WebApp.Request(
            method: requestLine[0].uppercased(),
            path: path,
            query: query,
            body: body
        )
    }

    private func respond(to request: WebApp.Request, on connection: NWConnection) {
        let response: WebApp.Response
        if request.path == "/status" {
            let body = payload(for: request.method)
            response = WebApp.Response(status: 200, contentType: "application/json; charset=utf-8", body: Data(body.utf8))
        } else {
            response = WebApp.route(request)
        }

        let head = """
        HTTP/1.1 \(response.status) OK\r
        Content-Type: \(response.contentType)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type\r
        Cache-Control: no-store\r
        Content-Length: \(response.body.count)\r
        Connection: close\r
        \r

        """
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func payload(for request: String) -> String {
        if request.hasPrefix("OPTIONS") { return "{}" }

        let status: [String: Any] = [
            "generatedAt": Util.nowISO(),
            "disk": diskPayload(),
            "mode": AgentConfigStore.load().mode,
            "fullDiskAccess": FullDiskAccess.hasAccess(),
            "helper": ["pid": Int(getpid())],
            "latest": latestSnapshotPayload() as Any,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{\"error\":\"encode failed\"}" }
        return text
    }

    private func diskPayload() -> [String: Any] {
        let url = URL(fileURLWithPath: "/System/Volumes/Data")
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = UInt64(values?.volumeTotalCapacity ?? 0)
        let available = UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        return [
            "totalBytes": total,
            "availableBytes": available,
            "usedBytes": total > available ? total - available : 0,
        ]
    }

    private func latestSnapshotPayload() -> [String: Any]? {
        let directory = AgentPaths.snapshots
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        // The panel belongs to the cleanup story, so prefer the newest system
        // junk scan; a narrow scan (large files only) is a poor status summary.
        // Falling back to the newest snapshot keeps it honest when there is none.
        let ordered = files
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return left > right
            }
        let junk = ordered.first { $0.lastPathComponent.hasPrefix("system-junk") }
        let candidates = junk.map { [$0] } ?? Array(ordered.prefix(1))

        var best: (url: URL, cached: Cached)?

        for url in candidates {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let element: Cached
            if let existing = cache[url.path], existing.mtime == modified {
                element = existing
            } else {
                guard let groups = summarize(url) else { continue }
                let total = groups.reduce(UInt64(0)) { $0 &+ ($1["bytes"] as? UInt64 ?? 0) }
                element = Cached(mtime: modified, groups: groups, total: total)
                cache[url.path] = element
            }
            if best == nil || element.total > best!.cached.total {
                best = (url, element)
            }
        }

        guard let best else { return nil }
        return [
            "snapshot": best.url.lastPathComponent,
            "modified": Util.iso(best.cached.mtime) as Any,
            "totalBytes": best.cached.total,
            "groups": best.cached.groups,
        ]
    }

    private func summarize(_ url: URL) -> [[String: Any]]? {
        if let cached = SnapshotCache.shared.getIfLoaded(path: url.path) {
            return cached.byCategory
                .map { key, items -> [String: Any] in
                    let bytes = items.reduce(UInt64(0)) { $0 &+ $1.entry.bytes }
                    return [
                        "category": key.isEmpty ? "unknown" : key,
                        "label": CategoryLabels.label(key.isEmpty ? "unknown" : key),
                        "bytes": bytes,
                        "items": items.count,
                    ]
                }
                .sorted { ($0["bytes"] as? UInt64 ?? 0) > ($1["bytes"] as? UInt64 ?? 0) }
        }

        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([ScanEntry].self, from: data)
        else { return nil }

        var totals: [String: (bytes: UInt64, count: Int)] = [:]
        for entry in entries {
            let key = entry.category ?? "unknown"
            var current = totals[key] ?? (0, 0)
            current.bytes &+= entry.bytes
            current.count += 1
            totals[key] = current
        }

        return totals
            .map { key, value -> [String: Any] in
                [
                    "category": key,
                    "label": CategoryLabels.label(key),
                    "bytes": value.bytes,
                    "items": value.count,
                ]
            }
            .sorted { ($0["bytes"] as? UInt64 ?? 0) > ($1["bytes"] as? UInt64 ?? 0) }
    }
}
