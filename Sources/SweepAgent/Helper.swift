import Foundation
import MacCleanKit

/// Full Disk Access helper.
///
/// A client-spawned MCP server inherits the client's TCC identity, so every
/// client (DSH, Codex, Cursor, …) would need its own Full Disk Access grant.
/// Instead one launchd agent runs `Sweep Helper.app` — a stable bundle id, so
/// the grant survives upgrades — and clients hand it scan requests through a
/// queue directory. One grant, every client.
public enum HelperPaths {
    public static var root: URL { AgentPaths.root.appendingPathComponent("helper", isDirectory: true) }
    public static var queue: URL { root.appendingPathComponent("queue", isDirectory: true) }
    public static var out: URL { root.appendingPathComponent("out", isDirectory: true) }
    public static var heartbeat: URL { root.appendingPathComponent("heartbeat") }

    public static var bundle: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/SweepHelper/Sweep Helper.app", isDirectory: true)
    }
    public static var executable: URL { bundle.appendingPathComponent("Contents/MacOS/sweep") }
    public static var plist: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/com.sweep.helper.plist")
    }

    public static func ensureDirs() {
        for directory in [root, queue, out] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

public struct HelperRequest: Codable, Sendable {
    public let id: String
    public let argv: [String]
}

public struct HelperResponse: Codable, Sendable {
    public let id: String
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

// MARK: - Agent side

public enum ExecutablePath {
    /// `CommandLine.arguments[0]` is just "sweep" when the binary is found on
    /// PATH, which broke a relative copy. Resolve it to a real absolute path.
    public static func resolve() -> URL {
        if let bundled = Bundle.main.executableURL, bundled.path.contains(".app/") {
            return bundled
        }
        let argv0 = CommandLine.arguments.first ?? ""
        if argv0.hasPrefix("/") {
            return URL(fileURLWithPath: argv0).resolvingSymlinksInPath()
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(argv0.isEmpty ? "sweep" : argv0)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
            }
        }
        return URL(fileURLWithPath: "/usr/local/bin/sweep")
    }
}

public enum HelperServer {
    public static func run() -> Never {
        HelperPaths.ensureDirs()
        // Same daemon, two jobs: the FDA queue and the read-only status endpoint
        // the Web UI plugin polls.
        StatusServer.shared.start()
        startHeartbeat()
        let fm = FileManager.default
        FileHandle.standardError.write(Data("sweep helper: watching \(HelperPaths.queue.path)\n".utf8))

        while true {
            if let names = try? fm.contentsOfDirectory(atPath: HelperPaths.queue.path) {
                for name in names.sorted() where name.hasSuffix(".json") {
                    let url = HelperPaths.queue.appendingPathComponent(name)
                    execute(url)
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    /// A scan blocks this loop for a minute; without an independent beat the
    /// client would call the helper unavailable mid-scan and fall back to a
    /// process that has no Full Disk Access.
    private static func startHeartbeat() {
        Thread.detachNewThread {
            while true {
                _ = FileManager.default.createFile(
                    atPath: HelperPaths.heartbeat.path,
                    contents: Date().description.data(using: .utf8)
                )
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    private static func execute(_ url: URL) {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let request = try? JSONDecoder().decode(HelperRequest.self, from: data)
        else { return }

        let process = Process()
        process.executableURL = ExecutablePath.resolve()
        process.arguments = request.argv

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        var status: Int32 = -1
        var stdout = "", stderr = ""
        do {
            try process.run()
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            status = process.terminationStatus
            stdout = String(data: outData, encoding: .utf8) ?? ""
            stderr = String(data: errData, encoding: .utf8) ?? ""
        } catch {
            stderr = error.localizedDescription
        }

        let response = HelperResponse(id: request.id, status: status, stdout: stdout, stderr: stderr)
        HelperPaths.ensureDirs()
        let destination = HelperPaths.out.appendingPathComponent("\(request.id).json")
        if let encoded = try? JSONEncoder().encode(response) {
            try? encoded.write(to: destination)
        }
    }
}

// MARK: - Client side

public enum HelperClient {
    public static func isAvailable() -> Bool {
        if let values = try? HelperPaths.heartbeat.resourceValues(forKeys: [.contentModificationDateKey]),
           let modified = values.contentModificationDate,
           Date().timeIntervalSince(modified) < 10 {
            return true
        }
        // Fall back to asking it directly: a cold start may not have written a
        // heartbeat yet, but the endpoint answering proves it is up.
        return HelperStatus.fetch(timeout: 1, attempts: 1) != nil
    }

    /// Sends one scan to the helper and waits for its result. Nil when the
    /// helper is not running, so callers can fall back to a plain subprocess.
    public static func scan(module: String, args: [String: Any], timeout: TimeInterval = 180) -> (String?, String?)? {
        guard isAvailable() else { return nil }
        HelperPaths.ensureDirs()

        var argv = ["scan", module, "--json"]
        if let limit = args["limit"] as? Int { argv += ["--limit", String(limit)] }
        if let roots = args["roots"] as? [String], !roots.isEmpty {
            argv += ["--roots", roots.joined(separator: ",")]
        }
        if let depth = args["depth"] as? Int { argv += ["--depth", String(depth)] }
        if let minSize = args["min_size_mb"] as? Int { argv += ["--min-size", String(minSize)] }
        if let days = args["days"] as? Int { argv += ["--days", String(days)] }

        let id = String(UUID().uuidString.prefix(12)).lowercased()
        let request = HelperRequest(id: id, argv: argv)
        let requestURL = HelperPaths.queue.appendingPathComponent("\(id).json")
        guard let data = try? JSONEncoder().encode(request),
              (try? data.write(to: requestURL)) != nil
        else { return (nil, "cannot write helper request") }

        let responseURL = HelperPaths.out.appendingPathComponent("\(id).json")
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let responseData = try? Data(contentsOf: responseURL),
               let response = try? JSONDecoder().decode(HelperResponse.self, from: responseData) {
                try? FileManager.default.removeItem(at: responseURL)
                if response.status == 0 { return (response.stdout, nil) }
                return (nil, response.stderr.isEmpty ? "helper scan failed (\(response.status))" : response.stderr)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        try? FileManager.default.removeItem(at: requestURL)
        return (nil, "helper timed out after \(Int(timeout))s")
    }
}

// MARK: - Install

public enum HelperInstaller {
    public static func install() throws {
        let fm = FileManager.default
        HelperPaths.ensureDirs()

        // Minimal app bundle: a stable CFBundleIdentifier is what makes the TCC
        // grant survive rebuilds (a bare binary's grant is tied to its cdhash).
        let contents = HelperPaths.bundle.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        let source = ExecutablePath.resolve()
        let installed = FileManager.default.fileExists(atPath: HelperPaths.executable.path)
        let force = CommandLine.arguments.contains("--force")
        // Replacing the binary changes the ad-hoc signature, which silently
        // revokes the Full Disk Access grant. Keep the installed copy unless the
        // caller explicitly asks for an upgrade.
        let sameBytes = (try? Data(contentsOf: source)) == (try? Data(contentsOf: HelperPaths.executable))
        if !sameBytes && (!installed || force) {
            try? fm.removeItem(at: HelperPaths.executable)
            let copy = Process()
            copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            copy.arguments = [source.path, HelperPaths.executable.path]
            try copy.run()
            copy.waitUntilExit()
        }

        let info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key><string>com.sweep.helper</string>
            <key>CFBundleName</key><string>Sweep Helper</string>
            <key>CFBundleExecutable</key><string>sweep</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleShortVersionString</key><string>0.3.0</string>
            <key>LSUIElement</key><true/>
        </dict>
        </plist>
        """
        try info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        // Without a bundle signature the app presents the bare binary's identity
        // ("sweep", Info.plist unbound), so a Full Disk Access grant recorded
        // against the .app never matches the process launchd starts.
        _ = shell("/usr/bin/codesign", [
            "--force", "--sign", "-",
            "--identifier", "com.sweep.helper",
            HelperPaths.bundle.path,
        ])

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.sweep.helper</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(HelperPaths.executable.path)</string>
                <string>serve</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardErrorPath</key><string>\(HelperPaths.root.appendingPathComponent("helper.log").path)</string>
        </dict>
        </plist>
        """
        try fm.createDirectory(
            at: HelperPaths.plist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try plist.write(to: HelperPaths.plist, atomically: true, encoding: .utf8)

        let uid = getuid()
        _ = shell("/bin/launchctl", ["bootout", "gui/\(uid)/com.sweep.helper"])
        // bootout leaves the domain in a transient state; bootstrapping straight
        // away intermittently returns EIO (5), so retry rather than give up.
        Thread.sleep(forTimeInterval: 0.8)
        var result = shell("/bin/launchctl", ["bootstrap", "gui/\(uid)", HelperPaths.plist.path])
        if result != 0 {
            Thread.sleep(forTimeInterval: 1.2)
            result = shell("/bin/launchctl", ["bootstrap", "gui/\(uid)", HelperPaths.plist.path])
        }
        if result != 0, !isLoaded() {
            throw NSError(domain: "sweep.helper", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed (\(result))"])
        }
    }

    public static func isLoaded() -> Bool {
        let uid = getuid()
        return shell("/bin/launchctl", ["print", "gui/\(uid)/com.sweep.helper"]) == 0
    }

    public static func uninstall() {
        let uid = getuid()
        _ = shell("/bin/launchctl", ["bootout", "gui/\(uid)/com.sweep.helper"])
        try? FileManager.default.removeItem(at: HelperPaths.plist)
        try? FileManager.default.removeItem(at: HelperPaths.bundle.deletingLastPathComponent())
    }

    @discardableResult
    static func shell(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

// MARK: - Status query

/// The helper holds the Full Disk Access grant, so the client must ask the
/// helper about permissions instead of probing its own process.
public enum HelperStatus {
    /// The helper answers on its own queue, but it can be busy finishing a scan
    /// right when a chart is requested; a single short timeout then looks like
    /// "no Full Disk Access". Retry once with a longer window instead.
    public static func fetch(timeout: TimeInterval = 4, attempts: Int = 2) -> [String: Any]? {
        for attempt in 1...max(attempts, 1) {
            if let payload = fetchOnce(timeout: timeout) { return payload }
            if attempt < attempts { Thread.sleep(forTimeInterval: 0.4) }
        }
        return nil
    }

    private static func fetchOnce(timeout: TimeInterval) -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(StatusServer.defaultPort)/status") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var payload: [String: Any]?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                payload = object
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return payload
    }

    public static func fullDiskAccess() -> Bool? {
        fetch()?["fullDiskAccess"] as? Bool
    }
}

// MARK: - Diagnostics

public enum FullDiskAccess {
    /// Paths macOS guards behind Full Disk Access. Reading any of them proves
    /// the current process has the grant.
    public static let probes = [
        "~/Library/Mail", "~/Library/Safari", "~/Library/Messages",
    ]

    public static func status() -> [(path: String, readable: Bool)] {
        probes.map { raw in
            let path = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                return (raw, false)
            }
            let readable = (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
            return (raw, readable)
        }
    }

    public static func hasAccess() -> Bool {
        status().contains { $0.readable }
    }
}
