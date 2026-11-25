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
        var expanded: [ScanTarget] = []
        var denied: [URL] = []
        for root in roots {
            let tpl = ScanTarget(path: root, recursive: true, minSize: minSize, skipHiddenDirectories: true)
            let split = FileWalker.expandTopLevelTargets(
                root: root,
                targetTemplate: tpl,
                excludedDirNames: DuplicateScanner.excludedDevDirNames
            )
            if let d = split.deniedPath { denied.append(d) }
            expanded.append(contentsOf: split.targets)
        }
        let result = await walker.scan(
            targets: expanded,
            options: ScanWalkOptions(
                leafOnly: true,
                includeIdentity: false,
                excludedDirNames: DuplicateScanner.excludedDevDirNames,
                pruneDevBuildDirs: true
            )
        )
        denied.append(contentsOf: result.deniedPaths)
        let leaves = result.items.filter { !$0.isDirectory && !$0.isSymlink }
        guard !leaves.isEmpty else { return (nil, Array(Set(denied)), []) }

        let group = ScanGroup(
            category: ScanCategory.largeFiles.rawValue,
            label: CategoryLabels.label(ScanCategory.largeFiles),
            items: leaves.count,
            bytes: FileWalker.leafBytes(of: leaves),
            top: Util.entries(from: leaves, limit: limit)
        )
        return (group, Array(Set(denied)), leaves)
    }

    public func oldFiles(roots: [URL], olderThanDays: Double, limit: Int) async -> (group: ScanGroup?, denied: [URL], all: [FileItem]) {
        let seconds = olderThanDays * 86_400
        var expanded: [ScanTarget] = []
        var denied: [URL] = []
        for root in roots {
            let tpl = ScanTarget(
                path: root,
                recursive: true,
                minAge: seconds,
                minSize: 1024 * 1024,
                skipHiddenDirectories: true
            )
            let split = FileWalker.expandTopLevelTargets(
                root: root,
                targetTemplate: tpl,
                excludedDirNames: DuplicateScanner.excludedDevDirNames
            )
            if let d = split.deniedPath { denied.append(d) }
            expanded.append(contentsOf: split.targets)
        }
        let result = await walker.scan(
            targets: expanded,
            options: ScanWalkOptions(
                leafOnly: true,
                includeIdentity: false,
                excludedDirNames: DuplicateScanner.excludedDevDirNames,
                pruneDevBuildDirs: true
            )
        )
        denied.append(contentsOf: result.deniedPaths)
        let leaves = result.items.filter { !$0.isDirectory && !$0.isSymlink }
        guard !leaves.isEmpty else { return (nil, Array(Set(denied)), []) }

        let group = ScanGroup(
            category: ScanCategory.oldFiles.rawValue,
            label: CategoryLabels.label(ScanCategory.oldFiles),
            items: leaves.count,
            bytes: FileWalker.leafBytes(of: leaves),
            top: Util.entries(from: leaves, limit: limit)
        )
        return (group, Array(Set(denied)), leaves)
    }
}

/// Duplicates: the same four stages Sweep uses — size, partial hash, full
/// hash, hard-link collapse — so only byte-identical copies are reported.
public struct DuplicateScanner {
    public static let maxHashCount = 20_000
    /// Dev dependency / build / VCS directories owned by ProjectJunk — walking millions
    /// of third-party files here starves personal document duplicate detection.
    public static let excludedDevDirNames: Set<String> = [
        "node_modules", ".venv", "venv", "Pods", ".build", ".next", ".nuxt",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".tox", ".dart_tool",
        "DerivedData", "Carthage", ".git", ".hg", ".svn", ".gradle",
    ]

    private let walker: FileWalker

    public init(walker: FileWalker = FileWalker()) {
        self.walker = walker
    }

