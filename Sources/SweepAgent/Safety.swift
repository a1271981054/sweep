import Foundation
import CryptoKit

/// What an agent is never allowed to touch, enforced in code rather than in a
/// prompt. Checked before any planned deletion, regardless of scan results.
public enum Safety {
    /// Never deletable: user documents, source trees, credentials, browser data.
    public static let protectedRoots: [String] = [
        "Documents", "Desktop", "Pictures", "Movies", "Music",
        "Library/Mobile Documents", "/.git", "/.ssh", "/.gnupg",
        "/Library/Keychains", "/.config/gh",
    ]

    public static func isProtected(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        let home = NSHomeDirectory()
        for root in protectedRoots {
            if root.hasPrefix("/") {
                if path.contains(root) { return true }
            } else if path == "\(home)/\(root)" || path.hasPrefix("\(home)/\(root)/") {
                return true
            }
        }
        // Anything inside a git repository's .git directory or a source file
        // extension we can't clean is left alone.
        let components = path.split(separator: "/").map(String.init)
        if components.contains(".git") { return true }
        return false
    }

    /// A plan digest binds an approved plan to the exact set of paths and
    /// sizes. `apply` must echo it back, so a file that changed between the
    /// approval and the execution invalidates the plan instead of being
    /// silently deleted.
    public static func planDigest(_ entries: [(path: String, bytes: UInt64)]) -> String {
        let canonical = entries
            .map { "\($0.path)|\($0.bytes)" }
            .sorted()
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Budget guard for a single operation.
    public struct Budget: Sendable {
        public var maxBytes: UInt64
        public var maxItems: Int

        public init(maxBytes: UInt64 = 20 * 1024 * 1024 * 1024, maxItems: Int = 5000) {
            self.maxBytes = maxBytes
            self.maxItems = maxItems
        }

        public func allows(bytes: UInt64, items: Int) -> Bool {
            bytes <= maxBytes && items <= maxItems
        }
    }
}
