import Foundation
import Darwin
import MacCleanKit

/// Result of walking a set of `ScanTarget`s.
public struct WalkResult: Sendable {
    public var items: [FileItem]
    /// Target roots that exist but could not be read (TCC denial or POSIX perms).
    public var deniedPaths: [URL]

    public init(items: [FileItem], deniedPaths: [URL]) {
        self.items = items
        self.deniedPaths = deniedPaths
    }
}

/// Controls how `FileWalker` trades optional metadata for speed.
public struct ScanWalkOptions: Sendable {
    /// Only return regular leaf files (`!isDirectory && !isSymlink`).
    /// When true, uses fast POSIX `fts` traversal without Cocoa `NSURL` / `LaunchServices` overhead.
    public var leafOnly: Bool
    /// Populate `inode` and `deviceID` (needed for hard-link dedup in `duplicates`).
    public var includeIdentity: Bool
    /// Exact directory basenames to prune during recursive leaf traversal.
    public var excludedDirNames: Set<String>
    /// Prune `target` / `build` folders when adjacent project marker files are present.
    public var pruneDevBuildDirs: Bool

    public init(
        leafOnly: Bool = false,
        includeIdentity: Bool = false,
        excludedDirNames: Set<String> = [],
        pruneDevBuildDirs: Bool = false
    ) {
        self.leafOnly = leafOnly
        self.includeIdentity = includeIdentity
        self.excludedDirNames = excludedDirNames
        self.pruneDevBuildDirs = pruneDevBuildDirs
    }
}

