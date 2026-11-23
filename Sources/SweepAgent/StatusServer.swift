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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let body = self.payload(for: request)
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json; charset=utf-8\r
            Access-Control-Allow-Origin: *\r
            Access-Control-Allow-Methods: GET, OPTIONS\r
            Cache-Control: no-store\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
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
