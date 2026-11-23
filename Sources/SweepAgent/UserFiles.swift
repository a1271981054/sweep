import Foundation
import CryptoKit
import MacCleanKit

public enum DefaultRoots {
    public static let userFiles = ["~/Downloads", "~/Documents", "~/Desktop", "~/Movies", "~/Music"]
    public static let documents = ["~/Downloads", "~/Documents", "~/Desktop"]
    public static let projects = ["~/Documents", "~/Desktop", "~/Developer", "~/Projects", "~/Code", "~/dev"]
}

/// Large files and old files: the user's own files, selected purely by size or
/// age. Nothing here is junk by definition, so the agent must never batch-clean
/// these without explicit approval of each entry.
public struct UserFilesScanner {
    private let walker: FileWalker

    public init(walker: FileWalker = FileWalker()) {
        self.walker = walker
    }

    public func largeFiles(roots: [URL], minSize: UInt64, limit: Int) async -> (group: ScanGroup?, denied: [URL], all: [FileItem]) {
        let targets = roots.map {
            ScanTarget(path: $0, recursive: true, minSize: minSize, skipHiddenDirectories: true)
        }
        let result = await walker.scan(targets: targets)
        let leaves = result.items.filter { !$0.isDirectory && !$0.isSymlink }
        guard !leaves.isEmpty else { return (nil, result.deniedPaths, []) }

        let group = ScanGroup(
            category: ScanCategory.largeFiles.rawValue,
            label: CategoryLabels.label(ScanCategory.largeFiles),
            items: leaves.count,
            bytes: FileWalker.leafBytes(of: leaves),
            top: Util.entries(from: leaves, limit: limit)
        )
        return (group, result.deniedPaths, leaves)
    }

    public func oldFiles(roots: [URL], olderThanDays: Double, limit: Int) async -> (group: ScanGroup?, denied: [URL], all: [FileItem]) {
        let seconds = olderThanDays * 86_400
        let targets = roots.map {
            ScanTarget(
                path: $0,
                recursive: true,
                minAge: seconds,
                minSize: 1024 * 1024,
                skipHiddenDirectories: true
            )
        }
        let result = await walker.scan(targets: targets)
        let leaves = result.items.filter { !$0.isDirectory && !$0.isSymlink }
        guard !leaves.isEmpty else { return (nil, result.deniedPaths, []) }

        let group = ScanGroup(
            category: ScanCategory.oldFiles.rawValue,
            label: CategoryLabels.label(ScanCategory.oldFiles),
            items: leaves.count,
            bytes: FileWalker.leafBytes(of: leaves),
            top: Util.entries(from: leaves, limit: limit)
        )
        return (group, result.deniedPaths, leaves)
    }
}

/// Duplicates: the same four stages Sweep uses — size, partial hash, full
/// hash, hard-link collapse — so only byte-identical copies are reported.
public struct DuplicateScanner {
    public static let maxHashCount = 20_000

    private let walker: FileWalker

    public init(walker: FileWalker = FileWalker()) {
        self.walker = walker
    }

    public func scan(
        roots: [URL],
        minSize: UInt64,
        limit: Int
    ) async -> (groups: [ScanGroup], denied: [URL], deletable: [FileItem], hashed: Int) {
        let targets = roots.map {
            ScanTarget(path: $0, recursive: true, minSize: minSize, skipHiddenDirectories: true)
        }
        let result = await walker.scan(targets: targets)
        let files = result.items.filter { !$0.isDirectory && !$0.isSymlink && $0.size > 0 }

        let sizeGroups = DuplicateDetection.sizeGroups(files)
        guard !sizeGroups.isEmpty else { return ([], result.deniedPaths, [], 0) }

        var partialPairs: [(key: String, item: FileItem)] = []
        var hashed = 0
        for group in sizeGroups {
            for item in group where hashed < Self.maxHashCount {
                guard let partial = Self.partialHash(item.url) else { continue }
                partialPairs.append((key: "\(item.size)-\(partial)", item: item))
                hashed += 1
            }
        }

        let partialGroups = DuplicateDetection.partialGroups(partialPairs)
        guard !partialGroups.isEmpty else { return ([], result.deniedPaths, [], hashed) }

        var fullPairs: [(key: String, item: FileItem)] = []
        for group in partialGroups {
            for item in group {
                guard let full = FileHashing.sha256(item.url) else { continue }
                fullPairs.append((key: full, item: item))
            }
        }

        let fullGroups = DuplicateDetection.fullGroupsAndDedupHardLinks(fullPairs)
        guard !fullGroups.isEmpty else { return ([], result.deniedPaths, [], hashed) }

        let deletable = DuplicateDetection.extractDeletableDuplicates(fullGroups)
        let group = ScanGroup(
            category: ScanCategory.duplicates.rawValue,
            label: CategoryLabels.label(ScanCategory.duplicates),
            items: deletable.count,
            bytes: FileWalker.leafBytes(of: deletable),
            top: Util.entries(from: deletable, limit: limit)
        )
        return ([group], result.deniedPaths, deletable, hashed)
    }

    /// First 4 KB only — cheap rejection before any full read.
    static func partialHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