/// File walker with the same semantics as Sweep's app-side `TargetedScanner`:
/// hidden-subtree pruning, exclude patterns, max depth, age/size filters,
/// package-descendant skipping and cross-target de-duplication.
public actor FileWalker {
    static let systemKeys: [URLResourceKey] = [
        .fileSizeKey, .totalFileSizeKey,
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .contentModificationDateKey, .nameKey,
    ]

    static let fullKeys: [URLResourceKey] = [
        .fileSizeKey, .fileAllocatedSizeKey,
        .totalFileSizeKey, .totalFileAllocatedSizeKey,
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .contentModificationDateKey, .creationDateKey, .contentAccessDateKey,
        .nameKey,
    ]

    private static let packageSuffixes: [String] = [
        ".app", ".framework", ".bundle", ".xcodeproj", ".xcworkspace",
        ".photoslibrary", ".photolibrary", ".musiclibrary", ".tvlibrary",
        ".fcpbundle", ".imovielibrary", ".logicx", ".pages", ".numbers", ".key",
    ]

    public init() {}

    public nonisolated func scan(
        targets: [ScanTarget],
        options: ScanWalkOptions = ScanWalkOptions()
    ) async -> WalkResult {
        guard !targets.isEmpty else { return WalkResult(items: [], deniedPaths: []) }

        let keys = Self.systemKeys
        let now = Date()

        let perTargetResults: [(items: [FileItem], deniedPath: URL?)]
        if targets.count > 1 {
            let indexed = await withTaskGroup(of: (Int, [FileItem], URL?).self) { group in
                let maxConcurrent = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
                var nextIdx = 0
                for _ in 0..<min(maxConcurrent, targets.count) {
                    let i = nextIdx
                    let t = targets[i]
                    nextIdx += 1
                    group.addTask {
                        let r = Self.scanTarget(t, keys: keys, options: options, now: now)
                        return (i, r.items, r.deniedPath)
                    }
                }
                var collected = Array<(items: [FileItem], deniedPath: URL?)?>(repeating: nil, count: targets.count)
                while let (idx, items, denied) = await group.next() {
                    collected[idx] = (items, denied)
                    if nextIdx < targets.count && !Task.isCancelled {
                        let i = nextIdx
                        let t = targets[i]
                        nextIdx += 1
                        group.addTask {
                            let r = Self.scanTarget(t, keys: keys, options: options, now: now)
                            return (i, r.items, r.deniedPath)
                        }
                    }
                }
                return collected.compactMap { $0 }
            }
            perTargetResults = indexed
        } else {
            perTargetResults = [Self.scanTarget(targets[0], keys: keys, options: options, now: now)]
        }

        if targets.count == 1, let only = perTargetResults.first {
            return WalkResult(items: only.items, deniedPaths: only.deniedPath.map { [$0] } ?? [])
        }

        var items: [FileItem] = []
        var seen = Set<URL>()
        var denied: [URL] = []

        for result in perTargetResults {
            for item in result.items where seen.insert(item.url).inserted {
                items.append(item)
            }
            if let deniedPath = result.deniedPath, !denied.contains(deniedPath) {
                denied.append(deniedPath)
            }
        }
        return WalkResult(items: items, deniedPaths: denied)
    }

    /// A `FileItem` for exactly one known path.
    public static func item(at url: URL) -> FileItem? {
        let keySet = Set(fullKeys)
        guard let values = try? url.resourceValues(forKeys: keySet) else { return nil }
        return makeFileItem(from: url, values: values, includeIdentity: true)
    }

    /// Sums regular files and symlinks in `path` via POSIX `fts`, matching
    /// Cocoa enumerator byte counts without NSURL/LaunchServices overhead.
    public static func fastDirectorySize(_ path: String) -> UInt64 {
        path.withCString { cPath in
            var argv: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: cPath), nil]
            guard let tree = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_COMFOLLOW, nil) else {
                return 0
            }
            defer { fts_close(tree) }

            var total: UInt64 = 0
            while let ent = fts_read(tree) {
                if Task.isCancelled { break }
                let info = Int32(ent.pointee.fts_info)
                if info == FTS_F || info == FTS_SL || info == FTS_SLNONE {
                    if let statp = ent.pointee.fts_statp {
                        total &+= UInt64(max(0, statp.pointee.st_size))
                    }
                }
            }
            return total
        }
    }

    /// Returns direct non-hidden, non-excluded subdirectories + top-level target
    /// for parallelizing large trees such as `~/Documents`.
    public static func expandTopLevelTargets(
        root: URL,
        targetTemplate: ScanTarget,
        excludedDirNames: Set<String> = []
    ) -> (targets: [ScanTarget], deniedPath: URL?) {
        if isPermissionDenied(root) {
            return ([], root)
        }
        let rootPath = root.path(percentEncoded: false)
        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            return ([], nil)
        }
        guard let dir = opendir(rootPath) else {
            return ([], isPermissionDenied(root) ? root : nil)
        }
        defer { closedir(dir) }

        var targets: [ScanTarget] = [
            ScanTarget(
                path: root,
                recursive: false,
                maxDepth: nil,
                fileExtensions: targetTemplate.fileExtensions,
                minAge: targetTemplate.minAge,
                maxAge: targetTemplate.maxAge,
                minSize: targetTemplate.minSize,
                excludePatterns: targetTemplate.excludePatterns,
                skipHiddenDirectories: targetTemplate.skipHiddenDirectories,
                excludedPaths: targetTemplate.excludedPaths
            ),
        ]

        let cleanRoot = rootPath.hasSuffix("/") && rootPath.count > 1 ? String(rootPath.dropLast()) : rootPath
        while let dp = readdir(dir) {
            let name = withUnsafePointer(to: &dp.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            if targetTemplate.skipHiddenDirectories && name.hasPrefix(".") { continue }
            if excludedDirNames.contains(name) { continue }

            let childPath = "\(cleanRoot)/\(name)"
            var childStat = stat()
            guard lstat(childPath, &childStat) == 0 else { continue }
            guard (childStat.st_mode & S_IFMT) == S_IFDIR else { continue }
            if isPackageDirectoryName(name) { continue }

            let childURL = URL(fileURLWithPath: childPath, isDirectory: true)
            if !targetTemplate.excludedPaths.isEmpty && targetTemplate.isExcludedPath(childURL) { continue }
            if !targetTemplate.excludePatterns.isEmpty && matchesExcludePattern(name: name, target: targetTemplate) { continue }

            let nextDepth = targetTemplate.maxDepth.map { max(0, $0 - 1) }
            targets.append(
                ScanTarget(
                    path: childURL,
                    recursive: true,
                    maxDepth: nextDepth,
                    fileExtensions: targetTemplate.fileExtensions,
                    minAge: targetTemplate.minAge,
                    maxAge: targetTemplate.maxAge,
                    minSize: targetTemplate.minSize,
                    excludePatterns: targetTemplate.excludePatterns,
                    skipHiddenDirectories: targetTemplate.skipHiddenDirectories,
                    excludedPaths: targetTemplate.excludedPaths
                )
            )
        }
        return (targets, nil)
    }

    /// Count bytes without double counting: directories report their whole
    /// subtree via `totalFileSize`, and their children are enumerated too, so
    /// only leaves and packages contribute.
    public static func leafBytes(of items: [FileItem]) -> UInt64 {
        items.reduce(0) { partial, item in
            if item.isDirectory && !item.isPackage { return partial }
            return partial &+ item.size
        }
    }

    public static func isPermissionDenied(_ url: URL) -> Bool {
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
        if fd >= 0 { close(fd); return false }
        return errno == EPERM || errno == EACCES
    }

    private static func scanTarget(
        _ target: ScanTarget,
        keys: [URLResourceKey],
        options: ScanWalkOptions,
        now: Date
    ) -> (items: [FileItem], deniedPath: URL?) {
        if options.leafOnly {
            return scanLeavesFastPOSIX(target, options: options, now: now)
        }
        return scanCocoa(target, keys: keys, options: options, now: now)
    }

    private static func scanCocoa(
        _ target: ScanTarget,
        keys: [URLResourceKey],
        options: ScanWalkOptions,
        now: Date
    ) -> (items: [FileItem], deniedPath: URL?) {
        let fm = FileManager.default

        if isPermissionDenied(target.path) {
            return ([], target.path)
        }
        guard fm.fileExists(atPath: target.path.path(percentEncoded: false)) else {
            return ([], nil)
        }

        let keySet = Set(keys)
        let hasExcludedPaths = !target.excludedPaths.isEmpty
        let hasExcludePatterns = !target.excludePatterns.isEmpty
        let extensions = target.fileExtensions
        let hasExtensions = !(extensions?.isEmpty ?? true)
        var results: [FileItem] = []

        if target.recursive {
            guard let enumerator = fm.enumerator(
                at: target.path,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]
            ) else { return ([], nil) }

            while let object = enumerator.nextObject() {
                if Task.isCancelled { break }
                guard let fileURL = object as? URL else { continue }

                if let maxDepth = target.maxDepth, enumerator.level > maxDepth {
                    enumerator.skipDescendants()
                    continue
                }

                let fileName = fileURL.lastPathComponent

                if target.skipHiddenDirectories && fileName.hasPrefix(".") {
                    let isDir = (try? fileURL.resourceValues(forKeys: keySet))?.isDirectory ?? false
                    if isDir { enumerator.skipDescendants() }
                    continue
                }

                if hasExcludedPaths && target.isExcludedPath(fileURL) {
                    enumerator.skipDescendants()
                    continue
                }

                if hasExcludePatterns && matchesExcludePattern(name: fileName, target: target) {
                    let isDir = (try? fileURL.resourceValues(forKeys: keySet))?.isDirectory ?? false
                    if isDir { enumerator.skipDescendants() }
                    continue
                }

                if hasExtensions, let extensions {
                    let ext = fileURL.pathExtension.lowercased()
                    if !extensions.contains(ext) {
                        continue
                    }
                }

                guard let values = try? fileURL.resourceValues(forKeys: keySet) else { continue }
                guard matchesValueFilters(values: values, target: target, now: now) else { continue }

                let item = makeFileItem(from: fileURL, values: values, name: fileName, includeIdentity: options.includeIdentity)
                results.append(item)
            }
        } else {
            guard let contents = try? fm.contentsOfDirectory(
                at: target.path,
                includingPropertiesForKeys: keys
            ) else { return ([], nil) }

            for fileURL in contents {
                if Task.isCancelled { break }
                let fileName = fileURL.lastPathComponent
                if hasExcludedPaths && target.isExcludedPath(fileURL) { continue }
                if hasExcludePatterns && matchesExcludePattern(name: fileName, target: target) { continue }
                if hasExtensions, let extensions {
                    let ext = fileURL.pathExtension.lowercased()
                    if !extensions.contains(ext) { continue }
                }
                guard let values = try? fileURL.resourceValues(forKeys: keySet) else { continue }
                guard matchesValueFilters(values: values, target: target, now: now) else { continue }
                let item = makeFileItem(from: fileURL, values: values, name: fileName, includeIdentity: options.includeIdentity)
                results.append(item)
            }
        }

        return (results, nil)
    }

    private static func scanLeavesFastPOSIX(
        _ target: ScanTarget,
        options: ScanWalkOptions,
        now: Date
    ) -> (items: [FileItem], deniedPath: URL?) {
        if isPermissionDenied(target.path) {
            return ([], target.path)
        }
        let rootPath = target.path.path(percentEncoded: false)
        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0 else {
            return ([], nil)
        }

        let nowSec = now.timeIntervalSince1970
        let hasExcludedPaths = !target.excludedPaths.isEmpty
        let excludedRootPaths = hasExcludedPaths
            ? target.excludedPaths.map { $0.path(percentEncoded: false) }
            : []
        let hasExcludePatterns = !target.excludePatterns.isEmpty
        let extensions = target.fileExtensions
        let hasExtensions = !(extensions?.isEmpty ?? true)
        let minSize = target.minSize
        let minAge = target.minAge
        let maxAge = target.maxAge
        let maxDepth = target.maxDepth
        let skipHidden = target.skipHiddenDirectories
        let excludedDirs = options.excludedDirNames

        if !target.recursive {
            return (
                scanSingleDirLeaves(
                    rootPath: rootPath,
                    skipHidden: skipHidden,
                    hasExcludedPaths: hasExcludedPaths,
                    excludedRootPaths: excludedRootPaths,
                    hasExcludePatterns: hasExcludePatterns,
                    excludePatterns: target.excludePatterns,
                    hasExtensions: hasExtensions,
                    extensions: extensions,
                    minSize: minSize,
                    minAge: minAge,
                    maxAge: maxAge,
                    nowSec: nowSec,
                    includeIdentity: options.includeIdentity
                ),
                nil
            )
        }

        var results: [FileItem] = []
        rootPath.withCString { cPath in
            var argv: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: cPath), nil]
            guard let tree = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_COMFOLLOW, nil) else {
                return
            }
            defer { fts_close(tree) }

            while let ent = fts_read(tree) {
                if Task.isCancelled { break }
                let info = Int32(ent.pointee.fts_info)
                let level = Int(ent.pointee.fts_level)

                if info == FTS_D {
                    if level == 0 {
                        if let maxDepth, maxDepth < 0 {
                            fts_set(tree, ent, FTS_SKIP)
                        }
                        continue
                    }

                    if let maxDepth, level > maxDepth {
                        fts_set(tree, ent, FTS_SKIP)
                        continue
                    }

                    let pathLen = Int(ent.pointee.fts_pathlen)
                    let nameLen = Int(ent.pointee.fts_namelen)
                    let namePtr = ent.pointee.fts_path.advanced(by: max(0, pathLen - nameLen))

                    if skipHidden && namePtr.pointee == 46 { // '.'
                        fts_set(tree, ent, FTS_SKIP)
                        continue
                    }

                    let name = String(cString: namePtr)
                    if isPackageDirectoryName(name) {
                        fts_set(tree, ent, FTS_SKIP)
                        continue
                    }
                    if excludedDirs.contains(name) {
                        fts_set(tree, ent, FTS_SKIP)
                        continue
                    }
                    if options.pruneDevBuildDirs && shouldPruneDevBuildDir(name: name, ftsPath: ent.pointee.fts_path, pathLen: pathLen, nameLen: nameLen) {
                        fts_set(tree, ent, FTS_SKIP)
                        continue
                    }
                    if hasExcludePatterns && containsExcludePattern(name, patterns: target.excludePatterns) {
                        fts_set(tree, ent, FTS_SKIP)
                        continue
                    }
                    if hasExcludedPaths {
                        let fullPath = String(cString: ent.pointee.fts_path)
                        if excludedRootPaths.contains(where: { PathExclusion.isInside(fullPath, root: $0) }) {
                            fts_set(tree, ent, FTS_SKIP)
                            continue
                        }
                    }
                    continue
                }

                guard info == FTS_F else { continue }
                if let maxDepth, level > maxDepth { continue }
                guard let statp = ent.pointee.fts_statp else { continue }
                let st = statp.pointee
                let fileSize = UInt64(max(0, st.st_size))
                if let minSize, fileSize < minSize { continue }

                if minAge != nil || maxAge != nil {
                    let modSec = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) * 1e-9
                    let age = nowSec - modSec
                    if let minAge, age < minAge { continue }
                    if let maxAge, age > maxAge { continue }
                }

                let pathLen = Int(ent.pointee.fts_pathlen)
                let nameLen = Int(ent.pointee.fts_namelen)
                let namePtr = ent.pointee.fts_path.advanced(by: max(0, pathLen - nameLen))
                if skipHidden && namePtr.pointee == 46 { continue }

                let name = String(cString: namePtr)
                if hasExtensions, let extensions {
                    let ext = fileExtensionLower(name)
                    if !extensions.contains(ext) { continue }
                }
                if hasExcludePatterns && containsExcludePattern(name, patterns: target.excludePatterns) {
                    continue
                }

                let fullPath = String(cString: ent.pointee.fts_path)
                if hasExcludedPaths {
                    if excludedRootPaths.contains(where: { PathExclusion.isInside(fullPath, root: $0) }) {
                        continue
                    }
                }

                let modDate = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) * 1e-9)
                let createDate = Date(timeIntervalSince1970: Double(st.st_birthtimespec.tv_sec) + Double(st.st_birthtimespec.tv_nsec) * 1e-9)
                let url = URL(fileURLWithPath: fullPath, isDirectory: false)
                results.append(
                    FileItem(
                        url: url,
                        name: name,
                        size: fileSize,
                        allocatedSize: 0,
                        isDirectory: false,
                        isSymlink: false,
                        isPackage: false,
                        contentType: nil,
                        creationDate: createDate,
                        modificationDate: modDate,
                        lastAccessDate: nil,
                        inode: options.includeIdentity ? UInt64(st.st_ino) : 0,
                        deviceID: options.includeIdentity ? Int32(st.st_dev) : 0
                    )
                )
            }
        }
        return (results, nil)
    }

    private static func scanSingleDirLeaves(
        rootPath: String,
        skipHidden: Bool,
        hasExcludedPaths: Bool,
        excludedRootPaths: [String],
        hasExcludePatterns: Bool,
        excludePatterns: [String],
        hasExtensions: Bool,
        extensions: Set<String>?,
        minSize: UInt64?,
        minAge: TimeInterval?,
        maxAge: TimeInterval?,
        nowSec: TimeInterval,
        includeIdentity: Bool
    ) -> [FileItem] {
        guard let dir = opendir(rootPath) else { return [] }
        defer { closedir(dir) }
        let dfd = dirfd(dir)
        let cleanRoot = rootPath.hasSuffix("/") && rootPath.count > 1 ? String(rootPath.dropLast()) : rootPath
        var results: [FileItem] = []

        while let dp = readdir(dir) {
            if Task.isCancelled { break }
            let name = withUnsafePointer(to: &dp.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            if skipHidden && name.hasPrefix(".") { continue }
            if hasExtensions, let extensions {
                if !extensions.contains(fileExtensionLower(name)) { continue }
            }
            if hasExcludePatterns && containsExcludePattern(name, patterns: excludePatterns) { continue }

            var st = stat()
            guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            guard (st.st_mode & S_IFMT) == S_IFREG else { continue }

            let fileSize = UInt64(max(0, st.st_size))
            if let minSize, fileSize < minSize { continue }

            let modSec = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) * 1e-9
            if minAge != nil || maxAge != nil {
                let age = nowSec - modSec
                if let minAge, age < minAge { continue }
                if let maxAge, age > maxAge { continue }
            }

            let fullPath = "\(cleanRoot)/\(name)"
            if hasExcludedPaths {
                if excludedRootPaths.contains(where: { PathExclusion.isInside(fullPath, root: $0) }) { continue }
            }

            let createSec = Double(st.st_birthtimespec.tv_sec) + Double(st.st_birthtimespec.tv_nsec) * 1e-9
            results.append(
                FileItem(
                    url: URL(fileURLWithPath: fullPath, isDirectory: false),
                    name: name,
                    size: fileSize,
                    allocatedSize: 0,
                    isDirectory: false,
                    isSymlink: false,
                    isPackage: false,
                    contentType: nil,
                    creationDate: Date(timeIntervalSince1970: createSec),
                    modificationDate: Date(timeIntervalSince1970: modSec),
                    lastAccessDate: nil,
                    inode: includeIdentity ? UInt64(st.st_ino) : 0,
                    deviceID: includeIdentity ? Int32(st.st_dev) : 0
                )
            )
        }
        return results
    }

    private static func shouldPruneDevBuildDir(
        name: String,
        ftsPath: UnsafePointer<CChar>,
        pathLen: Int,
        nameLen: Int
    ) -> Bool {
        let checkTarget = name == "target"
        let checkBuild = name == "build"
        guard checkTarget || checkBuild else { return false }

        let parentLen = max(0, pathLen - nameLen)
        let prefix = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(ftsPath).assumingMemoryBound(to: UInt8.self), count: parentLen), as: UTF8.self)
        if checkTarget {
            return access("\(prefix)Cargo.toml", F_OK) == 0 || access("\(prefix)pom.xml", F_OK) == 0
        }
        return access("\(prefix)build.gradle", F_OK) == 0
            || access("\(prefix)build.gradle.kts", F_OK) == 0
            || access("\(prefix)package.json", F_OK) == 0
            || access("\(prefix)pyproject.toml", F_OK) == 0
            || access("\(prefix)Package.swift", F_OK) == 0
            || access("\(prefix)CMakeLists.txt", F_OK) == 0
    }

    private static func isPackageDirectoryName(_ name: String) -> Bool {
        guard name.contains(".") else { return false }
        let lower = name.lowercased()
        return packageSuffixes.contains { lower.hasSuffix($0) }
    }

    private static func fileExtensionLower(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    private static func containsExcludePattern(_ name: String, patterns: [String]) -> Bool {
        for pattern in patterns where name.localizedCaseInsensitiveContains(pattern) {
            return true
        }
        return false
    }

    private static func matchesExcludePattern(name: String, target: ScanTarget) -> Bool {
        containsExcludePattern(name, patterns: target.excludePatterns)
    }

    private static func matchesValueFilters(values: URLResourceValues, target: ScanTarget, now: Date) -> Bool {
        if let minSize = target.minSize {
            let isDir = values.isDirectory ?? false
            let size = UInt64((isDir ? (values.totalFileSize ?? values.fileSize) : (values.fileSize ?? values.totalFileSize)) ?? 0)
            if size < minSize { return false }
        }
        if target.minAge != nil || target.maxAge != nil {
            if let modDate = values.contentModificationDate {
                let age = now.timeIntervalSince(modDate)
                if let minAge = target.minAge, age < minAge { return false }
                if let maxAge = target.maxAge, age > maxAge { return false }
            }
        }
        return true
    }

    private static func makeFileItem(
        from url: URL,
        values: URLResourceValues,
        name: String? = nil,
        includeIdentity: Bool
    ) -> FileItem {
        let isDir = values.isDirectory ?? false
        let isPkg = values.isPackage ?? false
        let size = UInt64(((isDir || isPkg) ? (values.totalFileSize ?? values.fileSize) : (values.fileSize ?? values.totalFileSize)) ?? 0)

        var inode: UInt64 = 0
        var deviceID: Int32 = 0
        if includeIdentity {
            var metadata = stat()
            if lstat(url.path(percentEncoded: false), &metadata) == 0 {
                inode = UInt64(metadata.st_ino)
                deviceID = Int32(metadata.st_dev)
            }
        }

        return FileItem(
            url: url,
            name: values.name ?? name ?? url.lastPathComponent,
            size: size,
            allocatedSize: 0,
            isDirectory: isDir,
            isSymlink: values.isSymbolicLink ?? false,
            isPackage: isPkg,
            contentType: nil,
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate,
            lastAccessDate: nil,
            inode: inode,
            deviceID: deviceID
        )
    }
}
