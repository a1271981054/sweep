import Foundation
import Darwin
import MacCleanKit

/// Project junk: dependency and build folders inside code projects.
/// The classification itself is Sweep's `ProjectJunkFinder`; this type builds
/// the directory tree with fast concurrent POSIX traversal, identifies valid
/// junk folders first, and only sizes confirmed targets in parallel.
public struct ProjectJunkScanner {
    static let junkNames: Set<String> = [
        "node_modules", ".next", "dist", "target", "build", ".venv", "venv", "Pods",
    ]

    private static let packageSuffixes: [String] = [
        ".app", ".framework", ".bundle", ".xcodeproj", ".xcworkspace",
        ".photoslibrary", ".photolibrary", ".musiclibrary", ".tvlibrary",
        ".fcpbundle", ".imovielibrary", ".logicx", ".pages", ".numbers", ".key",
    ]

    public init() {}

    public func scan(
        roots: [URL],
        maxDepth: Int = 6,
        limit: Int,
        onProgress: ((Double, String, String, UInt64, Int) -> Void)? = nil
    ) async -> (groups: [ScanGroup], items: [ProjectJunkItem], nodes: Int) {
        let fm = FileManager.default
        var rootPathsSeen = Set<String>()
        var existingRoots: [URL] = []
        for root in roots {
            let p = Self.normalize(root.path(percentEncoded: false))
            if rootPathsSeen.insert(p).inserted && fm.fileExists(atPath: p) && !FileWalker.isPermissionDenied(root) {
                existingRoots.append(URL(fileURLWithPath: p, isDirectory: true))
            }
        }

        onProgress?(0.04, "扫描项目目录", "并发检索项目树", 0, 0)

        var nodes: [ProjectTreeNode] = []
        var subtrees: [(path: String, depth: Int)] = []

        for root in existingRoots {
            if Task.isCancelled { break }
            let rootPath = Self.normalize(root.path(percentEncoded: false))
            let inspection = Self.readDirectoryPOSIX(path: rootPath, readChildrenOfJunk: true)
            nodes.append(
                ProjectTreeNode(
                    path: rootPath,
                    bytes: 0,
                    modified: inspection.modified,
                    childNames: inspection.childNames,
                    gitignoreLines: inspection.hasGitignore ? Self.gitignoreLines(in: rootPath) : []
                )
            )
            for subName in inspection.subdirNames {
                let isJunk = Self.junkNames.contains(subName)
                if !isJunk && subName.hasPrefix(".") { continue }
                if !isJunk && Self.isPackageDirectoryName(subName) { continue }
                subtrees.append((path: "\(rootPath)/\(subName)", depth: 1))
            }
        }

        var walkedDirs = nodes.count

        let collectedBatches = await withTaskGroup(of: [ProjectTreeNode].self) { group in
            let maxConcurrent = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
            var nextIdx = 0

            func enqueue(_ item: (path: String, depth: Int)) {
                group.addTask {
                    var localNodes: [ProjectTreeNode] = []
                    Self.walkSubtree(
                        path: item.path,
                        depth: item.depth,
                        maxDepth: maxDepth,
                        into: &localNodes
                    )
                    return localNodes
                }
            }

            for _ in 0..<min(maxConcurrent, subtrees.count) {
                enqueue(subtrees[nextIdx])
                nextIdx += 1
            }

            var all: [[ProjectTreeNode]] = []
            while let batch = await group.next() {
                all.append(batch)
                walkedDirs += batch.count

                let frac = 0.05 + 0.45 * (1.0 - exp(-Double(walkedDirs) / 1200.0))
                onProgress?(frac, "扫描项目目录", "已遍历 \(walkedDirs) 目录", 0, 0)

                if nextIdx < subtrees.count && !Task.isCancelled {
                    enqueue(subtrees[nextIdx])
                    nextIdx += 1
                }
            }
            return all
        }

        var seen = Set<String>()
        seen.reserveCapacity(walkedDirs + 64)
        var dedupedNodes: [ProjectTreeNode] = []
        dedupedNodes.reserveCapacity(walkedDirs + 64)

        for node in nodes where seen.insert(node.path).inserted {
            dedupedNodes.append(node)
        }
        for batch in collectedBatches {
            for node in batch where seen.insert(node.path).inserted {
                dedupedNodes.append(node)
            }
        }

        onProgress?(0.52, "整理项目列表", "\(dedupedNodes.count) 目录", 0, 0)

        // Filter valid project junk folders first (marker + .gitignore rules) before sizing them.
        let candidates = ProjectJunkFinder.find(nodes: dedupedNodes)
        guard !candidates.isEmpty else { return ([], [], dedupedNodes.count) }

        let totalCandidates = candidates.count
        var doneCount = 0
        var foundBytes: UInt64 = 0
        var foundCount = 0

        let sizedItems = await withTaskGroup(of: ProjectJunkItem.self) { group in
            let maxConcurrent = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
            var nextIdx = 0

            func enqueueCandidate(_ item: ProjectJunkItem) {
                group.addTask {
                    let bytes = Self.directorySize(item.path)
                    return ProjectJunkItem(
                        path: item.path,
                        projectPath: item.projectPath,
                        kind: item.kind,
                        bytes: bytes,
                        projectModified: item.projectModified
                    )
                }
            }

            for _ in 0..<min(maxConcurrent, totalCandidates) {
                enqueueCandidate(candidates[nextIdx])
                nextIdx += 1
            }

            var out: [ProjectJunkItem] = []
            out.reserveCapacity(totalCandidates)

            while let measured = await group.next() {
                out.append(measured)

                doneCount += 1
                if measured.bytes > 0 {
                    foundBytes &+= measured.bytes
                    foundCount += 1
                }

                let label = "\((measured.projectPath as NSString).lastPathComponent)/\((measured.path as NSString).lastPathComponent)"
                let frac = 0.55 + 0.40 * (Double(doneCount) / Double(max(totalCandidates, 1)))
                onProgress?(frac, "计算项目依赖", label, foundBytes, foundCount)

                if nextIdx < totalCandidates && !Task.isCancelled {
                    enqueueCandidate(candidates[nextIdx])
                    nextIdx += 1
                }
            }
            return out
        }

        let items = sizedItems.sorted { lhs, rhs in
            let left = lhs.projectModified ?? .distantFuture
            let right = rhs.projectModified ?? .distantFuture
            if left != right { return left < right }
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.path < rhs.path
        }

        if ProcessInfo.processInfo.environment["SWEEP_DEBUG"] != nil {
            let byPath = Dictionary(dedupedNodes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            for item in items {
                let parent = byPath[item.projectPath]
                FileHandle.standardError.write(Data(
                    "debug: \(item.path) bytes=\(item.bytes) parentFound=\(parent != nil)\n".utf8))
            }
        }

        onProgress?(0.98, "整理项目列表", "\(items.count) 项", foundBytes, foundCount)

        let entries = items
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
            .map {
                ScanEntry(
                    id: Util.stableID($0.path),
                    path: $0.path,
                    bytes: $0.bytes,
                    modified: Util.iso($0.projectModified),
                    kind: $0.kind.rawValue
                )
            }

        let group = ScanGroup(
            category: ScanCategory.projectJunk.rawValue,
            label: CategoryLabels.label(ScanCategory.projectJunk),
            items: items.count,
            bytes: items.reduce(0) { $0 &+ $1.bytes },
            top: Array(entries)
        )
        return ([group], items, dedupedNodes.count)
    }

    private struct DirInspection {
        let modified: Date?
        let childNames: [String]
        let subdirNames: [String]
        let hasGitignore: Bool
    }

    private static func walkSubtree(
        path: String,
        depth: Int,
        maxDepth: Int,
        into nodes: inout [ProjectTreeNode]
    ) {
        if Task.isCancelled { return }
        let name = (path as NSString).lastPathComponent
        let isJunk = Self.junkNames.contains(name)

        if !isJunk && depth >= maxDepth {
            return
        }
        if !isJunk && name.hasPrefix(".") {
            return
        }
        if !isJunk && isPackageDirectoryName(name) {
            return
        }

        // Only venv/.venv inspect childNames (for pyvenv.cfg); skip reading huge node_modules root entries.
        let needChildren = !isJunk || name == ".venv" || name == "venv"
        let inspection = readDirectoryPOSIX(path: path, readChildrenOfJunk: needChildren)

        nodes.append(
            ProjectTreeNode(
                path: path,
                bytes: 0,
                modified: inspection.modified,
                childNames: inspection.childNames,
                gitignoreLines: (!isJunk && inspection.hasGitignore) ? Self.gitignoreLines(in: path) : []
            )
        )

        if isJunk || depth >= maxDepth {
            return
        }

        for childName in inspection.subdirNames {
            let childIsJunk = Self.junkNames.contains(childName)
            if !childIsJunk && childName.hasPrefix(".") { continue }
            if !childIsJunk && isPackageDirectoryName(childName) { continue }
            walkSubtree(
                path: "\(path)/\(childName)",
                depth: depth + 1,
                maxDepth: maxDepth,
                into: &nodes
            )
        }
    }

    private static func readDirectoryPOSIX(path: String, readChildrenOfJunk: Bool) -> DirInspection {
        var dirStat = stat()
        let modified: Date? = lstat(path, &dirStat) == 0
            ? Date(timeIntervalSince1970: Double(dirStat.st_mtimespec.tv_sec) + Double(dirStat.st_mtimespec.tv_nsec) * 1e-9)
            : nil

        guard readChildrenOfJunk, let dir = opendir(path) else {
            return DirInspection(modified: modified, childNames: [], subdirNames: [], hasGitignore: false)
        }
        defer { closedir(dir) }
        let dfd = dirfd(dir)

        var childNames: [String] = []
        var subdirNames: [String] = []
        var hasGitignore = false

        while let dp = readdir(dir) {
            let entryName = withUnsafePointer(to: &dp.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if entryName == "." || entryName == ".." { continue }
            childNames.append(entryName)
            if entryName == ".gitignore" { hasGitignore = true }

            let dType = Int32(dp.pointee.d_type)
            if dType == DT_DIR {
                subdirNames.append(entryName)
            } else if dType == DT_UNKNOWN {
                var st = stat()
                if fstatat(dfd, entryName, &st, AT_SYMLINK_NOFOLLOW) == 0,
                   (st.st_mode & S_IFMT) == S_IFDIR {
                    subdirNames.append(entryName)
                }
            }
        }

        return DirInspection(modified: modified, childNames: childNames, subdirNames: subdirNames, hasGitignore: hasGitignore)
    }

    private static func isPackageDirectoryName(_ name: String) -> Bool {
        guard name.contains(".") else { return false }
        let lower = name.lowercased()
        return packageSuffixes.contains { lower.hasSuffix($0) }
    }

    /// Directory URLs carry a trailing slash; the finder links nodes by exact
    /// parent path, so every path must be normalized before it enters the table.
    static func normalize(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var value = path
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func directorySize(_ path: String) -> UInt64 {
        FileWalker.fastDirectorySize(path)
    }

    static func gitignoreLines(in directory: String) -> [String] {
        let path = (directory as NSString).appendingPathComponent(".gitignore")
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(2000)
            .map { String($0) }
    }
}
