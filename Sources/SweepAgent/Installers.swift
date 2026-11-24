import Foundation
import MacCleanKit

/// Installer files that are either stale or belong to software that is not on
/// this Mac. "Not installed" is a heuristic, so the caller must treat it as a
/// suggestion: it compares installer names against the apps in /Applications.
public struct InstallersScanner {
    public static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg"]

    /// Words that say nothing about which app an installer carries.
    static let noiseWords: Set<String> = [
        "mac", "macos", "osx", "darwin", "arm64", "x64", "x86", "x86_64", "universal",
        "setup", "installer", "install", "install", "latest", "release", "stable",
        "cn", "zh", "en", "app", "dmg", "pkg", "zip", "final", "beta", "alpha",
    ]

    public init() {}

    public struct Result: Sendable {
        public let entries: [ScanEntry]
        public let groups: [ScanGroup]
        public let deniedPaths: [URL]
    }

    public func scan(
        roots: [URL],
        olderThanDays: Double = 30,
        notInstalledOnly: Bool = false,
        limit: Int = 40
    ) async -> Result {
        let fileManager = FileManager.default
        let installed = Self.installedApps()
        let cutoff = Date().addingTimeInterval(-olderThanDays * 86_400)

        var stale: [ScanEntry] = []
        var missing: [ScanEntry] = []
        var denied: [URL] = []

        for root in roots {
            guard fileManager.fileExists(atPath: root.path(percentEncoded: false)) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let object = enumerator.nextObject() {
                guard let url = object as? URL else { continue }
                let values = try? url.resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey,
                ])

                let ext = url.pathExtension.lowercased()
                let isBundleApp = values?.isDirectory == true && ext == "app"
                guard isBundleApp || Self.installerExtensions.contains(ext) else { continue }

                let name = url.deletingPathExtension().lastPathComponent
                let state = Self.installationState(
                    installerName: name,
                    url: url,
                    isBundle: isBundleApp,
                    installed: installed
                )

                let bytes: UInt64
                if isBundleApp {
                    bytes = Self.directorySize(url)
                } else {
                    bytes = UInt64(values?.fileSize ?? 0)
                }
                guard bytes > 0 else { continue }

                let modified = values?.contentModificationDate
                let entry = ScanEntry(
                    id: Util.stableID(url.path(percentEncoded: false)),
                    path: url.path(percentEncoded: false),
                    bytes: bytes,
                    modified: Util.iso(modified),
                    kind: state.label,
                    category: state.category
                )

                if state.category == "uninstalled_installers" {
                    missing.append(entry)
                } else if let modified, modified < cutoff {
                    stale.append(entry)
                }
            }
        }

        var groups: [ScanGroup] = []
        if !stale.isEmpty {
            groups.append(Self.group(
                category: "unused_disk_images",
                label: "过期安装包",
                entries: stale,
                limit: limit
            ))
        }
        if !missing.isEmpty {
            groups.append(Self.group(
                category: "uninstalled_installers",
                label: "尚未安装",
                entries: missing,
                limit: limit
            ))
        }

        let entries = stale + missing
        return Result(entries: entries, groups: groups, deniedPaths: denied)
    }

    // MARK: - Helpers

    struct AppFingerprint {
        let bundleID: String?
        let normalizedName: String
    }

    enum InstallationState {
        case installed(String)
        case notInstalled
        case unknown

        var category: String {
            switch self {
            case .notInstalled: return "uninstalled_installers"
            case .installed, .unknown: return "unused_disk_images"
            }
        }

        var label: String {
            switch self {
            case .installed(let name): return "已安装 \(name)"
            case .notInstalled: return "未安装"
            case .unknown: return "未知"
            }
        }
    }

    static func installationState(
        installerName: String,
        url: URL,
        isBundle: Bool,
        installed: [AppFingerprint]
    ) -> InstallationState {
        // A dropped .app is decided by bundle id; anything else by name.
        if isBundle,
           let bundleID = Bundle(url: url)?.bundleIdentifier,
           installed.contains(where: { $0.bundleID == bundleID }) {
            return .installed(URL(fileURLWithPath: url.path).deletingPathExtension().lastPathComponent)
        }

        let tokens = significantTokens(installerName)
        guard let brand = tokens.first, brand.count >= 4 else { return .unknown }

        // Only the brand token counts, and it must line up with an app name:
        // a bare "contains" match turned unrelated apps into matches.
        if let match = installed.first(where: { fingerprint in
            let app = fingerprint.normalizedName
            return app.hasPrefix(brand) || brand.hasPrefix(app)
                || (app.contains(brand) && brand.count >= 6)
        }) {
            return .installed(match.normalizedName)
        }
        return .notInstalled
    }

    static func significantTokens(_ name: String) -> [String] {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                guard token.count >= 3 else { return false }
                if noiseWords.contains(token) { return false }
                // Drop pure version fragments such as "1", "2", "10", "0", "8".
                if token.allSatisfy(\.isNumber) { return false }
                // Drop "v1", "v2", "10.0.8".
                if token.first == "v", token.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) {
                    return false
                }
                return true
            }
    }

    static func installedApps() -> [AppFingerprint] {
        let roots = ["/Applications", "\(NSHomeDirectory())/Applications"]
        var result: [AppFingerprint] = []
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for name in names where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: root).appendingPathComponent(name)
                let bundleID = Bundle(url: url)?.bundleIdentifier
                let normalized = name
                    .replacingOccurrences(of: ".app", with: "")
                    .lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .joined()
                result.append(AppFingerprint(bundleID: bundleID, normalizedName: normalized))
            }
        }
        return result
    }

    static func directorySize(_ url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return 0 }
        var total: UInt64 = 0
        while let object = enumerator.nextObject() {
            guard let fileURL = object as? URL,
                  let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory != true
            else { continue }
            total &+= UInt64(values.fileSize ?? 0)
        }
        return total
    }

    static func group(category: String, label: String, entries: [ScanEntry], limit: Int) -> ScanGroup {
        let sorted = entries.sorted { $0.bytes > $1.bytes }
        return ScanGroup(
            category: category,
            label: label,
            items: entries.count,
            bytes: entries.reduce(0) { $0 &+ $1.bytes },
            top: Array(sorted.prefix(limit))
        )
    }
}
