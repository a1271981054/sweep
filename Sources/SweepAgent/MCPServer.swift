import Foundation
import MacCleanKit

/// MCP server over stdio (newline-delimited JSON-RPC 2.0).
///
/// Six read-only scan tools plus a two-step clean path: `plan_clean` returns a
/// digest, `apply_clean` only acts when handed that exact digest, and
/// `restore_clean` puts everything back from the Trash.
/// Runs a scan in a child process so a slow module (system junk takes 20–60 s)
/// never blocks the MCP loop or trips the client's request timeout.
actor JobStore {
    struct Job: Sendable {
        let id: String
        let module: String
        let startedAt: Date
        var state: String        // running | done | failed
        var result: String?
        var error: String?
    }

    private var jobs: [String: Job] = [:]

    func begin(module: String) -> String {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        jobs[id] = Job(id: id, module: module, startedAt: Date(), state: "running", result: nil, error: nil)
        return id
    }

    func finish(_ id: String, result: String?) {
        jobs[id]?.state = "done"
        jobs[id]?.result = result
    }

    func fail(_ id: String, error: String) {
        jobs[id]?.state = "failed"
        jobs[id]?.error = error
    }

    func get(_ id: String) -> Job? { jobs[id] }
}

public struct MCPServer {
    let jobs = JobStore()

    static let protocolVersion = "2024-11-05"
    static let serverVersion = "0.2.0"

    public init() {}

    public func run() async {
        var buffer = Data()

        while true {
            guard let line = nextLine(&buffer) else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = message["method"] as? String
            else { continue }

            let id = message["id"]
            let params = message["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                respond(id: id, result: [
                    "protocolVersion": Self.protocolVersion,
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": ["name": "sweep", "version": Self.serverVersion],
                ])
            case "notifications/initialized", "notifications/cancelled":
                continue
            case "ping":
                respond(id: id, result: [:])
            case "tools/list":
                respond(id: id, result: ["tools": Self.tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                await handleTool(name: name, arguments: args, id: id)
            default:
                respond(id: id, error: [-32601, "Method not found: \(method)"])
            }
        }
    }

    // MARK: - Tool catalog

    static let scanLimit: [String: Any] = [
        "type": "integer", "minimum": 1, "maximum": 100,
        "description": "How many largest candidates to return per group (default 5). The full list is stored in the snapshot.",
    ]

