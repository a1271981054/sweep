import Foundation
import CryptoKit
import MacCleanKit

public enum AgentPaths {
    public static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".sweep", isDirectory: true)
    }
    public static var snapshots: URL { root.appendingPathComponent("snapshots", isDirectory: true) }
    public static var plans: URL { root.appendingPathComponent("plans", isDirectory: true) }
    public static var config: URL { root.appendingPathComponent("config.json") }
    public static var operations: URL { root.appendingPathComponent("operations.jsonl") }
    public static var trashEmpties: URL { root.appendingPathComponent("trash-empties.jsonl") }

    public static func ensure() {
        for directory in [root, snapshots, plans] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: config.path) {
            try? Data("""
            {
              "mode": "confirm",
              "maxBytes": 21474836480,
              "maxItems": 2000
            }
            """.utf8).write(to: config)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        }
    }
}

// MARK: - Snapshots

public enum SnapshotStore {
    public static func uniqueURL(module: String) -> URL {
        AgentPaths.ensure()
        let stamp = Int(Date().timeIntervalSince1970)
        var candidate = AgentPaths.snapshots.appendingPathComponent("\(module)-\(stamp).json")
        if FileManager.default.fileExists(atPath: candidate.path) {
            let suffix = UUID().uuidString.prefix(4).lowercased()
            candidate = AgentPaths.snapshots.appendingPathComponent("\(module)-\(stamp)-\(suffix).json")
        }
        return candidate
    }

    public static func write(to url: URL, entries: [ScanEntry]) -> Bool {
        guard !entries.isEmpty else { return false }
        AgentPaths.ensure()
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// Persists the full candidate list so a later plan can only reference
    /// entries this process actually found. Returns the file path.
    public static func write(module: String, entries: [ScanEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        let url = uniqueURL(module: module)
        return write(to: url, entries: entries) ? url.path : nil
    }
}

// MARK: - Configuration

public struct AgentConfig: Codable, Sendable {
    public var mode: String
    public var maxBytes: UInt64
    public var maxItems: Int

    public static let `default` = AgentConfig(mode: "confirm", maxBytes: 20 * 1024 * 1024 * 1024, maxItems: 2000)

    public var isReadOnly: Bool { mode == "readonly" }
    public var isAuto: Bool { mode == "auto" }
}

public enum AgentConfigStore {
    public static func load() -> AgentConfig {
        AgentPaths.ensure()
        guard let data = try? Data(contentsOf: AgentPaths.config),
              let config = try? JSONDecoder().decode(AgentConfig.self, from: data)
        else { return .default }
        return config
    }

    public static func setMode(_ mode: String) throws {
        guard ["readonly", "confirm", "auto"].contains(mode) else {
            throw CleanError.invalidMode(mode)
        }
        AgentPaths.ensure()
        var config = load()
        config.mode = mode
        let data = try JSONEncoder().encode(config)
        try data.write(to: AgentPaths.config)
    }
}

// MARK: - Errors

public enum CleanError: Error, LocalizedError {
    case invalidMode(String)
    case readOnly
    case planNotFound(String)
    case digestMismatch
    case digestRequired
    case drift(path: String, expected: UInt64, actual: UInt64)
    case protectedPath(String)
    case missing(String)
    case budgetExceeded(bytes: UInt64, items: Int)
    case unknownIDs([String])
    case notAllowedInAuto(String)
    case operationNotFound(String)
    case emptySelection
    case trashAccessDenied

    public var errorDescription: String? {
        switch self {
        case .invalidMode(let mode): return "Unknown mode: \(mode). Use readonly, confirm or auto."
        case .readOnly: return "Mode is readonly: apply_clean is disabled."
        case .planNotFound(let id): return "Plan not found: \(id)"
        case .digestMismatch: return "Digest mismatch: the plan changed since it was approved."
        case .digestRequired: return "This mode requires the digest returned by plan_clean."
        case .drift(let path, let expected, let actual):
            return "File changed since planning: \(path) (\(expected) → \(actual) bytes)"
        case .protectedPath(let path): return "Protected path, refusing to delete: \(path)"
        case .missing(let path): return "No longer exists: \(path)"
        case .budgetExceeded(let bytes, let items):
            return "Exceeds budget: \(bytes) bytes / \(items) items"
        case .unknownIDs(let ids): return "Unknown ids (not in snapshot): \(ids.joined(separator: ", "))"
        case .notAllowedInAuto(let category): return "Category not allowed in auto mode: \(category)"
        case .operationNotFound(let id): return "Operation not found: \(id)"
        case .emptySelection: return "No entries selected."
        case .trashAccessDenied: return "无权访问 ~/.Trash，请为 Sweep Helper 授予完全磁盘访问权限。"
        }
    }
}

// MARK: - Plan

public struct PlanEntry: Codable, Sendable {
    public let id: String
    public let path: String
    public let bytes: UInt64
    public let category: String?
}

public struct CleanPlan: Codable, Sendable {
    public let id: String
    public let createdAt: String
    public let digest: String
    public let entries: [PlanEntry]
    public let totalBytes: UInt64
    public let warning: String?
}

public enum PlanStore {
    public static func create(from snapshotEntries: [ScanEntry], ids: [String]) throws -> CleanPlan {
        AgentPaths.ensure()
        let lookup = Dictionary(uniqueKeysWithValues: snapshotEntries.map { ($0.id, $0) })
        let unknown = ids.filter { lookup[$0] == nil }
        guard unknown.isEmpty else { throw CleanError.unknownIDs(unknown) }

        let entries = ids.compactMap { lookup[$0] }.map {
            PlanEntry(id: $0.id, path: $0.path, bytes: $0.bytes, category: $0.category)
        }
        guard !entries.isEmpty else { throw CleanError.emptySelection }

        let digest = Safety.planDigest(entries.map { ($0.path, $0.bytes) })
        let plan = CleanPlan(
            id: UUID().uuidString.prefix(8).lowercased(),
            createdAt: Util.nowISO(),
            digest: digest,
            entries: entries,
            totalBytes: entries.reduce(0) { $0 &+ $1.bytes },
            warning: "Nothing is deleted until apply_clean receives this exact digest."
        )
        let data = try JSONEncoder().encode(plan)
        let url = AgentPaths.plans.appendingPathComponent("\(plan.id).json")
        try data.write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return plan
    }

    public static func load(id: String) throws -> CleanPlan {
        let url = AgentPaths.plans.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url),
              let plan = try? JSONDecoder().decode(CleanPlan.self, from: data)
        else { throw CleanError.planNotFound(id) }
        return plan
    }
}

// MARK: - Operations

public struct OperationItem: Codable, Sendable {
    public let path: String
    public let bytes: UInt64
    public let category: String?
    public let trashPath: String?
    public let ok: Bool
    public let error: String?
}

public struct OperationRecord: Codable, Sendable {
    public let id: String
    public let createdAt: String
    public let planId: String
    public let digest: String
    public let mode: String
    public let okCount: Int
    public let failCount: Int
    public let bytes: UInt64
    public let items: [OperationItem]
}

public struct OperationSummary: Codable, Sendable {
    public let id: String
    public let createdAt: String
    public let okCount: Int
    public let failCount: Int
    public let bytes: UInt64
}

public enum OperationLog {
    private static let cacheLock = NSLock()
    private static var cachedMtime: Date?
    private static var cachedSize: UInt64 = 0
    private static var cachedSummaries: [OperationSummary] = []

