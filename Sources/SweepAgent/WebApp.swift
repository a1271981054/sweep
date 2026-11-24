import Foundation
import Network
import MacCleanKit

/// Local web app served by the helper (which holds Full Disk Access).
///
/// Static assets live in `~/.local/share/sweep/web/` so the interface can change
/// without rebuilding — a rebuild would change the helper's signature and cost
/// the user another permission grant.
public enum WebApp {
    public static var assetDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/sweep/web", isDirectory: true)
    }

    public struct Request {
        public let method: String
        public let path: String
        public let query: [String: String]
        public let body: Data
    }

    public struct Response {
        public let status: Int
        public let contentType: String
        public let body: Data

        static func json(_ object: [String: Any], status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return Response(status: status, contentType: "application/json; charset=utf-8", body: data)
        }

        static func text(_ string: String, status: Int = 200, type: String = "text/plain; charset=utf-8") -> Response {
            Response(status: status, contentType: type, body: Data(string.utf8))
        }
    }

    // MARK: - Routing

    public static func route(_ request: Request) -> Response {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return asset("index.html", type: "text/html; charset=utf-8")
        case ("GET", "/app.css"):
            return asset("app.css", type: "text/css; charset=utf-8")
        case ("GET", "/app.js"):
            return asset("app.js", type: "application/javascript; charset=utf-8")
        case ("GET", "/api/state"):
            return state()
        case ("POST", "/api/scan"):
            return ScanJobs.shared.start()
        case ("GET", "/api/job"):
            return job(request.query["id"] ?? "")
        case ("POST", "/api/plan"):
            return plan(request.body)
        case ("POST", "/api/apply"):
            return apply(request.body)
        case ("POST", "/api/restore"):
            return restore(request.body)
        default:
            return .json(["error": "not found"], status: 404)
        }
    }

    // MARK: - Static assets

    static func asset(_ name: String, type: String) -> Response {
        let url = assetDirectory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            return .text("asset missing: \(name)", status: 500)
        }
        return Response(status: 200, contentType: type, body: data)
    }

    // MARK: - State

    static func state() -> Response {
        let url = URL(fileURLWithPath: "/System/Volumes/Data")
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = UInt64(values?.volumeTotalCapacity ?? 0)
        let available = UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0)

        let ops = OperationLog.all().suffix(5).map { record -> [String: Any] in
            [
                "id": record.id,
                "createdAt": record.createdAt,
                "bytes": record.bytes,
                "okCount": record.okCount,
                "failCount": record.failCount,
            ]
        }

        return .json([
            "disk": [
                "totalBytes": total,
                "availableBytes": available,
                "usedBytes": total > available ? total - available : 0,
            ],
            "mode": AgentConfigStore.load().mode,
            "fullDiskAccess": FullDiskAccess.hasAccess(),
            "operations": Array(ops),
        ])
    }

    // MARK: - Scan job

    static func job(_ id: String) -> Response {
        guard let job = ScanJobs.shared.get(id) else {
            return .json(["error": "unknown job"], status: 404)
        }
        return .json(job)
    }

    // MARK: - Plan

    static func plan(_ body: Data) -> Response {
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let selections = payload["selections"] as? [[String: Any]]
        else {
            return .json(["error": "selections required"], status: 400)
        }

        let minBytes = UInt64(max(payload["minBytes"] as? Int ?? 0, 0))
        var entries: [ScanEntry] = []

        for selection in selections {
            guard let snapshotPath = selection["snapshot"] as? String,
                  let categories = selection["categories"] as? [String]
            else { continue }
            let url = URL(fileURLWithPath: (snapshotPath as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url),
                  let all = try? JSONDecoder().decode([ScanEntry].self, from: data)
            else { continue }
            entries.append(contentsOf: all.filter {
                categories.contains($0.category ?? "") && $0.bytes >= minBytes
            })
        }

        guard !entries.isEmpty else {
            return .json(["error": "nothing selected"], status: 400)
        }

        do {
            let plan = try PlanStore.create(
                from: entries,
                ids: entries.map(\.id)
            )
            return .json([
                "planId": plan.id,
                "digest": plan.digest,
                "count": plan.entries.count,
                "totalBytes": plan.totalBytes,
            ])
        } catch {
            return .json(["error": error.localizedDescription], status: 400)
        }
    }

    // MARK: - Apply

    static func apply(_ body: Data) -> Response {
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let planId = payload["planId"] as? String
        else {
            return .json(["error": "planId required"], status: 400)
        }

        do {
            let record = try Cleaner.apply(planId: planId, digest: payload["digest"] as? String)
            return .json([
                "operationId": record.id,
                "movedCount": record.okCount,
                "failedCount": record.failCount,
                "bytes": record.bytes,
            ])
        } catch {
            return .json(["error": error.localizedDescription], status: 400)
        }
    }

    static func restore(_ body: Data) -> Response {
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let operationId = payload["operationId"] as? String
        else {
            return .json(["error": "operationId required"], status: 400)
        }
        do {
            let result = try Cleaner.restore(operationId: operationId)
            return .json(["restored": result.restored, "failed": result.failed])
        } catch {
            return .json(["error": error.localizedDescription], status: 400)
        }
    }
}

// MARK: - Jobs

/// Runs the four clean-up scans the workflow needs, one after another, in a
/// child process each, and reports progress the page can poll.
final class ScanJobs {
    static let shared = ScanJobs()

    private let lock = NSLock()
    private var jobs: [String: [String: Any]] = [:]
    /// Modules the clean-up workflow covers, in display order.
    static let modules = ["system-junk", "project-junk", "duplicates", "installers"]

    func start() -> WebApp.Response {
        let id = String(UUID().uuidString.prefix(10)).lowercased()
        lock.lock()
        jobs[id] = [
            "id": id,
            "state": "running",
            "index": 0,
            "total": Self.modules.count,
            "module": Self.modules[0],
            "groups": [],
        ]
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            for (index, module) in Self.modules.enumerated() {
                self.update(id) { $0["module"] = module; $0["index"] = index }
                if let payload = Self.runScan(module) {
                    self.update(id) { job in
                        var groups = job["groups"] as? [[String: Any]] ?? []
                        let snapshot = payload["snapshotPath"] as? String ?? ""
                        for group in payload["groups"] as? [[String: Any]] ?? [] {
                            var copy = group
                            copy["snapshot"] = snapshot
                            copy["module"] = module
                            groups.append(copy)
                        }
                        job["groups"] = groups
                    }
                }
            }
            self.update(id) { $0["state"] = "done"; $0["index"] = Self.modules.count }
        }

        return .json(["id": id])
    }

    func get(_ id: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return jobs[id]
    }

    private func update(_ id: String, _ change: (inout [String: Any]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var job = jobs[id] else { return }
        change(&job)
        jobs[id] = job
    }

    private static func runScan(_ module: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = ExecutablePath.resolve()
        process.arguments = ["scan", module, "--json", "--limit", "6"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
