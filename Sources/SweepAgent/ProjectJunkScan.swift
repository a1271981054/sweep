import Foundation
import MacCleanKit

/// Project junk: dependency and build folders inside code projects.
/// The classification itself is Sweep's `ProjectJunkFinder`; this type only
/// builds the directory tree it expects (parent-child linkage + `.gitignore`).
public struct ProjectJunkScanner {
    static let junkNames: Set<String> = [
        "node_modules", ".next", "dist", "target", "build", ".venv", "venv", "Pods",
    ]

    public init() {}

    public func scan(
        roots: [URL],
        maxDepth: Int = 6,
        limit: Int
    ) async -> (groups: [ScanGroup], items: [ProjectJunkItem], nodes: Int) {
        var nodes: [ProjectTreeNode] = []
        var seen = Set<String>()

        for root in roots {
            let fm = FileManager.default
            guard fm.fileExists(atPath: root.path(percentEncoded: false)) else { continue }

            let rootPath = Self.normalize(root.path(percentEncoded: false))
            if seen.insert(rootPath).inserted {
                let rootChildren = (try? fm.contentsOfDirectory(atPath: rootPath)) ?? []
                let rootModified = try? root.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                nodes.append(
                    ProjectTreeNode(
                        path: rootPath,
                        bytes: 0,
                        modified: rootModified,
                        childNames: rootChildren,
                        gitignoreLines: rootChildren.contains(".gitignore") ? Self.gitignoreLines(in: rootPath) : []
                    )
                )
            }

            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants]
            )
            while let object = enumerator?.nextObject() {
                guard let url = object as? URL else { continue }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }

                let path = Self.normalize(url.path(percentEncoded: false))
                let relative = path.dropFirst(root.path(percentEncoded: false).count)
                let depth = relative.components(separatedBy: "/").count - 1

                let name = url.lastPathComponent
                let isJunkName = Self.junkNames.contains(name)

                // Never descend into a junk folder; it is a leaf candidate.
                if isJunkName {
                    enumerator?.skipDescendants()
                } else if depth >= maxDepth {
                    enumerator?.skipDescendants()
                    continue
                } else if ScanTarget.isHiddenEntry(url) {
                    // Hidden folders hold app/tool state, not project junk.
                    enumerator?.skipDescendants()
                    continue
                }

                guard seen.insert(path).inserted else { continue }

                let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let bytes = isJunkName ? Self.directorySize(path) : 0

                nodes.append(
                    ProjectTreeNode(
                        path: path,
                        bytes: bytes,
                        modified: modified,
                        childNames: children,
                        gitignoreLines: children.contains(".gitignore") ? Self.gitignoreLines(in: path) : []
                    )
                )
            }
        }

        if ProcessInfo.processInfo.environment["SWEEP_DEBUG"] != nil {
            let byPath = Dictionary(nodes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            for node in nodes where Self.junkNames.contains((node.path as NSString).lastPathComponent) {
                let parentPath = (node.path as NSString).deletingLastPathComponent
                let parent = byPath[parentPath]
                let kids = parent.map { Set($0.childNames) } ?? []
                let markers = ["package.json", "Cargo.toml", "pyproject.toml", "build.gradle", "pom.xml", "Podfile"]
                    .filter { kids.contains($0) }
                let hasCfg = node.childNames.contains("pyvenv.cfg")
                FileHandle.standardError.write(Data(
                    "debug: \(node.path)\n        parentInTable=\(parent != nil) siblings=\(kids.count) markers=\(markers) pyvenv=\(hasCfg)\n".utf8))
            }
        }

        let items = ProjectJunkFinder.find(nodes: nodes)
        guard !items.isEmpty else { return ([], [], nodes.count) }

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
        return ([group], items, nodes.count)
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
        let url = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .totalFileSizeKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return 0 }

        var total: UInt64 = 0
        while let object = enumerator.nextObject() {
            guard let fileURL = object as? URL,
                  let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey, .isDirectoryKey])
            else { continue }
            if values.isDirectory == true { continue }
            total &+= UInt64(values.fileSize ?? 0)
        }
        return total
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
