import Foundation
import CryptoKit
import MacCleanKit

/// One candidate row an agent may reference by `id`.
public struct ScanEntry: Codable, Sendable {
    public let id: String
    public let path: String
    public let bytes: UInt64
    public let modified: String?
    public let kind: String?
    public let category: String?

    public init(
        id: String,
        path: String,
        bytes: UInt64,
        modified: String?,
        kind: String? = nil,
        category: String? = nil
    ) {
        self.id = id
        self.path = path
        self.bytes = bytes
        self.modified = modified
        self.kind = kind
        self.category = category
    }
}

public struct ScanGroup: Codable, Sendable {
    public let category: String
    public let label: String
    public let items: Int
    public let bytes: UInt64
    /// Bounded sample, largest first. The full set lives in the snapshot file.
    public let top: [ScanEntry]

    public init(category: String, label: String, items: Int, bytes: UInt64, top: [ScanEntry]) {
        self.category = category
        self.label = label
        self.items = items
        self.bytes = bytes
        self.top = top
    }
}

public struct ScanReport: Codable, Sendable {
    public let module: String
    public let generatedAt: String
    public let totalItems: Int
    public let totalBytes: UInt64
    public let groups: [ScanGroup]
    /// Roots macOS refused to let this process read (missing Full Disk Access).
    public let deniedPaths: [String]
    public let warnings: [String]
    public let scanSeconds: Double
    /// Path to the full, untruncated candidate list, if written.
    public let snapshotPath: String?

    public init(
        module: String,
        generatedAt: String,
        totalItems: Int,
        totalBytes: UInt64,
        groups: [ScanGroup],
        deniedPaths: [String],
        warnings: [String],
        scanSeconds: Double,
        snapshotPath: String?
    ) {
        self.module = module
        self.generatedAt = generatedAt
        self.totalItems = totalItems
        self.totalBytes = totalBytes
        self.groups = groups
        self.deniedPaths = deniedPaths
        self.warnings = warnings
        self.scanSeconds = scanSeconds
        self.snapshotPath = snapshotPath
    }
}

public enum Util {
    public static func stableID(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    public static func iso(_ date: Date?) -> String? {
        guard let date else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }

    public static func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    public static func bytes(_ value: UInt64) -> String {
        if value == 0 { return "0 B" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(clamping: value))
    }

    /// Expands `~/` and resolves symlinks the same way the app does.
    public static func expand(_ raw: String) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    public static func entries(from items: [FileItem], limit: Int, category: String? = nil) -> [ScanEntry] {
        items
            .sorted { $0.size > $1.size }
            .prefix(limit)
            .map {
                ScanEntry(
                    id: stableID($0.url.path(percentEncoded: false)),
                    path: $0.url.path(percentEncoded: false),
                    bytes: $0.size,
                    modified: iso($0.modificationDate),
                    category: category
                )
            }
    }
}
