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
        case ("GET", "/api/metrics"):
            return metrics()
        case ("POST", "/api/scan"):
            return ScanJobs.shared.start()
        case ("GET", "/api/job"):
            return job(request.query["id"] ?? "")
        case ("GET", "/api/snapshot"):
            return snapshot(request.query)
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

        let ops = OperationLog.summaries().suffix(5).map { record -> [String: Any] in
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

    static func metrics() -> Response {
        .json(SystemMetrics.shared.collect())
    }

    // MARK: - Scan job

    static func job(_ id: String) -> Response {
        guard let job = ScanJobs.shared.get(id) else {
            return .json(["error": "unknown job"], status: 404)
        }
        return .json(job)
    }

    // MARK: - Snapshot explorer

    static func snapshot(_ query: [String: String]) -> Response {
        guard let rawPath = query["path"], !rawPath.isEmpty else {
            return .json(["error": "path required"], status: 400)
        }
        guard let cached = SnapshotCache.shared.load(path: rawPath) else {
            return .json(["error": "snapshot not found"], status: 404)
        }

        let category = query["category"] ?? ""
        let sub = query["sub"] ?? ""
        let risk = query["risk"] ?? ""
        let search = (query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sort = query["sort"] ?? "size"
        let offset = max(0, Int(query["offset"] ?? "0") ?? 0)
        let limit = min(500, max(1, Int(query["limit"] ?? "100") ?? 100))

        // O(1) indexed category lookup & pre-sorted size ordering when no filter/alternate sort applies.
        let categoryScoped = category.isEmpty
            ? cached.items
            : (cached.byCategory[category] ?? [])
        let subgroups = category.isEmpty
            ? cached.allSubgroups
            : (cached.subgroupsByCategory[category] ?? [])

        let hasFilters = !sub.isEmpty || !risk.isEmpty || !search.isEmpty
        var filtered: [SnapshotCache.AnalyzedEntry]
        if !hasFilters {
            filtered = categoryScoped
        } else {
            filtered = categoryScoped
            if !sub.isEmpty {
                filtered = filtered.filter { $0.analysis.subCategory == sub }
            }
            if !risk.isEmpty {
                filtered = filtered.filter { $0.analysis.risk == risk }
            }
            if !search.isEmpty {
                filtered = filtered.filter { item in
                    item.entry.path.lowercased().contains(search)
                        || item.analysis.subLabel.lowercased().contains(search)
                        || item.analysis.riskLabel.lowercased().contains(search)
                }
            }
        }

        switch sort {
        case "name":
            filtered.sort {
                ($0.entry.path as NSString).lastPathComponent.localizedStandardCompare(
                    ($1.entry.path as NSString).lastPathComponent
                ) == .orderedAscending
            }
        case "modified":
            filtered.sort { ($0.entry.modified ?? "") > ($1.entry.modified ?? "") }
        default:
            // categoryScoped / filtered already preserve descending bytes order from CachedSnapshot.
            break
        }

        let total = filtered.count
        let totalBytes = filtered.reduce(UInt64(0)) { $0 &+ $1.entry.bytes }
        let start = min(offset, total)
        let end = min(start + limit, total)
        let slice = filtered[start..<end].map { item in
            FileAdvisor.describe(item.entry, classification: item.analysis).asDictionary(for: item.entry)
        }

        return .json([
            "total": total,
            "totalBytes": totalBytes,
            "offset": start,
            "limit": limit,
            "subgroups": subgroups,
            "entries": slice,
        ])
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
        var seenIds = Set<String>()

        for selection in selections {
            guard let snapshotPath = selection["snapshot"] as? String else { continue }
            guard let cached = SnapshotCache.shared.load(path: snapshotPath) else { continue }

            // Explicit file IDs take precedence so user-checked files clean regardless of minBytes.
            if let ids = selection["ids"] as? [String], !ids.isEmpty {
                let idSet = Set(ids)
                for item in cached.items where idSet.contains(item.entry.id) {
                    if seenIds.insert(item.entry.id).inserted {
                        entries.append(item.entry)
                    }
                }
                continue
            }

            let categories = Set(selection["categories"] as? [String] ?? [])
            let subCategories = Set(selection["subCategories"] as? [String] ?? [])
            let excludeIds = Set(selection["excludeIds"] as? [String] ?? [])

            if !subCategories.isEmpty {
                let matching = cached.items.filter { item in
                    (categories.isEmpty || categories.contains(item.entry.category ?? ""))
                        && subCategories.contains(item.analysis.subCategory)
                        && !excludeIds.contains(item.entry.id)
                }
                let applyThreshold = matching.count > 1500 && minBytes > 0
                for item in matching where !applyThreshold || item.entry.bytes >= minBytes {
                    if seenIds.insert(item.entry.id).inserted {
                        entries.append(item.entry)
                    }
                }
                continue
            }

            guard !categories.isEmpty else { continue }
            for item in cached.items where categories.contains(item.entry.category ?? "") && item.entry.bytes >= minBytes {
                if seenIds.insert(item.entry.id).inserted {
                    entries.append(item.entry)
                }
            }
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
            let okItems = record.items.filter(\.ok)
            var cleanedIds: [String] = []
            var deltaMap: [String: (category: String, subCategory: String, bytes: UInt64, items: Int, ids: [String])] = [:]

            for item in okItems {
                let entryId = Util.stableID(item.path)
                cleanedIds.append(entryId)
                let probe = ScanEntry(id: entryId, path: item.path, bytes: item.bytes, modified: nil, kind: nil, category: item.category)
                let analysis = FileAdvisor.analyze(probe)
                let cat = item.category ?? ""
                let key = "\(cat)|\(analysis.subCategory)"
                var entry = deltaMap[key] ?? (category: cat, subCategory: analysis.subCategory, bytes: 0, items: 0, ids: [])
                entry.bytes &+= item.bytes
                entry.items += 1
                entry.ids.append(entryId)
                deltaMap[key] = entry
            }

            let subDeltas = deltaMap.values.map { delta -> [String: Any] in
                [
                    "category": delta.category,
                    "subCategory": delta.subCategory,
                    "bytes": delta.bytes,
                    "items": delta.items,
                    "ids": delta.ids,
                ]
            }

            return .json([
                "operationId": record.id,
                "movedCount": record.okCount,
                "failedCount": record.failCount,
                "bytes": record.bytes,
                "cleanedIds": cleanedIds,
                "subDeltas": subDeltas,
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

// MARK: - Snapshot cache & sub-group aggregation

final class SnapshotCache {
    static let shared = SnapshotCache()

    struct AnalyzedEntry {
        let entry: ScanEntry
        let analysis: FileClassification
    }

    struct CachedSnapshot {
        let path: String
        var mtime: Date?
        let items: [AnalyzedEntry]
        let byCategory: [String: [AnalyzedEntry]]
        let allSubgroups: [[String: Any]]
        let subgroupsByCategory: [String: [[String: Any]]]
    }

    private let lock = NSLock()
    private var entries: [String: CachedSnapshot] = [:]
    private var order: [String] = []
    private var pendingWrites: [String: DispatchGroup] = [:]
    private let writeQueue = DispatchQueue(label: "sweep.snapshot.write", qos: .utility)
    private let maxCached = 8

    static func resolvedSnapshotURL(_ rawPath: String) -> URL? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let target = URL(fileURLWithPath: expanded).standardizedFileURL
        let root = AgentPaths.snapshots.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard target.path.hasPrefix(prefix), target.pathExtension == "json" else {
            return nil
        }
        return target
    }

    func getIfLoaded(path rawPath: String) -> CachedSnapshot? {
        guard let url = Self.resolvedSnapshotURL(rawPath) else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        lock.lock()
        let hit = entries[url.path]
        let hasPending = pendingWrites[url.path] != nil
        lock.unlock()
        guard let hit else { return nil }
        if hasPending || hit.mtime == mtime { return hit }
        return nil
    }

    /// Populates the in-memory index straight from freshly scanned `[ScanEntry]`
    /// and persists JSON asynchronously so scans finish without disk/decode blocking.
    @discardableResult
    func ingest(path rawPath: String, entries rawEntries: [ScanEntry], persistAsync: Bool = true) -> CachedSnapshot? {
        guard let url = Self.resolvedSnapshotURL(rawPath) else { return nil }
        let built = Self.buildCachedSnapshot(path: url.path, mtime: nil, rawEntries: rawEntries)

        let writeGroup: DispatchGroup? = persistAsync ? DispatchGroup() : nil
        writeGroup?.enter()

        lock.lock()
        if let writeGroup {
            pendingWrites[url.path] = writeGroup
        }
        storeLocked(built)
        lock.unlock()

        if persistAsync {
            writeQueue.async { [weak self] in
                _ = SnapshotStore.write(to: url, entries: rawEntries)
                let diskMtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let self {
                    self.lock.lock()
                    if var current = self.entries[url.path] {
                        current.mtime = diskMtime
                        self.entries[url.path] = current
                    }
                    self.pendingWrites.removeValue(forKey: url.path)
                    self.lock.unlock()
                }
                writeGroup?.leave()
            }
        }
        return built
    }

    func load(path rawPath: String) -> CachedSnapshot? {
        guard let url = Self.resolvedSnapshotURL(rawPath) else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        lock.lock()
        let pending = pendingWrites[url.path]
        if let hit = entries[url.path], pending != nil || hit.mtime == mtime {
            lock.unlock()
            return hit
        }
        lock.unlock()

        if let pending {
            pending.wait()
        }

        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ScanEntry].self, from: data)
        else { return nil }

        let latestMtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let snapshot = Self.buildCachedSnapshot(path: url.path, mtime: latestMtime, rawEntries: decoded)

        lock.lock()
        storeLocked(snapshot)
        lock.unlock()

        return snapshot
    }

    private func storeLocked(_ snapshot: CachedSnapshot) {
        entries[snapshot.path] = snapshot
        order.removeAll { $0 == snapshot.path }
        order.append(snapshot.path)
        while order.count > maxCached {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }

    private static func buildCachedSnapshot(path: String, mtime: Date?, rawEntries: [ScanEntry]) -> CachedSnapshot {
        let todayEpoch = FileAdvisor.currentEpochDay()
        var analyzed: [AnalyzedEntry] = []
        analyzed.reserveCapacity(rawEntries.count)
        var byCategory: [String: [AnalyzedEntry]] = [:]

        for raw in rawEntries {
            let item = AnalyzedEntry(entry: raw, analysis: FileAdvisor.classify(raw, todayEpochDay: todayEpoch))
            analyzed.append(item)
            byCategory[raw.category ?? "", default: []].append(item)
        }

        analyzed.sort { $0.entry.bytes > $1.entry.bytes }
        for cat in Array(byCategory.keys) {
            byCategory[cat]?.sort { $0.entry.bytes > $1.entry.bytes }
        }

        var subgroupsByCategory: [String: [[String: Any]]] = [:]
        for (cat, bucketItems) in byCategory {
            subgroupsByCategory[cat] = summarizeSubgroups(bucketItems)
        }
        let allSubgroups: [[String: Any]]
        if byCategory.count == 1, let only = subgroupsByCategory.values.first {
            allSubgroups = only
        } else {
            allSubgroups = summarizeSubgroups(analyzed)
        }

        return CachedSnapshot(
            path: path,
            mtime: mtime,
            items: analyzed,
            byCategory: byCategory,
            allSubgroups: allSubgroups,
            subgroupsByCategory: subgroupsByCategory
        )
    }

    static func summarizeSubgroups(_ items: [AnalyzedEntry], minBytes: UInt64 = 1024 * 1024) -> [[String: Any]] {
        struct Bucket {
            let id: String
            var label: String
            var bytes: UInt64 = 0
            var count: Int = 0
            var largeBytes: UInt64 = 0
            var largeCount: Int = 0
            var safeCount: Int = 0
            var confirmCount: Int = 0
            var cautionCount: Int = 0
            var safeBytes: UInt64 = 0
            var confirmBytes: UInt64 = 0
            var cautionBytes: UInt64 = 0
            var staleCount: Int = 0
            var top: [AnalyzedEntry] = []
        }

        var buckets: [String: Bucket] = [:]
        for item in items {
            let sub = item.analysis.subCategory
            var bucket = buckets[sub] ?? Bucket(id: sub, label: item.analysis.subLabel)
            bucket.bytes &+= item.entry.bytes
            bucket.count += 1
            if item.entry.bytes >= minBytes {
                bucket.largeBytes &+= item.entry.bytes
                bucket.largeCount += 1
            }
            if let age = item.analysis.ageDays, age >= 30 {
                bucket.staleCount += 1
            }
            switch item.analysis.risk {
            case "safe":
                bucket.safeCount += 1
                bucket.safeBytes &+= item.entry.bytes
            case "caution":
                bucket.cautionCount += 1
                bucket.cautionBytes &+= item.entry.bytes
            default:
                bucket.confirmCount += 1
                bucket.confirmBytes &+= item.entry.bytes
            }
            if bucket.top.count < 3 || item.entry.bytes > (bucket.top.last?.entry.bytes ?? 0) {
                bucket.top.append(item)
                bucket.top.sort { $0.entry.bytes > $1.entry.bytes }
                if bucket.top.count > 3 { bucket.top.removeLast() }
            }
            buckets[sub] = bucket
        }

        return buckets.values.map { bucket -> [String: Any] in
            let dominantRisk: String
            let dominantLabel: String
            if bucket.cautionBytes > bucket.safeBytes && bucket.cautionBytes >= bucket.confirmBytes {
                dominantRisk = "caution"
                dominantLabel = "谨慎保留"
            } else if bucket.safeBytes >= bucket.confirmBytes && bucket.safeBytes >= bucket.cautionBytes {
                dominantRisk = "safe"
                dominantLabel = "推荐清理"
            } else {
                dominantRisk = "confirm"
                dominantLabel = "按需确认"
            }

            let overCap = bucket.count > 1500
            let cleanableBytes = overCap ? bucket.largeBytes : bucket.bytes
            let cleanableItems = overCap ? bucket.largeCount : bucket.count
            let topItems = bucket.top.map { item -> [String: Any] in
                let rawName = (item.entry.path as NSString).lastPathComponent
                let parentName = ((item.entry.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                let displayName = item.entry.category == "project_junk" && !parentName.isEmpty
                    ? "\(parentName)/\(rawName)"
                    : rawName
                var dict: [String: Any] = [
                    "id": item.entry.id,
                    "name": displayName,
                    "path": item.entry.path,
                    "bytes": item.entry.bytes,
                    "risk": item.analysis.risk,
                    "riskLabel": item.analysis.riskLabel,
                ]
                if let age = item.analysis.ageDays { dict["ageDays"] = age }
                return dict
            }
            let advice = bucket.top.first.map { FileAdvisor.describe($0.entry, classification: $0.analysis).advice } ?? ""

            return [
                "id": bucket.id,
                "label": bucket.label,
                "bytes": bucket.bytes,
                "items": bucket.count,
                "cleanableBytes": cleanableBytes,
                "cleanableItems": cleanableItems,
                "risk": dominantRisk,
                "riskLabel": dominantLabel,
                "safeBytes": bucket.safeBytes,
                "confirmBytes": bucket.confirmBytes,
                "cautionBytes": bucket.cautionBytes,
                "safeCount": bucket.safeCount,
                "confirmCount": bucket.confirmCount,
                "cautionCount": bucket.cautionCount,
                "staleCount": bucket.staleCount,
                "advice": advice,
                "top": topItems,
            ]
        }.sorted { ($0["bytes"] as? UInt64 ?? 0) > ($1["bytes"] as? UInt64 ?? 0) }
    }
}

// MARK: - Jobs

/// Runs all four clean-up scans concurrently inside the helper process,
/// populates `SnapshotCache` immediately in memory, and streams progress.
final class ScanJobs {
    static let shared = ScanJobs()

    private let lock = NSLock()
    private var jobs: [String: [String: Any]] = [:]
    private var activeTask: Task<Void, Never>?
    private var cancelledIds: Set<String> = []

    /// Modules the clean-up workflow covers, in display order.
    static let modules = ["system-junk", "project-junk", "duplicates", "installers"]
    static let moduleWeights: [Double] = [0.30, 0.35, 0.27, 0.08]
    static let moduleTitles = ["系统垃圾", "项目垃圾", "重复文件", "安装包"]

    private final class ConcurrentState: @unchecked Sendable {
        private let stateLock = NSLock()
        var progress: [Double]
        var stages: [String]
        var bytes: [UInt64]
        var items: [Int]
        var done: [Bool]
        var lastEmit: [TimeInterval]

        init(count: Int, titles: [String]) {
            self.progress = Array(repeating: 0.0, count: count)
            self.stages = titles
            self.bytes = Array(repeating: 0, count: count)
            self.items = Array(repeating: 0, count: count)
            self.done = Array(repeating: false, count: count)
            self.lastEmit = Array(repeating: 0, count: count)
        }

        func updateLive(
            index: Int,
            subFrac: Double,
            stage: String,
            foundBytes: UInt64,
            foundItems: Int,
            weights: [Double],
            modules: [String]
        ) -> (overall: Double, module: String, moduleProgress: Double, stage: String, bytes: UInt64, items: Int, index: Int)? {
            let now = Date().timeIntervalSince1970
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !done[index] else { return nil }

            let clamped = min(0.98, max(progress[index], subFrac))
            let delta = clamped - progress[index]
            let elapsed = now - lastEmit[index]
            progress[index] = clamped
            if !stage.isEmpty { stages[index] = stage }
            bytes[index] = max(bytes[index], foundBytes)
            items[index] = max(items[index], foundItems)

            if elapsed < 0.06 && delta < 0.03 {
                return nil
            }
            lastEmit[index] = now
            return aggregateLocked(weights: weights, modules: modules)
        }

        func markDone(
            index: Int,
            modBytes: UInt64,
            modItems: Int,
            weights: [Double],
            modules: [String]
        ) -> (overall: Double, module: String, moduleProgress: Double, stage: String, bytes: UInt64, items: Int, index: Int) {
            stateLock.lock()
            defer { stateLock.unlock() }
            done[index] = true
            progress[index] = 1.0
            bytes[index] = modBytes
            items[index] = modItems
            return aggregateLocked(weights: weights, modules: modules)
        }

        private func aggregateLocked(
            weights: [Double],
            modules: [String]
        ) -> (overall: Double, module: String, moduleProgress: Double, stage: String, bytes: UInt64, items: Int, index: Int) {
            var overall = 0.0
            var totalBytes: UInt64 = 0
            var totalItems = 0
            var completed = 0
            var activeIdx: Int?

            for i in 0..<modules.count {
                overall += weights[i] * progress[i]
                totalBytes &+= bytes[i]
                totalItems += items[i]
                if done[i] {
                    completed += 1
                } else if activeIdx == nil {
                    activeIdx = i
                }
            }

            let shownIdx = activeIdx ?? max(0, modules.count - 1)
            let cappedOverall = completed == modules.count ? 1.0 : min(0.99, overall)
            return (
                cappedOverall,
                modules[shownIdx],
                progress[shownIdx],
                stages[shownIdx],
                totalBytes,
                totalItems,
                completed
            )
        }
    }

    func start() -> WebApp.Response {
        let id = String(UUID().uuidString.prefix(10)).lowercased()
        lock.lock()
        for existingId in jobs.keys where (jobs[existingId]?["state"] as? String) == "running" {
            cancelledIds.insert(existingId)
            var stopped = jobs[existingId] ?? [:]
            stopped["state"] = "cancelled"
            jobs[existingId] = stopped
        }
        let previousTask = activeTask
        activeTask = nil
        jobs[id] = [
            "id": id,
            "state": "running",
            "index": 0,
            "total": Self.modules.count,
            "module": Self.modules[0],
            "moduleProgress": 0.0,
            "progress": 0.0,
            "percent": 0,
            "stage": "并发扫描中",
            "liveBytes": UInt64(0),
            "liveItems": 0,
            "groups": [],
        ]
        lock.unlock()

        previousTask?.cancel()

        let task = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let state = ConcurrentState(count: Self.modules.count, titles: Self.moduleTitles)

            await withTaskGroup(of: Void.self) { group in
                for (index, module) in Self.modules.enumerated() {
                    group.addTask {
                        if Task.isCancelled || self.isCancelled(id) { return }

                        let output = await CLIRunner.executeModule(module: module, limit: 12) { subFrac, stage, _, foundBytes, foundItems in
                            if Task.isCancelled || self.isCancelled(id) { return }
                            guard let agg = state.updateLive(
                                index: index,
                                subFrac: subFrac,
                                stage: stage,
                                foundBytes: foundBytes,
                                foundItems: foundItems,
                                weights: Self.moduleWeights,
                                modules: Self.modules
                            ) else { return }

                            self.update(id) { job in
                                let prev = job["progress"] as? Double ?? 0.0
                                let next = max(prev, agg.overall)
                                job["index"] = agg.index
                                job["module"] = agg.module
                                job["moduleProgress"] = agg.moduleProgress
                                job["progress"] = next
                                job["percent"] = Int((next * 100.0).rounded())
                                job["stage"] = agg.stage
                                job["liveBytes"] = max(job["liveBytes"] as? UInt64 ?? 0, agg.bytes)
                                job["liveItems"] = max(job["liveItems"] as? Int ?? 0, agg.items)
                            }
                        }

                        if Task.isCancelled || self.isCancelled(id) { return }

                        var enrichedGroups: [[String: Any]] = []
                        var modBytes: UInt64 = 0
                        var modItems = 0

                        if let output {
                            let snapshotPath: String
                            let cached: SnapshotCache.CachedSnapshot?
                            if output.entries.isEmpty {
                                snapshotPath = ""
                                cached = nil
                            } else {
                                let url = SnapshotStore.uniqueURL(module: module)
                                snapshotPath = url.path
                                cached = SnapshotCache.shared.ingest(path: snapshotPath, entries: output.entries, persistAsync: true)
                            }

                            for scanGroup in output.groups {
                                modBytes &+= scanGroup.bytes
                                modItems += scanGroup.items

                                var groupDict: [String: Any] = [
                                    "category": scanGroup.category,
                                    "label": scanGroup.label,
                                    "items": scanGroup.items,
                                    "bytes": scanGroup.bytes,
                                    "snapshot": snapshotPath,
                                    "module": module,
                                ]

                                if let cached {
                                    groupDict["subgroups"] = cached.subgroupsByCategory[scanGroup.category] ?? []
                                    let scoped = cached.byCategory[scanGroup.category] ?? []
                                    let analyzedTop = scoped
                                        .prefix(12)
                                        .map { FileAdvisor.describe($0.entry, classification: $0.analysis).asDictionary(for: $0.entry) }
                                    groupDict["top"] = analyzedTop
                                } else {
                                    groupDict["top"] = scanGroup.top.map { entry in
                                        var d: [String: Any] = [
                                            "id": entry.id,
                                            "path": entry.path,
                                            "bytes": entry.bytes,
                                        ]
                                        if let m = entry.modified { d["modified"] = m }
                                        if let k = entry.kind { d["kind"] = k }
                                        if let c = entry.category { d["category"] = c }
                                        return d
                                    }
                                }
                                enrichedGroups.append(groupDict)
                            }
                        }

                        let agg = state.markDone(
                            index: index,
                            modBytes: modBytes,
                            modItems: modItems,
                            weights: Self.moduleWeights,
                            modules: Self.modules
                        )

                        self.update(id) { job in
                            var groups = job["groups"] as? [[String: Any]] ?? []
                            groups.append(contentsOf: enrichedGroups)
                            job["groups"] = groups
                            job["index"] = agg.index
                            job["module"] = agg.module
                            job["moduleProgress"] = agg.moduleProgress
                            let prev = job["progress"] as? Double ?? 0.0
                            let next = max(prev, agg.overall)
                            job["progress"] = next
                            job["percent"] = Int((next * 100.0).rounded())
                            job["stage"] = agg.index < Self.modules.count ? agg.stage : "完成"
                            job["liveBytes"] = agg.bytes
                            job["liveItems"] = agg.items
                        }
                    }
                }
            }

            if !Task.isCancelled && !self.isCancelled(id) {
                self.update(id) {
                    if let groups = $0["groups"] as? [[String: Any]] {
                        $0["groups"] = groups.sorted {
                            ($0["bytes"] as? UInt64 ?? 0) > ($1["bytes"] as? UInt64 ?? 0)
                        }
                    }
                    $0["state"] = "done"
                    $0["index"] = Self.modules.count
                    $0["moduleProgress"] = 1.0
                    $0["progress"] = 1.0
                    $0["percent"] = 100
                    $0["stage"] = "完成"
                }
            }
        }

        lock.lock()
        activeTask = task
        lock.unlock()

        return .json(["id": id])
    }

    func get(_ id: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return jobs[id]
    }

    private func isCancelled(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledIds.contains(id)
    }

    private func update(_ id: String, _ change: (inout [String: Any]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var job = jobs[id] else { return }
        change(&job)
        jobs[id] = job
    }
}