    static let tools: [[String: Any]] = [
        [
            "name": "disk_report",
            "description": "Report total, used and available space on the data volume. Read-only.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false],
        ],
        [
            "name": "scan_large_files",
            "description": "Find the largest user files under the given roots. Read-only. These are the user's own documents: never clean them without explicit per-file approval.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "roots": ["type": "array", "items": ["type": "string"]],
                    "min_size_mb": ["type": "integer", "minimum": 1, "description": "Default 200."],
                    "limit": scanLimit,
                ],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "scan_old_files",
            "description": "Find user files not modified for N days. Read-only. Old does not mean unneeded.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "roots": ["type": "array", "items": ["type": "string"]],
                    "days": ["type": "integer", "minimum": 1, "description": "Default 365."],
                    "limit": scanLimit,
                ],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "scan_duplicates",
            "description": "Find byte-identical duplicate files (size, partial hash, full SHA-256, hard-link aware). Read-only. Returns only the redundant copies, keeping one original per group.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "roots": ["type": "array", "items": ["type": "string"]],
                    "min_size_mb": ["type": "integer", "minimum": 1, "description": "Default 200."],
                    "limit": scanLimit,
                ],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "render_chart",
            "description": "Render a snapshot as a PNG bar chart, grouped by category, and return it as an image so the user sees the picture instead of a wall of text. Omit snapshot to chart the newest one.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "snapshot": ["type": "string", "description": "snapshotPath from a scan; defaults to the newest."],
                    "plan": ["type": "string", "description": "Plan id from plan_clean: renders that plan instead, for the confirmation step."],
                    "op": ["type": "string", "description": "Operation id from apply_clean: renders the result with its undo id."],
                    "view": ["type": "string", "enum": ["scan", "entries", "disk", "status", "ops"], "description": "disk: gauge; status: mode and permissions; ops: cleanup history; entries: file list; scan: category summary (default)."],
                    "top": ["type": "integer", "minimum": 1, "maximum": 20, "description": "Categories to show (default 8)."],
                ],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "plan_clean",
            "description": "Build a clean plan from a scan snapshot and the ids the user approved. Deletes nothing. Returns a plan id, the exact byte total and a digest; show them to the user before calling apply_clean.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "snapshot": ["type": "string", "description": "snapshotPath from a scan_* result."],
                    "ids": ["type": "array", "items": ["type": "string"], "description": "Candidate ids from that snapshot."],
                ],
                "required": ["snapshot", "ids"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "apply_clean",
            "description": "Move the planned items to the Trash. Requires the digest returned by plan_clean (unless mode is auto, where only whitelisted cache categories are allowed). Protected paths and files whose size changed since planning are refused item by item. Reversible with restore_clean.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "plan_id": ["type": "string"],
                    "digest": ["type": "string", "description": "The digest from plan_clean, after the user approved the plan."],
                ],
                "required": ["plan_id"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "restore_clean",
            "description": "Put every item from one apply_clean operation back where it came from, as long as the Trash still holds it.",
            "inputSchema": [
                "type": "object",
                "properties": ["operation_id": ["type": "string", "description": "id from apply_clean or list_operations."]],
                "required": ["operation_id"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "trash_report",
            "description": "Inspect items currently in the macOS Trash (~/.Trash), returning count, total bytes, top items, and a digest for confirmation. Read-only.",
            "inputSchema": [
                "type": "object",
                "properties": ["limit": scanLimit],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "empty_trash",
            "description": "Permanently empty ~/.Trash. This is IRREVERSIBLE and cannot be undone with restore_clean. Requires the digest from trash_report after explicit user approval; disabled in readonly mode.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "digest": ["type": "string", "description": "The digest returned by trash_report, confirming the exact Trash contents approved by the user."],
                ],
                "required": ["digest"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "list_operations",
            "description": "List recent clean operations with ids, counts and bytes. Read-only.",
            "inputSchema": [
                "type": "object",
                "properties": ["limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Default 5."]],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "cleanup_mode",
            "description": "Read the autonomy mode, or change it. readonly blocks apply_clean; confirm (default) requires the plan digest; auto allows unattended cleaning of whitelisted cache categories only.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "mode": ["type": "string", "enum": ["readonly", "confirm", "auto"], "description": "Omit to only read the current mode."],
                ],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "scan_start",
            "description": "Start a scan as a background job and return a job id immediately. Use this for system junk and project junk, which take 20–60 s and would otherwise time out. Poll scan_status for the result. Read-only.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "module": ["type": "string", "enum": ["system-junk", "project-junk", "large-files", "old-files", "duplicates"]],
                    "limit": scanLimit,
                    "roots": ["type": "array", "items": ["type": "string"], "description": "Absolute or ~ paths."],
                    "depth": ["type": "integer", "minimum": 1, "maximum": 10],
                    "min_size_mb": ["type": "integer", "minimum": 1],
                    "days": ["type": "integer", "minimum": 1],
                ],
                "required": ["module"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "scan_status",
            "description": "Check a scan job. Returns state running, done or failed; when done, the same payload a scan tool returns, including snapshotPath for plan_clean.",
            "inputSchema": [
                "type": "object",
                "properties": ["job_id": ["type": "string"]],
                "required": ["job_id"],
                "additionalProperties": false,
            ],
        ],
    ]

    // MARK: - Dispatch

    func handleTool(name: String, arguments args: [String: Any], id: Any?) async {
        let limit = min(max(args["limit"] as? Int ?? 5, 1), 100)
        let roots = (args["roots"] as? [String]) ?? []

        switch name {
        case "disk_report":
            respond(id: id, result: textResult(diskPayload()))

        case "scan_system_junk":
            let (groups, denied, perCategory) = await SystemJunkScanner().scan(limit: limit)
            let entries = perCategory.flatMap { pair in
                flatEntries(pair.1, category: pair.0.rawValue)
            }
            var payload = reportPayload(module: "system-junk", groups: groups, denied: denied, warnings: [])
            payload["snapshotPath"] = SnapshotStore.write(module: "system-junk", entries: entries) ?? NSNull()
            respond(id: id, result: textResult(payload))

        case "scan_project_junk":
            let depth = min(max(args["depth"] as? Int ?? 6, 1), 10)
            let (groups, items, nodes) = await ProjectJunkScanner().scan(
                roots: resolve(roots, fallback: DefaultRoots.projects),
                maxDepth: depth,
                limit: limit
            )
            let entries = items.map {
                ScanEntry(id: Util.stableID($0.path), path: $0.path, bytes: $0.bytes,
                          modified: Util.iso($0.projectModified), kind: $0.kind.rawValue,
                          category: ScanCategory.projectJunk.rawValue)
            }
            var payload = reportPayload(module: "project-junk", groups: groups, denied: [],
                                        warnings: ["walked \(nodes) directory nodes"])
            payload["snapshotPath"] = SnapshotStore.write(module: "project-junk", entries: entries) ?? NSNull()
            respond(id: id, result: textResult(payload))

        case "scan_large_files":
            let minSize = UInt64(max(args["min_size_mb"] as? Int ?? 200, 1)) * 1024 * 1024
            let (group, denied, items) = await UserFilesScanner().largeFiles(
                roots: resolve(roots, fallback: ["~/Downloads", "~/Documents", "~/Desktop"]),
                minSize: minSize, limit: limit
            )
            let entries = flatEntries(items, category: "large_files")
            var payload = reportPayload(module: "large-files", groups: group.map { [$0] } ?? [], denied: denied, warnings: [])
            payload["snapshotPath"] = SnapshotStore.write(module: "large-files", entries: entries) ?? NSNull()
            respond(id: id, result: textResult(payload))

        case "scan_old_files":
            let days = Double(max(args["days"] as? Int ?? 365, 1))
            let (group, denied, items) = await UserFilesScanner().oldFiles(
                roots: resolve(roots, fallback: DefaultRoots.documents),
                olderThanDays: days, limit: limit
            )
            let entries = flatEntries(items, category: "old_files")
            var payload = reportPayload(module: "old-files", groups: group.map { [$0] } ?? [], denied: denied, warnings: [])
            payload["snapshotPath"] = SnapshotStore.write(module: "old-files", entries: entries) ?? NSNull()
            respond(id: id, result: textResult(payload))

        case "scan_duplicates":
            let minSize = UInt64(max(args["min_size_mb"] as? Int ?? 200, 1)) * 1024 * 1024
            let (groups, denied, deletable, hashed) = await DuplicateScanner().scan(
                roots: resolve(roots, fallback: DefaultRoots.documents),
                minSize: minSize, limit: limit
            )
            let entries = flatEntries(deletable, category: "duplicates")
            var payload = reportPayload(module: "duplicates", groups: groups, denied: denied,
                                        warnings: ["partial-hashed \(hashed) files"])
            payload["snapshotPath"] = SnapshotStore.write(module: "duplicates", entries: entries) ?? NSNull()
            respond(id: id, result: textResult(payload))

        case "scan_start":
            guard let module = args["module"] as? String else {
                toolError(id: id, "module is required"); return
            }
            let jobId = await jobs.begin(module: module)
            let jobArgs = args
            Task {
                let (result, failure) = launchScan(module: module, args: jobArgs)
                if let failure {
                    await jobs.fail(jobId, error: failure)
                } else {
                    await jobs.finish(jobId, result: result)
                }
            }
            respond(id: id, result: textResult([
                "jobId": jobId,
                "module": module,
                "hint": "Poll scan_status with this job_id; a full system-junk scan takes 20–60 s.",
            ]))

        case "scan_status":
            guard let jobId = args["job_id"] as? String else {
                toolError(id: id, "job_id is required"); return
            }
            guard let job = await jobs.get(jobId) else {
                toolError(id: id, "unknown job: \(jobId)"); return
            }
            switch job.state {
            case "failed":
                respond(id: id, result: textResult([
                    "state": "failed", "module": job.module, "error": job.error ?? "unknown",
                ]))
            case "done":
                var payload: [String: Any] = ["state": "done", "module": job.module]
                if let text = job.result, let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) {
                    payload["result"] = object
                }
                respond(id: id, result: textResult(payload))
            default:
                respond(id: id, result: textResult([
                    "state": "running",
                    "module": job.module,
                    "elapsedSeconds": Int(Date().timeIntervalSince(job.startedAt)),
                ]))
            }

        case "render_chart":
            let top = min(max(args["top"] as? Int ?? 8, 1), 20)

            if let view = args["view"] as? String, view != "scan", view != "entries" {
                let output = AgentPaths.root
                    .appendingPathComponent("charts", isDirectory: true)
                    .appendingPathComponent("\(view).png")
                try? FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                do {
                    switch view {
                    case "disk":
                        let url = URL(fileURLWithPath: "/System/Volumes/Data")
                        let values = try? url.resourceValues(forKeys: [
                            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                        ])
                        try ChartRenderer.renderDisk(
                            total: UInt64(values?.volumeTotalCapacity ?? 0),
                            available: UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0),
                            output: output
                        )
                    case "status":
                        try ChartRenderer.renderStatus(
                            mode: AgentConfigStore.load().mode,
                            fullDiskAccess: HelperStatus.fullDiskAccess() ?? FullDiskAccess.hasAccess(),
                            helperRunning: HelperClient.isAvailable(),
                            output: output
                        )
                    case "ops":
                        try ChartRenderer.renderOperations(OperationLog.all(), output: output)
                    default:
                        toolError(id: id, "unknown view: \(view)"); return
                    }
                    guard let data = try? Data(contentsOf: output) else {
                        toolError(id: id, "chart written but unreadable"); return
                    }
                    respond(id: id, result: [
                        "content": [
                            ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"],
                            ["type": "text", "text": "view \(view) · \(output.path)"],
                        ],
                    ])
                } catch {
                    toolError(id: id, error.localizedDescription)
                }
                return
            }

            if let opId = args["op"] as? String {
                let output = AgentPaths.root
                    .appendingPathComponent("charts", isDirectory: true)
                    .appendingPathComponent("op-\(opId).png")
                try? FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                do {
                    let record = try OperationLog.find(opId)
                    try ChartRenderer.renderOperation(record, output: output)
                    guard let data = try? Data(contentsOf: output) else {
                        toolError(id: id, "operation chart written but unreadable"); return
                    }
                    respond(id: id, result: [
                        "content": [
                            ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"],
                            ["type": "text", "text": "operation \(opId) · \(record.okCount) moved · \(Util.bytes(record.bytes)) · undo with restore_clean"],
                        ],
                    ])
                } catch {
                    toolError(id: id, error.localizedDescription)
                }
                return
            }

            if let planId = args["plan"] as? String {
                let output = AgentPaths.root
                    .appendingPathComponent("charts", isDirectory: true)
                    .appendingPathComponent("plan-\(planId).png")
                try? FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                do {
                    let plan = try PlanStore.load(id: planId)
                    try ChartRenderer.renderPlan(plan, output: output)
                    guard let data = try? Data(contentsOf: output) else {
                        toolError(id: id, "plan chart written but unreadable"); return
                    }
                    respond(id: id, result: [
                        "content": [
                            ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"],
                            ["type": "text", "text": "plan \(planId) · \(plan.entries.count) items · \(Util.bytes(plan.totalBytes)) · digest \(plan.digest)"],
                        ],
                    ])
                } catch {
                    toolError(id: id, error.localizedDescription)
                }
                return
            }
            let snapshot: URL
            if let raw = args["snapshot"] as? String {
                snapshot = Util.expand(raw)
            } else {
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: AgentPaths.snapshots,
                    includingPropertiesForKeys: [.contentModificationDateKey]
                )) ?? []
                guard let newest = files.sorted(by: {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return a > b
                }).first else {
                    toolError(id: id, "no snapshot yet: run a scan first"); return
                }
                snapshot = newest
            }

            let output = AgentPaths.root
                .appendingPathComponent("charts", isDirectory: true)
                .appendingPathComponent("chart-\(Int(Date().timeIntervalSince1970)).png")
            try? FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            do {
                let name = snapshot.lastPathComponent
                let fileOriented = name.hasPrefix("large-files")
                    || name.hasPrefix("old-files")
                    || name.hasPrefix("duplicates")
                let wantEntries = args["view"] as? String == "entries" || fileOriented

                if wantEntries {
                    let title: String = name.hasPrefix("large-files") ? "大文件"
                        : name.hasPrefix("old-files") ? "旧文件"
                        : name.hasPrefix("duplicates") ? "重复文件" : "扫描结果"
                    try ChartRenderer.renderEntries(
                        snapshot: snapshot, title: title, output: output,
                        maxRows: max(top, 10)
                    )
                } else {
                    try ChartRenderer.render(snapshot: snapshot, output: output, top: top)
                }
                guard let data = try? Data(contentsOf: output) else {
                    toolError(id: id, "chart written but unreadable"); return
                }
                respond(id: id, result: [
                    "content": [
                        ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"],
                        ["type": "text", "text": "chart: \(output.path)"],
                    ],
                ])
            } catch {
                toolError(id: id, error.localizedDescription)
            }

        case "plan_clean":
            guard let snapshot = args["snapshot"] as? String else {
                toolError(id: id, "snapshot is required"); return
            }
            guard let ids = args["ids"] as? [String], !ids.isEmpty else {
                toolError(id: id, "ids must contain at least one candidate id"); return
            }
            let url = URL(fileURLWithPath: (snapshot as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url),
                  let entries = try? JSONDecoder().decode([ScanEntry].self, from: data)
            else { toolError(id: id, "cannot read snapshot: \(snapshot)"); return }

            do {
                let plan = try PlanStore.create(from: entries, ids: ids)
                respond(id: id, result: textResult([
                    "planId": plan.id,
                    "digest": plan.digest,
                    "count": plan.entries.count,
                    "totalBytes": plan.totalBytes,
                    "entries": plan.entries.prefix(50).map {
                        ["id": $0.id, "path": $0.path, "bytes": $0.bytes, "category": $0.category ?? "unknown"]
                    },
                    "next": "Show this plan to the user. Call apply_clean with plan_id and digest only after they approve.",
                ]))
            } catch {
                toolError(id: id, error.localizedDescription)
            }

        case "apply_clean":
            guard let planId = args["plan_id"] as? String else {
                toolError(id: id, "plan_id is required"); return
            }
            do {
                let record = try Cleaner.apply(planId: planId, digest: args["digest"] as? String)
                respond(id: id, result: textResult([
                    "operationId": record.id,
                    "mode": record.mode,
                    "movedCount": record.okCount,
                    "failedCount": record.failCount,
                    "bytes": record.bytes,
                    "failures": record.items.filter { !$0.ok }.map {
                        ["path": $0.path, "error": $0.error ?? "unknown"]
                    },
                    "undo": "restore_clean with operation_id \(record.id)",
                ]))
            } catch {
                toolError(id: id, error.localizedDescription)
            }

        case "restore_clean":
            guard let operationId = args["operation_id"] as? String else {
                toolError(id: id, "operation_id is required"); return
            }
            do {
                let result = try Cleaner.restore(operationId: operationId)
                respond(id: id, result: textResult([
                    "restored": result.restored,
                    "failed": result.failed,
                ]))
            } catch {
                toolError(id: id, error.localizedDescription)
            }

        case "trash_report":
            let summary = TrashService.inspect(limit: limit)
            var payload = summary.asDictionary()
            if summary.denied {
                payload["hint"] = CleanError.trashAccessDenied.localizedDescription
            }
            respond(id: id, result: textResult(payload))

        case "empty_trash":
            guard let digest = args["digest"] as? String, !digest.isEmpty else {
                toolError(id: id, "digest from trash_report is required"); return
            }
            do {
                let result = try TrashService.empty(expectedDigest: digest)
                respond(id: id, result: textResult(result.asDictionary()))
            } catch {
                toolError(id: id, error.localizedDescription)
            }

        case "list_operations":
            let records = OperationLog.all().suffix(max(1, args["limit"] as? Int ?? 5))
            respond(id: id, result: textResult([
                "operations": records.map { record -> [String: Any] in
                    [
                        "id": record.id,
                        "createdAt": record.createdAt,
                        "mode": record.mode,
                        "movedCount": record.okCount,
                        "failedCount": record.failCount,
                        "bytes": record.bytes,
                    ]
                },
            ]))

        case "cleanup_mode":
            if let mode = args["mode"] as? String {
                do { try AgentConfigStore.setMode(mode) }
                catch { toolError(id: id, error.localizedDescription); return }
            }
            let config = AgentConfigStore.load()
            respond(id: id, result: textResult([
                "mode": config.mode,
                "maxBytes": config.maxBytes,
                "maxItems": config.maxItems,
            ]))

        default:
            respond(id: id, error: [-32602, "Unknown tool: \(name)"])
        }
    }

    /// Reuses the CLI for scanning: same code path, separate process, no
    /// blocking of the MCP loop, and the job survives a slow filesystem.
    func launchScan(module: String, args: [String: Any]) -> (result: String?, error: String?) {
        // Prefer the FDA helper: one grant covers every client. Falls back to a
        // plain subprocess when the helper is not running.
        if let viaHelper = HelperClient.scan(module: module, args: args) {
            return viaHelper
        }
        var cliArgs = ["scan", module, "--json"]
        if let limit = args["limit"] as? Int { cliArgs += ["--limit", String(limit)] }
        if let roots = args["roots"] as? [String], !roots.isEmpty {
            cliArgs += ["--roots", roots.joined(separator: ",")]
        }
        if let depth = args["depth"] as? Int { cliArgs += ["--depth", String(depth)] }
        if let minSize = args["min_size_mb"] as? Int { cliArgs += ["--min-size", String(minSize)] }
        if let days = args["days"] as? Int { cliArgs += ["--days", String(days)] }

        let executable = ExecutablePath.resolve().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = cliArgs

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return (nil, error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return (nil, "scan failed (exit \(process.terminationStatus))")
        }
        return (String(data: data, encoding: .utf8), nil)
    }

    // MARK: - Payloads

    func resolve(_ raw: [String], fallback: [String]) -> [URL] {
        (raw.isEmpty ? fallback : raw).map { Util.expand($0) }
    }

    func flatEntries(_ items: [FileItem], category: String) -> [ScanEntry] {
        items
            .filter { !$0.isDirectory || $0.isPackage }
            .map {
                ScanEntry(
                    id: Util.stableID($0.url.path(percentEncoded: false)),
                    path: $0.url.path(percentEncoded: false),
                    bytes: $0.size,
                    modified: Util.iso($0.modificationDate),
                    category: category
                )
            }
    }

    func diskPayload() -> [String: Any] {
        let url = URL(fileURLWithPath: "/System/Volumes/Data")
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = UInt64(values?.volumeTotalCapacity ?? 0)
        let available = UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        return [
            "totalBytes": total,
            "availableBytes": available,
            "usedBytes": total > available ? total - available : 0,
        ]
    }

    func reportPayload(module: String, groups: [ScanGroup], denied: [URL], warnings: [String]) -> [String: Any] {
        var payload: [String: Any] = [
            "module": module,
            "generatedAt": Util.nowISO(),
            "totalBytes": groups.reduce(0) { $0 &+ $1.bytes },
            "totalItems": groups.reduce(0) { $0 &+ $1.items },
            "groups": groups.map { group -> [String: Any] in
                [
                    "category": group.category,
                    "label": group.label,
                    "items": group.items,
                    "bytes": group.bytes,
                    "top": group.top.map { entry -> [String: Any] in
                        var row: [String: Any] = ["id": entry.id, "path": entry.path, "bytes": entry.bytes]
                        if let modified = entry.modified { row["modified"] = modified }
                        if let kind = entry.kind { row["kind"] = kind }
                        return row
                    },
                ]
            },
            "deniedPaths": denied.map { $0.path(percentEncoded: false) },
            "warnings": warnings,
        ]
        if !denied.isEmpty {
            payload["hint"] = "Some roots were unreadable (missing Full Disk Access): results are incomplete."
        }
        return payload
    }

    func textResult(_ object: [String: Any]) -> [String: Any] {
        ["content": [["type": "text", "text": Self.encode(object)]]]
    }

    func toolError(id: Any?, _ message: String) {
        guard let id else { return }
        send([
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [["type": "text", "text": message]],
                "isError": true,
            ],
        ])
    }

    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{\"error\":\"encode failed\"}" }
        return text
    }

    // MARK: - Transport

    func respond(id: Any?, result: [String: Any]) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func respond(id: Any?, error: [Any]) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "error": ["code": error[0], "message": error[1]]])
    }

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              var text = String(data: data, encoding: .utf8) else { return }
        text.append("\n")
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    func nextLine(_ buffer: inout Data) -> String? {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                return String(data: line, encoding: .utf8)
            }
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}