    public func scan(
        roots: [URL],
        minSize: UInt64,
        limit: Int,
        onProgress: ((Double, String, String, UInt64, Int) -> Void)? = nil
    ) async -> (groups: [ScanGroup], denied: [URL], deletable: [FileItem], hashed: Int) {
        onProgress?(0.02, "遍历文件", "并发扫描目录", 0, 0)

        var targets: [ScanTarget] = []
        var denied: [URL] = []
        for root in roots {
            let tpl = ScanTarget(path: root, recursive: true, minSize: minSize, skipHiddenDirectories: true)
            let split = FileWalker.expandTopLevelTargets(
                root: root,
                targetTemplate: tpl,
                excludedDirNames: Self.excludedDevDirNames
            )
            if let deniedRoot = split.deniedPath {
                denied.append(deniedRoot)
            }
            targets.append(contentsOf: split.targets)
        }

        let walkOptions = ScanWalkOptions(
            leafOnly: true,
            includeIdentity: true,
            excludedDirNames: Self.excludedDevDirNames,
            pruneDevBuildDirs: true
        )
        let result = await walker.scan(targets: targets, options: walkOptions)
        denied.append(contentsOf: result.deniedPaths)
        let files = result.items.filter { !$0.isDirectory && !$0.isSymlink && $0.size > 0 }
        onProgress?(0.28, "遍历文件", "\(files.count) 候选", 0, 0)

        let sizeGroups = DuplicateDetection.sizeGroups(files)
        guard !sizeGroups.isEmpty else {
            onProgress?(1.0, "重复文件", "0 项", 0, 0)
            return ([], Array(Set(denied)), [], 0)
        }

        let partialBudget = min(Self.maxHashCount, sizeGroups.reduce(0) { $0 + $1.count })
        var partialPairs: [(key: String, item: FileItem)] = []
        var hashed = 0
        for group in sizeGroups {
            for item in group where hashed < Self.maxHashCount {
                guard let partial = Self.partialHash(item.url) else { continue }
                partialPairs.append((key: "\(item.size)-\(partial)", item: item))
                hashed += 1
                if hashed % 25 == 0 || hashed == partialBudget {
                    let frac = 0.28 + 0.36 * (Double(hashed) / Double(max(partialBudget, 1)))
                    onProgress?(frac, "部分哈希比对", "\(hashed)/\(partialBudget)", 0, 0)
                }
            }
        }

        let partialGroups = DuplicateDetection.partialGroups(partialPairs)
        guard !partialGroups.isEmpty else {
            onProgress?(1.0, "重复文件", "0 项", 0, 0)
            return ([], Array(Set(denied)), [], hashed)
        }

        let fullBudget = partialGroups.reduce(0) { $0 + $1.count }
        var fullPairs: [(key: String, item: FileItem)] = []
        var fullDone = 0
        for group in partialGroups {
            for item in group {
                fullDone += 1
                guard let full = FileHashing.sha256(item.url) else { continue }
                fullPairs.append((key: full, item: item))
                if fullDone % 10 == 0 || fullDone == fullBudget {
                    let frac = 0.64 + 0.30 * (Double(fullDone) / Double(max(fullBudget, 1)))
                    onProgress?(frac, "全量 SHA-256 校验", "\(fullDone)/\(fullBudget)", 0, 0)
                }
            }
        }

        let fullGroups = DuplicateDetection.fullGroupsAndDedupHardLinks(fullPairs)
        guard !fullGroups.isEmpty else {
            onProgress?(1.0, "重复文件", "0 项", 0, 0)
            return ([], Array(Set(denied)), [], hashed)
        }

        let deletable = DuplicateDetection.extractDeletableDuplicates(fullGroups)
        let bytes = FileWalker.leafBytes(of: deletable)
        onProgress?(0.98, "汇总重复副本", "\(deletable.count) 项", bytes, deletable.count)
        let group = ScanGroup(
            category: ScanCategory.duplicates.rawValue,
            label: CategoryLabels.label(ScanCategory.duplicates),
            items: deletable.count,
            bytes: bytes,
            top: Util.entries(from: deletable, limit: limit)
        )
        return ([group], Array(Set(denied)), deletable, hashed)
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