    public static func append(_ record: OperationRecord) throws {
        AgentPaths.ensure()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(record)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: AgentPaths.operations.path) {
            FileManager.default.createFile(atPath: AgentPaths.operations.path, contents: nil)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AgentPaths.operations.path)
        }
        let handle = try FileHandle(forWritingTo: AgentPaths.operations)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)

        cacheLock.lock()
        cachedMtime = nil
        cacheLock.unlock()
    }

    public static func summaries() -> [OperationSummary] {
        let url = AgentPaths.operations
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = vals?.contentModificationDate
        let size = UInt64(vals?.fileSize ?? 0)

        cacheLock.lock()
        if let mtime, cachedMtime == mtime, cachedSize == size {
            let hit = cachedSummaries
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        let parsed = data.split(separator: 0x0A).compactMap { try? decoder.decode(OperationSummary.self, from: Data($0)) }

        cacheLock.lock()
        cachedMtime = mtime
        cachedSize = size
        cachedSummaries = parsed
        cacheLock.unlock()
        return parsed
    }

    public static func all() -> [OperationRecord] {
        guard let data = try? Data(contentsOf: AgentPaths.operations) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(OperationRecord.self, from: Data($0)) }
    }

    public static func find(_ id: String) throws -> OperationRecord {
        guard let record = all().last(where: { $0.id == id }) else {
            throw CleanError.operationNotFound(id)
        }
        return record
    }
}

// MARK: - Cleaner

