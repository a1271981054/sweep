import Foundation
import Darwin

public struct TrashEntry: Codable, Sendable {
    public let name: String
    public let path: String
    public let bytes: UInt64
    public let isDirectory: Bool
    public let modified: String?

    public func asDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "path": path,
            "bytes": bytes,
            "isDirectory": isDirectory,
        ]
        if let modified { dict["modified"] = modified }
        return dict
    }
}

public struct TrashSummary: Codable, Sendable {
    public let items: Int
    public let bytes: UInt64
    public let digest: String
    public let denied: Bool
    public let top: [TrashEntry]

    public func asDictionary() -> [String: Any] {
        [
            "items": items,
            "bytes": bytes,
            "digest": digest,
            "denied": denied,
            "top": top.map { $0.asDictionary() },
        ]
    }
}

public struct TrashEmptyResult: Codable, Sendable {
    public let operationId: String?
    public let deletedCount: Int
    public let deletedBytes: UInt64
    public let failedCount: Int
    public let failures: [String]
    public let remainingCount: Int
    public let remainingBytes: UInt64

    public func asDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "deletedCount": deletedCount,
            "deletedBytes": deletedBytes,
            "failedCount": failedCount,
            "failures": failures,
            "remainingCount": remainingCount,
            "remainingBytes": remainingBytes,
        ]
        if let operationId { dict["operationId"] = operationId }
        return dict
    }
}

private struct TrashAuditRecord: Codable {
    let id: String
    let createdAt: String
    let digest: String
    let mode: String
    let deletedCount: Int
    let failedCount: Int
    let deletedBytes: UInt64
}

public enum TrashStore {
    private static let metadataNames: Set<String> = [".DS_Store", ".localized"]

    public static var trashDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true)
    }

    /// Enumerates `~/.Trash` (or `trashDirectory`) top-level items, sizing folders via fast
    /// POSIX `fts` while refusing to follow top-level symlinks.
    public static func inspect(limit: Int = 50, trashDirectory: URL = TrashStore.trashDirectory) -> TrashSummary {
        let result = scanEntries(in: trashDirectory)
        let topEntries = Array(result.entries.prefix(max(1, limit)))
        return TrashSummary(
            items: result.entries.count,
            bytes: result.totalBytes,
            digest: result.digest,
            denied: result.denied,
            top: topEntries
        )
    }

    /// Permanently removes every user item from `~/.Trash` (or `trashDirectory`).
    public static func empty(
        expectedDigest: String? = nil,
        trashDirectory: URL = TrashStore.trashDirectory,
        writeAudit: Bool = true
    ) throws -> TrashEmptyResult {
        let config = AgentConfigStore.load()
        guard !config.isReadOnly else { throw CleanError.readOnly }

        let scan = scanEntries(in: trashDirectory)
        guard !scan.denied else { throw CleanError.trashAccessDenied }

        if scan.entries.isEmpty {
            return TrashEmptyResult(
                operationId: nil,
                deletedCount: 0,
                deletedBytes: 0,
                failedCount: 0,
                failures: [],
                remainingCount: 0,
                remainingBytes: 0
            )
        }

        if let expectedDigest, !expectedDigest.isEmpty {
            guard expectedDigest == scan.digest else { throw CleanError.digestMismatch }
        }

        let fm = FileManager.default
        var deletedCount = 0
        var deletedBytes: UInt64 = 0
        var failures: [String] = []
        var remainingCount = 0
        var remainingBytes: UInt64 = 0

        for entry in scan.entries {
            let targetURL = URL(fileURLWithPath: entry.path)
            do {
                try fm.removeItem(at: targetURL)
                deletedCount += 1
                deletedBytes &+= entry.bytes
            } catch {
                failures.append("\(entry.name): \(error.localizedDescription)")
                remainingCount += 1
                remainingBytes &+= entry.bytes
            }
        }

        let opId = UUID().uuidString.prefix(8).lowercased()
        if writeAudit {
            let audit = TrashAuditRecord(
                id: opId,
                createdAt: Util.nowISO(),
                digest: scan.digest,
                mode: config.mode,
                deletedCount: deletedCount,
                failedCount: failures.count,
                deletedBytes: deletedBytes
            )
            appendAudit(audit)
        }

        return TrashEmptyResult(
            operationId: deletedCount > 0 ? opId : nil,
            deletedCount: deletedCount,
            deletedBytes: deletedBytes,
            failedCount: failures.count,
            failures: failures,
            remainingCount: remainingCount,
            remainingBytes: remainingBytes
        )
    }

    private static func scanEntries(in root: URL) -> (entries: [TrashEntry], totalBytes: UInt64, digest: String, denied: Bool) {
        let fm = FileManager.default

        guard fm.fileExists(atPath: root.path) else {
            return ([], 0, Safety.planDigest([]), false)
        }
        if FileWalker.isPermissionDenied(root) {
            return ([], 0, Safety.planDigest([]), true)
        }

        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )
        } catch let error as NSError {
            let denied = error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoPermissionError)
                || (error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)))
            return ([], 0, Safety.planDigest([]), denied)
        }

        var entries: [TrashEntry] = []
        var totalBytes: UInt64 = 0
        var digestPairs: [(path: String, bytes: UInt64)] = []

        for url in urls {
            let name = url.lastPathComponent
            if metadataNames.contains(name) { continue }

            let fullPath = url.path(percentEncoded: false)
            var st = stat()
            guard lstat(fullPath, &st) == 0 else { continue }

            let mode = st.st_mode & S_IFMT
            let isDir = mode == S_IFDIR
            let isSymlink = mode == S_IFLNK
            let itemBytes: UInt64
            if isDir && !isSymlink {
                itemBytes = FileWalker.fastDirectorySize(fullPath)
            } else {
                itemBytes = UInt64(max(0, st.st_size))
            }

            let modifiedDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))

            entries.append(
                TrashEntry(
                    name: name,
                    path: fullPath,
                    bytes: itemBytes,
                    isDirectory: isDir,
                    modified: Util.iso(modifiedDate)
                )
            )
            totalBytes &+= itemBytes
            digestPairs.append((fullPath, itemBytes))
        }

        entries.sort { $0.bytes > $1.bytes }
        let digest = Safety.planDigest(digestPairs)
        return (entries, totalBytes, digest, false)
    }

    private static func appendAudit(_ record: TrashAuditRecord) {
        AgentPaths.ensure()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        let url = AgentPaths.trashEmpties
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}

