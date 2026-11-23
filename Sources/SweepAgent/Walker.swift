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

/// File walker with the same semantics as Sweep's app-side `TargetedScanner`:
/// hidden-subtree pruning, exclude patterns, max depth, age/size filters,
/// package-descendant skipping and cross-target de-duplication.
public actor FileWalker {
    static let resourceKeys: [URLResourceKey] = [
        .fileSizeKey, .fileAllocatedSizeKey,
        .totalFileSizeKey, .totalFileAllocatedSizeKey,
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .contentModificationDateKey, .creationDateKey, .contentAccessDateKey,
        .contentTypeKey, .nameKey,
    ]

    public init() {}

    public func scan(targets: [ScanTarget]) async -> WalkResult {
        var items: [FileItem] = []
        var seen = Set<URL>()
        var denied: [URL] = []

        for target in targets {
            let result = Self.scanTarget(target, keys: Self.resourceKeys)
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
        makeFileItem(from: url, keys: resourceKeys)
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

    private static func isPermissionDenied(_ url: URL) -> Bool {
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
        if fd >= 0 { close(fd); return false }
        return errno == EPERM || errno == EACCES
    }

    private static func scanTarget(_ target: ScanTarget, keys: [URLResourceKey]) -> (items: [FileItem], deniedPath: URL?) {
        let fm = FileManager.default

        if isPermissionDenied(target.path) {
            return ([], target.path)
        }
        guard fm.fileExists(atPath: target.path.path(percentEncoded: false)) else {
            return ([], nil)
        }

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

                if let maxDepth = target.maxDepth {
                    let rootPath = target.path.path(percentEncoded: false)
                    let relative = fileURL.path(percentEncoded: false).dropFirst(rootPath.count)
                    let depth = relative.components(separatedBy: "/").count - 1
                    if depth > maxDepth {
                        enumerator.skipDescendants()
                        continue
                    }
                }

                if target.skipHiddenDirectories && ScanTarget.isHiddenEntry(fileURL) {
                    let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir { enumerator.skipDescendants() }
                    continue
                }

                if target.isExcludedPath(fileURL) {
                    enumerator.skipDescendants()
                    continue
                }

                if matchesExcludePattern(url: fileURL, target: target) {
                    let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir { enumerator.skipDescendants() }
                    continue
                }

                if matchesTarget(url: fileURL, target: target),
                   let item = makeFileItem(from: fileURL, keys: keys) {
                    results.append(item)
                }
            }
        } else {
            guard let contents = try? fm.contentsOfDirectory(
                at: target.path,
                includingPropertiesForKeys: keys
            ) else { return ([], nil) }

            for fileURL in contents {
                if Task.isCancelled { break }
                if target.isExcludedPath(fileURL) { continue }
                if matchesTarget(url: fileURL, target: target),
                   let item = makeFileItem(from: fileURL, keys: keys) {
                    results.append(item)
                }
            }
        }

        return (results, nil)
    }

    private static func matchesExcludePattern(url: URL, target: ScanTarget) -> Bool {
        let name = url.lastPathComponent
        for pattern in target.excludePatterns where name.localizedCaseInsensitiveContains(pattern) {
            return true
        }
        return false
    }

    private static func matchesTarget(url: URL, target: ScanTarget) -> Bool {
        if matchesExcludePattern(url: url, target: target) { return false }

        if let extensions = target.fileExtensions, !extensions.isEmpty {
            let ext = url.pathExtension.lowercased()
            if !extensions.contains(ext) { return false }
        }

        if target.minSize != nil || target.minAge != nil || target.maxAge != nil {
            guard let values = try? url.resourceValues(forKeys: Set([
                .fileSizeKey, .totalFileSizeKey, .contentModificationDateKey,
            ])) else { return false }

            if let minSize = target.minSize {
                let size = UInt64(values.totalFileSize ?? values.fileSize ?? 0)
                if size < minSize { return false }
            }

            if let modDate = values.contentModificationDate {
                let age = Date().timeIntervalSince(modDate)
                if let minAge = target.minAge, age < minAge { return false }
                if let maxAge = target.maxAge, age > maxAge { return false }
            }
        }
        return true
    }

    private static func makeFileItem(from url: URL, keys: [URLResourceKey]) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }

        var metadata = stat()
        let hasIdentity = lstat(url.path(percentEncoded: false), &metadata) == 0

        return FileItem(
            url: url,
            name: values.name ?? url.lastPathComponent,
            size: UInt64(values.totalFileSize ?? values.fileSize ?? 0),
            allocatedSize: UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
            isDirectory: values.isDirectory ?? false,
            isSymlink: values.isSymbolicLink ?? false,
            isPackage: values.isPackage ?? false,
            contentType: values.contentType,
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate,
            lastAccessDate: values.contentAccessDate,
            inode: hasIdentity ? UInt64(metadata.st_ino) : 0,
            deviceID: hasIdentity ? Int32(metadata.st_dev) : 0
        )
    }
}