public enum Cleaner {
    /// Categories that `auto` may touch unattended. Everything that is or may
    /// be user content stays out of this list on purpose.
    public static let autoWhitelist: Set<String> = [
        "user_caches", "system_caches", "user_logs", "system_logs",
        "package_manager_caches", "xcode_junk", "ide_caches", "ai_tool_caches",
        "old_updates", "broken_downloads", "incomplete_downloads",
    ]

    public static func apply(planId: String, digest: String?) throws -> OperationRecord {
        let config = AgentConfigStore.load()
        guard !config.isReadOnly else { throw CleanError.readOnly }

        let plan = try PlanStore.load(id: planId)
        let recomputed = Safety.planDigest(plan.entries.map { ($0.path, $0.bytes) })
        guard recomputed == plan.digest else { throw CleanError.digestMismatch }

        if config.isAuto {
            // An entry without a category is never auto-cleanable: the module
            // couldn't say what it is, so unattended deletion is not allowed.
            let blocked = plan.entries.first { entry in
                guard let category = entry.category else { return true }
                return !autoWhitelist.contains(category)
            }
            if let blocked { throw CleanError.notAllowedInAuto(blocked.category ?? "unknown") }
            if let digest, digest != plan.digest { throw CleanError.digestMismatch }
        } else {
            guard let digest else { throw CleanError.digestRequired }
            guard digest == plan.digest else { throw CleanError.digestMismatch }
        }

        let budget = Safety.Budget(maxBytes: config.maxBytes, maxItems: config.maxItems)
        guard budget.allows(bytes: plan.totalBytes, items: plan.entries.count) else {
            throw CleanError.budgetExceeded(bytes: plan.totalBytes, items: plan.entries.count)
        }

        let fm = FileManager.default
        var items: [OperationItem] = []

        for entry in plan.entries {
            let url = URL(fileURLWithPath: entry.path)

            if Safety.isProtected(url) {
                items.append(OperationItem(path: entry.path, bytes: entry.bytes, category: entry.category,
                                           trashPath: nil, ok: false,
                                           error: CleanError.protectedPath(entry.path).errorDescription))
                continue
            }
            guard fm.fileExists(atPath: entry.path) else {
                items.append(OperationItem(path: entry.path, bytes: entry.bytes, category: entry.category,
                                           trashPath: nil, ok: false,
                                           error: CleanError.missing(entry.path).errorDescription))
                continue
            }

            // Drift guard: the bytes must still match what was approved.
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey, .isDirectoryKey])
            let current = UInt64(values?.totalFileSize ?? values?.fileSize ?? 0)
            guard current == entry.bytes else {
                items.append(OperationItem(path: entry.path, bytes: entry.bytes, category: entry.category,
                                           trashPath: nil, ok: false,
                                           error: CleanError.drift(path: entry.path, expected: entry.bytes, actual: current).errorDescription))
                continue
            }

            do {
                var trashed: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &trashed)
                items.append(OperationItem(path: entry.path, bytes: entry.bytes, category: entry.category,
                                           trashPath: trashed?.path, ok: true, error: nil))
            } catch {
                items.append(OperationItem(path: entry.path, bytes: entry.bytes, category: entry.category,
                                           trashPath: nil, ok: false, error: error.localizedDescription))
            }
        }

        let succeeded = items.filter(\.ok)
        let record = OperationRecord(
            id: UUID().uuidString.prefix(8).lowercased(),
            createdAt: Util.nowISO(),
            planId: plan.id,
            digest: plan.digest,
            mode: config.mode,
            okCount: succeeded.count,
            failCount: items.count - succeeded.count,
            bytes: succeeded.reduce(0) { $0 &+ $1.bytes },
            items: items
        )
        try OperationLog.append(record)
        return record
    }

    /// Puts every trashed item back where it came from.
    public static func restore(operationId: String) throws -> (restored: Int, failed: [String]) {
        let record = try OperationLog.find(operationId)
        let fm = FileManager.default
        var restored = 0
        var failed: [String] = []

        for item in record.items where item.ok {
            guard let trashPath = item.trashPath else {
                failed.append("\(item.path): no trash path recorded")
                continue
            }
            let from = URL(fileURLWithPath: trashPath)
            let to = URL(fileURLWithPath: item.path)

            guard fm.fileExists(atPath: from.path) else {
                failed.append("\(item.path): already restored or emptied from Trash")
                continue
            }
            guard !fm.fileExists(atPath: to.path) else {
                failed.append("\(item.path): something already exists at the original path")
                continue
            }
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                restored += 1
            } catch {
                failed.append("\(item.path): \(error.localizedDescription)")
            }
        }
        return (restored, failed)
    }
}