/// Bridges CLI / MCP Trash requests through the FDA-privileged helper HTTP API
/// when the caller process cannot access `~/.Trash` directly.
public enum HelperTrashBridge {
    public static func inspect() -> [String: Any]? {
        request(method: "GET", path: "/api/trash", body: nil)
    }

    public static func empty(digest: String?) -> (payload: [String: Any]?, error: String?) {
        var bodyData: Data? = nil
        if let digest, !digest.isEmpty {
            bodyData = try? JSONSerialization.data(withJSONObject: ["digest": digest], options: [])
        } else {
            bodyData = Data("{}".utf8)
        }
        guard let res = requestRaw(method: "POST", path: "/api/trash/empty", body: bodyData) else {
            return (nil, nil)
        }
        if res.status >= 400 {
            let msg = (res.json?["error"] as? String) ?? "helper empty trash failed (\(res.status))"
            return (nil, msg)
        }
        return (res.json, nil)
    }

    private static func request(method: String, path: String, body: Data?) -> [String: Any]? {
        guard let res = requestRaw(method: method, path: path, body: body), res.status < 400 else {
            return nil
        }
        return res.json
    }

    private static func requestRaw(method: String, path: String, body: Data?) -> (status: Int, json: [String: Any]?)? {
        guard HelperClient.isAvailable(),
              let url = URL(string: "http://127.0.0.1:\(StatusServer.defaultPort)\(path)")
        else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let sem = DispatchSemaphore(value: 0)
        var outStatus = 0
        var outJSON: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                outStatus = http.statusCode
            }
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                outJSON = obj
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 31)
        guard outStatus > 0 else { return nil }
        return (outStatus, outJSON)
    }
}

public enum TrashService {
    public static func inspect(limit: Int = 50) -> TrashSummary {
        let local = TrashStore.inspect(limit: limit)
        if !local.denied { return local }
        guard let dict = HelperTrashBridge.inspect(),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let bridged = try? JSONDecoder().decode(TrashSummary.self, from: data)
        else { return local }
        return bridged
    }

    public static func empty(expectedDigest: String? = nil) throws -> TrashEmptyResult {
        do {
            return try TrashStore.empty(expectedDigest: expectedDigest)
        } catch CleanError.trashAccessDenied {
            let bridged = HelperTrashBridge.empty(digest: expectedDigest)
            if let message = bridged.error {
                throw NSError(domain: "sweep.trash", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            guard let payload = bridged.payload,
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                  let result = try? JSONDecoder().decode(TrashEmptyResult.self, from: data)
            else {
                throw CleanError.trashAccessDenied
            }
            return result
        }
    }
}
