import Foundation
import Darwin
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
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    public static func stableID(_ path: String) -> String {
        var copy = path
        let digest: SHA256Digest = copy.withUTF8 { ptr in
            guard let base = ptr.baseAddress, !ptr.isEmpty else {
                return SHA256.hash(data: Data())
            }
            return SHA256.hash(data: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: ptr.count, deallocator: .none))
        }
        return String(unsafeUninitializedCapacity: 12) { buffer in
            var idx = 0
            for byte in digest {
                buffer[idx] = hexDigits[Int(byte >> 4)]
                buffer[idx + 1] = hexDigits[Int(byte & 0x0f)]
                idx += 2
                if idx == 12 { break }
            }
            return 12
        }
    }

    public static func iso(_ date: Date?) -> String? {
        guard let date else { return nil }
        let sec = date.timeIntervalSince1970
        guard sec.isFinite, sec >= 0, sec < 253_402_300_800 else {
            return ISO8601DateFormatter().string(from: date)
        }
        var t = time_t(sec)
        var tm = Darwin.tm()
        guard gmtime_r(&t, &tm) != nil else {
            return ISO8601DateFormatter().string(from: date)
        }
        let year = Int(tm.tm_year) + 1900
        let month = Int(tm.tm_mon) + 1
        let day = Int(tm.tm_mday)
        let hour = Int(tm.tm_hour)
        let min = Int(tm.tm_min)
        let s = Int(tm.tm_sec)
        return String(unsafeUninitializedCapacity: 20) { buf in
            buf[0] = UInt8(48 + (year / 1000) % 10)
            buf[1] = UInt8(48 + (year / 100) % 10)
            buf[2] = UInt8(48 + (year / 10) % 10)
            buf[3] = UInt8(48 + year % 10)
            buf[4] = 45
            buf[5] = UInt8(48 + month / 10)
            buf[6] = UInt8(48 + month % 10)
            buf[7] = 45
            buf[8] = UInt8(48 + day / 10)
            buf[9] = UInt8(48 + day % 10)
            buf[10] = 84
            buf[11] = UInt8(48 + hour / 10)
            buf[12] = UInt8(48 + hour % 10)
            buf[13] = 58
            buf[14] = UInt8(48 + min / 10)
            buf[15] = UInt8(48 + min % 10)
            buf[16] = 58
            buf[17] = UInt8(48 + s / 10)
            buf[18] = UInt8(48 + s % 10)
            buf[19] = 90
            return 20
        }
    }

    public static func nowISO() -> String {
        iso(Date()) ?? ISO8601DateFormatter().string(from: Date())
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

    public static func topItems(_ items: [FileItem], limit: Int) -> [FileItem] {
        guard limit > 0, !items.isEmpty else { return [] }
        if items.count <= limit {
            return items.sorted { $0.size > $1.size }
        }
        // Linear top-K selection when limit is small avoids full O(N log N) sort over 100k items.
        if limit <= 256 {
            var best: [FileItem] = []
            best.reserveCapacity(limit + 1)
            var threshold: UInt64 = 0
            for item in items {
                if best.count < limit {
                    best.append(item)
                    if best.count == limit {
                        best.sort { $0.size > $1.size }
                        threshold = best[limit - 1].size
                    }
                } else if item.size > threshold {
                    var lo = 0
                    var hi = limit
                    while lo < hi {
                        let mid = (lo + hi) >> 1
                        if best[mid].size > item.size {
                            lo = mid + 1
                        } else {
                            hi = mid
                        }
                    }
                    best.insert(item, at: lo)
                    best.removeLast()
                    threshold = best[limit - 1].size
                }
            }
            if best.count < limit {
                best.sort { $0.size > $1.size }
            }
            return best
        }
        return Array(items.sorted { $0.size > $1.size }.prefix(limit))
    }

    public static func entries(from items: [FileItem], limit: Int, category: String? = nil) -> [ScanEntry] {
        topItems(items, limit: limit).map {
            let path = $0.url.path(percentEncoded: false)
            return ScanEntry(
                id: stableID(path),
                path: path,
                bytes: $0.size,
                modified: iso($0.modificationDate),
                category: category
            )
        }
    }
}
