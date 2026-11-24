import Foundation
import MacCleanKit

public enum CLIRunner {
    public static func run(_ argv: [String]) async {
        var args = Array(argv.dropFirst())
        guard let command = args.first else { usage(); return }
        args.removeFirst()

        switch command {
        case "scan":
            guard let module = args.first else { usage(); return }
            args.removeFirst()
            await scan(module: module, options: Options(args))
        case "disk":
            await disk(options: Options(args))
        case "mcp":
            await MCPServer().run()
        case "plan":
            planCommand(Options(args))
        case "apply":
            applyCommand(Options(args))
        case "restore":
            restoreCommand(Options(args))
        case "ops":
            opsCommand(Options(args))
        case "mode":
            modeCommand(args)
        case "mcp-config":
            mcpConfig(args.first ?? "generic")
        case "serve":
            HelperServer.run()
        case "helper-install":
            helperInstallCommand()
        case "helper-uninstall":
            HelperInstaller.uninstall()
            print("helper 已卸载（LaunchAgent 与 app 均已移除）")
        case "fda":
            fdaCommand()
        case "chart":
            chartCommand(Options(args))
        case "ui":
            uiCommand()
        case "version", "--version":
            print("sweep 0.3.0 · scan engine MacCleanKit (BSD-3, see NOTICE)")
        case "help", "--help", "-h":
            usage()
        default:
            FileHandle.standardError.write(Data("unknown command: \(command)\n\n".utf8))
            usage()
        }
    }

    // MARK: - Commands

    static func disk(options: Options) async {
        let url = URL(fileURLWithPath: "/System/Volumes/Data")
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey,
        ])
        let total = UInt64(values?.volumeTotalCapacity ?? 0)
        let available = UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        let used = total > available ? total - available : 0

        if options.json {
            let payload: [String: Any] = [
                "volume": values?.volumeName ?? "Data",
                "totalBytes": total,
                "availableBytes": available,
                "usedBytes": used,
                "usedPercent": total == 0 ? 0 : Int((Double(used) / Double(total)) * 100),
            ]
            printJSON(payload)
            return
        }

        print("磁盘 \(values?.volumeName ?? "Data")")
        print("  总容量   \(Util.bytes(total))")
        print("  已使用   \(Util.bytes(used))  (\(total == 0 ? 0 : Int(Double(used) / Double(total) * 100))%)")
        print("  可用     \(Util.bytes(available))")
    }

    static func scan(module: String, options: Options) async {
        let started = Date()
        var groups: [ScanGroup] = []
        var denied: [URL] = []
        var warnings: [String] = []
        var allEntries: [ScanEntry] = []

        switch module {
        case "system-junk", "junk":
            let (g, d, perCategory) = await SystemJunkScanner().scan(limit: options.limit)
            groups = g; denied = d
            allEntries = perCategory.flatMap { pair in
                makeEntries(pair.1, limit: 100_000, category: pair.0.rawValue)
            }

        case "project-junk", "projects":
            let (g, items, nodes) = await ProjectJunkScanner().scan(
                roots: resolve(options.roots, default: DefaultRoots.projects),
                maxDepth: options.depth,
                limit: options.limit
            )
            groups = g
            allEntries = items.map {
                ScanEntry(
                    id: Util.stableID($0.path),
                    path: $0.path,
                    bytes: $0.bytes,
                    modified: Util.iso($0.projectModified),
                    kind: $0.kind.rawValue,
                    category: ScanCategory.projectJunk.rawValue
                )
            }
            warnings.append("遍历了 \(nodes) 个项目目录节点")

        case "large-files", "large":
            let (g, d, items) = await UserFilesScanner().largeFiles(
                roots: resolve(options.roots, default: DefaultRoots.userFiles),
                minSize: options.minSizeMB * 1024 * 1024,
                limit: options.limit
            )
            if let g { groups = [g] }
            denied = d
            allEntries = makeEntries(items, limit: 20_000, category: "large_files")

        case "old-files", "old":
            let (g, d, items) = await UserFilesScanner().oldFiles(
                roots: resolve(options.roots, default: DefaultRoots.documents),
                olderThanDays: options.days,
                limit: options.limit
            )
            if let g { groups = [g] }
            denied = d
            allEntries = makeEntries(items, limit: 20_000, category: "old_files")

        case "installers":
            let result = await InstallersScanner().scan(
                roots: resolve(options.roots, default: ["~/Downloads", "~/Desktop"]),
                olderThanDays: options.days,
                limit: options.limit
            )
            groups = result.groups
            denied = result.deniedPaths
            allEntries = result.entries

        case "duplicates", "dup":
            let (g, d, deletable, hashed) = await DuplicateScanner().scan(
                roots: resolve(options.roots, default: DefaultRoots.documents),
                minSize: options.minSizeMB * 1024 * 1024,
                limit: options.limit
            )
            groups = g
            denied = d
            allEntries = makeEntries(deletable, limit: 20_000, category: "duplicates")
            warnings.append("对 \(hashed) 个文件做了部分哈希")

        case "smart":
            let (g, d, perCategory) = await SystemJunkScanner().scan(limit: options.limit)
            let (pg, pitems, _) = await ProjectJunkScanner().scan(
                roots: resolve([], default: DefaultRoots.projects),
                maxDepth: options.depth,
                limit: options.limit
            )
            groups = g + pg
            denied = d
            allEntries = perCategory.flatMap { pair in
                makeEntries(pair.1, limit: 40_000, category: pair.0.rawValue)
            } + pitems.map {
                ScanEntry(
                    id: Util.stableID($0.path),
                    path: $0.path,
                    bytes: $0.bytes,
                    modified: Util.iso($0.projectModified),
                    kind: $0.kind.rawValue,
                    category: ScanCategory.projectJunk.rawValue
                )
            }

        default:
            FileHandle.standardError.write(Data("unknown module: \(module)\n".utf8))
            return
        }

        if !denied.isEmpty {
            warnings.append("\(denied.count) 个目录因缺少「完全磁盘访问权限」读取失败，结果可能偏小")
        }

        let totalBytes = groups.reduce(0) { $0 &+ $1.bytes }
        let totalItems = groups.reduce(0) { $0 &+ $1.items }
        let snapshot = options.save ? writeSnapshot(module: module, entries: allEntries) : nil

        let report = ScanReport(
            module: module,
            generatedAt: Util.nowISO(),
            totalItems: totalItems,
            totalBytes: totalBytes,
            groups: groups,
            deniedPaths: denied.map { $0.path(percentEncoded: false) },
            warnings: warnings,
            scanSeconds: (Date().timeIntervalSince(started) * 10).rounded() / 10,
            snapshotPath: snapshot
        )

        if options.json {
            printJSON(report)
        } else {
            printHuman(report)
        }
    }

    // MARK: - Web UI

    static func uiCommand() {
        guard HelperClient.isAvailable() else {
            print("helper 未运行，先安装：sweep helper-install")
            exit(1)
        }
        let url = "http://127.0.0.1:\(StatusServer.defaultPort)/"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        try? process.run()
        print(url)
    }

    // MARK: - Chart

    static func chartCommand(_ options: Options) {
        let chartsDir = Util.expand("~/.sweep/charts")
        try? FileManager.default.createDirectory(at: chartsDir, withIntermediateDirectories: true)

        if options.diskView {
            let output = Util.expand(options.out ?? "~/.sweep/charts/disk.png")
            let url = URL(fileURLWithPath: "/System/Volumes/Data")
            let values = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ])
            do {
                try ChartRenderer.renderDisk(
                    total: UInt64(values?.volumeTotalCapacity ?? 0),
                    available: UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0),
                    output: output
                )
                print(output.path)
            } catch { fail("生成磁盘图失败：\(error.localizedDescription)") }
            return
        }

        if options.statusView {
            let output = Util.expand(options.out ?? "~/.sweep/charts/status.png")
            do {
                try ChartRenderer.renderStatus(
                    mode: AgentConfigStore.load().mode,
                    fullDiskAccess: HelperStatus.fullDiskAccess() ?? FullDiskAccess.hasAccess(),
                    helperRunning: HelperClient.isAvailable(),
                    output: output
                )
                print(output.path)
            } catch { fail("生成状态图失败：\(error.localizedDescription)") }
            return
        }

        if options.opsView {
            let output = Util.expand(options.out ?? "~/.sweep/charts/ops.png")
            do {
                try ChartRenderer.renderOperations(OperationLog.all(), output: output)
                print(output.path)
            } catch { fail("生成记录图失败：\(error.localizedDescription)") }
            return
        }

        // Operation result: what moved, and the id that undoes it.
        if let opId = options.op {
            let output = Util.expand(options.out ?? "~/.sweep/charts/op-\(opId).png")
            try? FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            do {
                let record = try OperationLog.find(opId)
                try ChartRenderer.renderOperation(record, output: output)
                print(output.path)
            } catch {
                fail("生成结果图失败：\(error.localizedDescription)")
            }
            return
        }

        // A plan is the more useful picture right before a deletion.
        if let planId = options.plan {
            let output = Util.expand(options.out ?? "~/.sweep/charts/plan-\(planId).png")
            try? FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            do {
                let plan = try PlanStore.load(id: planId)
                try ChartRenderer.renderPlan(plan, output: output)
                print(output.path)
            } catch {
                fail("生成计划图失败：\(error.localizedDescription)")
            }
            return
        }

        let snapshot: URL
        if let raw = options.snapshot {
            snapshot = Util.expand(raw)
        } else {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: AgentPaths.snapshots,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            let latest = files.sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return left > right
            }.first
            guard let latest else { fail("没有快照：先跑一次 scan") }
            snapshot = latest
        }

        let output = Util.expand(options.out ?? "~/.sweep/charts/latest.png")
        try? FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let moduleTitle: String = {
            let name = snapshot.lastPathComponent
            if name.hasPrefix("large-files") { return "大文件" }
            if name.hasPrefix("old-files") { return "旧文件" }
            if name.hasPrefix("duplicates") { return "重复文件" }
            if name.hasPrefix("project-junk") { return "项目垃圾" }
            if name.hasPrefix("system-junk") { return "系统垃圾" }
            return "扫描结果"
        }()

        // File-oriented modules read better as a list than as categories.
        let wantsList = options.listView
            || snapshot.lastPathComponent.hasPrefix("large-files")
            || snapshot.lastPathComponent.hasPrefix("old-files")
            || snapshot.lastPathComponent.hasPrefix("duplicates")

        do {
            if wantsList {
                try ChartRenderer.renderEntries(
                    snapshot: snapshot,
                    title: moduleTitle,
                    output: output,
                    maxRows: options.limit == 10 ? 14 : options.limit
                )
                print(output.path)
                return
            }
            try ChartRenderer.render(snapshot: snapshot, output: output, top: options.limit)
            print(output.path)
        } catch {
            fail("生成图表失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Helper & permission

    static func helperInstallCommand() {
        do {
            try HelperInstaller.install()
            print("✓ helper 已安装并启动: \(HelperPaths.bundle.path)")
            print("")
            print("还差一步（必须你手动授权）：")
            print("  系统设置 → 隐私与安全性 → 完全磁盘访问权限 → + →")
            print("  选择 \(HelperPaths.bundle.path)")
            print("")
            print("授权后执行 `sweep helper-install` 重启 helper 生效。")
            print("判据：扫描结果里的 deniedPaths 变为空；四个 MCP 客户端共用这一次授权。")
        } catch {
            fail(error.localizedDescription)
        }
    }

    static func fdaCommand() {
        let rows = FullDiskAccess.status()
        print("完全磁盘访问权限")
        for row in rows {
            print("  \(row.readable ? "OK  " : "DENY")  \(row.path)")
        }
        print("")
        let available = HelperClient.isAvailable()
        print("helper: \(available ? "运行中" : "未运行")  \(HelperPaths.bundle.path)")
        if !available {
            print("  → 运行 `sweep helper-install` 安装")
        }
        if !FullDiskAccess.hasAccess() {
            print("")
            print("↑ 这是**调用者进程**（终端 / DSH）的权限，不是你关心的那个。")
            print("  扫描实际由 helper 执行，判据是扫描结果里的 deniedPaths 是否为空。")
            print("  授权路径：系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 添加 Sweep Helper.app")
            print("  授权后执行 `sweep helper-install` 重启 helper 生效。")
        }
    }

    // MARK: - Client config

    static func mcpConfig(_ client: String) {
        let exe = (CommandLine.arguments.first.flatMap { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
            ?? "sweep"
        switch client {
        case "codex":
            print("""
            # ~/.codex/config.toml
            [mcp_servers.sweep]
            command = "\(exe)"
            args = ["mcp"]
            """)
        case "claude", "claude-desktop", "cursor", "zcode", "workbuddy", "json":
            print("""
            {
              "mcpServers": {
                "sweep": {
                  "command": "\(exe)",
                  "args": ["mcp"]
                }
              }
            }
            """)
        case "dsh":
            print("""
            DSH 用一个 config-only bundle 接入（示例见 dsh-bundle/）：
              package.json        声明 dsh.bundle.patch
              cordis.patch.yml    insert @deepseek-ai/dsh-mcp-client · transport: stdio
            安装：Plugins → Add plugin → 选择 dsh-bundle 目录
            命令：\(exe) mcp
            """)
        default:
            print("用法: sweep mcp-config [codex|claude|cursor|zcode|workbuddy|dsh|json]")
        }
    }

    // MARK: - Clean commands

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    static func planCommand(_ options: Options) {
        guard let snapshotPath = options.snapshot else {
            fail("plan 需要 --snapshot <scan 输出里的 snapshotPath>")
        }
        let url = URL(fileURLWithPath: (snapshotPath as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([ScanEntry].self, from: data)
        else { fail("读不到快照: \(snapshotPath)") }
        var ids = options.ids
        if ids.isEmpty {
            ids = entries.filter { entry in
                let sizeOK = options.minBytesMB.map { entry.bytes >= UInt64($0) * 1024 * 1024 } ?? true
                let categoryOK = options.categories.isEmpty
                    || options.categories.contains(entry.category ?? "")
                return sizeOK && categoryOK
            }.map(\.id)
        }
        guard !ids.isEmpty else {
            fail("没有匹配的候选：检查 --ids 或 --min-bytes / --categories")
        }

        do {
            let plan = try PlanStore.create(from: entries, ids: ids)
            if options.json {
                printJSON(plan)
                return
            }
            print("")
            print("清理计划 \(plan.id)")
            print("将移入废纸篓 \(plan.entries.count) 项 · \(Util.bytes(plan.totalBytes))")
            print(String(repeating: "─", count: 62))
            for entry in plan.entries.prefix(20) {
                print("  \(Util.bytes(entry.bytes).leftPadded(9))  \(abbreviate(entry.path))")
            }
            if plan.entries.count > 20 { print("  … 其余 \(plan.entries.count - 20) 项") }
            print("")
            print("digest: \(plan.digest)")
            print("确认后执行: sweep apply --plan \(plan.id) --digest \(plan.digest)")
            print("")
        } catch {
            fail(error.localizedDescription)
        }
    }

    static func applyCommand(_ options: Options) {
        guard let planId = options.plan else { fail("apply 需要 --plan <计划 id>") }
        do {
            let record = try Cleaner.apply(planId: planId, digest: options.digest)
            if options.json {
                printJSON(record)
                return
            }
            print("")
            print("已移入废纸篓 \(record.okCount) 项 · \(Util.bytes(record.bytes))")
            if record.failCount > 0 {
                print("失败 \(record.failCount) 项：")
                for item in record.items where !item.ok {
                    print("  · \(abbreviate(item.path)) → \(item.error ?? "unknown")")
                }
            }
            print("操作 id: \(record.id)（撤销：sweep restore --op \(record.id)）")
            print("")
        } catch {
            fail(error.localizedDescription)
        }
    }

    static func restoreCommand(_ options: Options) {
        guard let operationId = options.op else { fail("restore 需要 --op <操作 id>") }
        do {
            let result = try Cleaner.restore(operationId: operationId)
            print("已还原 \(result.restored) 项")
            if !result.failed.isEmpty {
                print("未还原 \(result.failed.count) 项：")
                for line in result.failed { print("  · \(line)") }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    static func opsCommand(_ options: Options) {
        let records = OperationLog.all().suffix(max(1, options.limit))
        if records.isEmpty {
            print("暂无清理记录")
            return
        }
        for record in records {
            print("\(record.id)  \(record.createdAt)  \(record.okCount) 项  \(Util.bytes(record.bytes))  mode=\(record.mode)")
        }
    }

    static func modeCommand(_ args: [String]) {
        if let value = args.first {
            do {
                try AgentConfigStore.setMode(value)
                print("mode = \(value)")
            } catch {
                fail(error.localizedDescription)
            }
            return
        }
        let config = AgentConfigStore.load()
        print("mode     \(config.mode)")
        print("maxBytes \(Util.bytes(config.maxBytes))")
        print("maxItems \(config.maxItems)")
    }

    // MARK: - Output

    static func makeEntries(_ items: [FileItem], limit: Int, category: String? = nil) -> [ScanEntry] {
        items
            .filter { !$0.isDirectory || $0.isPackage }
            .sorted { $0.size > $1.size }
            .prefix(limit)
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

    static func printHuman(_ report: ScanReport) {
        let titles = [
            "system-junk": "系统垃圾", "junk": "系统垃圾",
            "project-junk": "项目垃圾", "projects": "项目垃圾",
            "large-files": "大文件", "large": "大文件",
            "old-files": "旧文件", "old": "旧文件",
            "duplicates": "重复文件", "dup": "重复文件",
            "installers": "安装包",
            "smart": "智能扫描",
        ]
        print("")
        print("\(titles[report.module] ?? report.module)扫描")
        print("总计 \(Util.bytes(report.totalBytes)) · \(report.totalItems) 项 · \(report.scanSeconds)s")
        print(String(repeating: "─", count: 62))

        if report.groups.isEmpty {
            print("未发现可清理项")
        }

        for group in report.groups {
            print("\(group.label.padding(toLength: 18, withPad: " ", startingAt: 0)) \(Util.bytes(group.bytes).leftPadded(9))  \(group.items) 项")
            for entry in group.top.prefix(3) {
                print("    \(Util.bytes(entry.bytes).leftPadded(9))  \(abbreviate(entry.path))")
            }
        }

        for warning in report.warnings {
            print("· \(warning)")
        }
        if let snapshot = report.snapshotPath {
            print("\n快照: \(snapshot)")
        }
        print("")
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .useDefaultKeys
        if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            FileHandle.standardError.write(Data("failed to encode json\n".utf8))
        }
    }

    static func printJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }

    // MARK: - Snapshot

    static func writeSnapshot(module: String, entries: [ScanEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".sweep/snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let stamp = Int(Date().timeIntervalSince1970)
        let url = base.appendingPathComponent("\(module)-\(stamp).json")
        guard let data = try? JSONEncoder().encode(entries) else { return nil }
        do {
            try data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url.path
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    static func resolve(_ raw: [String], default fallback: [String]) -> [URL] {
        let roots = raw.isEmpty ? fallback : raw
        return roots.map { Util.expand($0) }
    }

    static func usage() {
        print("""
        sweep — 磁盘扫描与清理（给 agent 用的结构化接口）

        用法:
          sweep disk [--json]
          sweep mcp                         以 stdio 方式启动 MCP 服务器（给 agent 用）
          sweep ui                          打开本地清理界面
          sweep chart --disk | --status | --ops     磁盘 / 状态 / 清理记录
          sweep chart --snapshot S [--list]         扫描结果（--list 出文件清单）
          sweep chart --plan P               把计划渲染成图片（确认前给用户看）
          sweep chart --op O                 把执行结果渲染成图片（带撤销 id）
          sweep plan  --snapshot S --ids a,b  生成清理计划 + digest
          sweep plan  --snapshot S --min-bytes 5 --categories user_caches,package_manager_caches
          sweep apply --plan P --digest D     执行（移入废纸篓）
          sweep restore --op O                撤销某次操作
          sweep ops [--limit N]               最近的操作记录
          sweep mode [readonly|confirm|auto]  查看/切换自主度
          sweep scan <module> [选项]

        模块:
          system-junk    系统垃圾（21 个分类）
          project-junk   项目垃圾（node_modules / target / .venv …）
          large-files    大文件（默认 ≥200MB）
          old-files      旧文件（默认 ≥365 天未改）
          duplicates     重复文件（四段式，仅字节相同）
          installers     安装包（过期 / 尚未安装）
          smart          智能扫描 = 系统垃圾 + 项目垃圾

        选项:
          --json              输出机器可读 JSON
          --limit N           每组返回的样例条数（默认 10）
          --min-size MB       大文件/重复文件的最小体积（默认 200）
          --days N            旧文件天数（默认 365）
          --roots a,b         指定扫描根目录
          --depth N           项目扫描深度（默认 6）
          --no-save           不写快照

        例:
          sweep scan system-junk --json --limit 20
          sweep scan large-files --min-size 500
          sweep scan project-junk --roots ~/Developer
        """)
    }
}

struct Options {
    var json = false
    var limit = 10
    var minSizeMB: UInt64 = 200
    var days: Double = 365
    var roots: [String] = []
    var depth = 6
    var save = true
    var snapshot: String?
    var ids: [String] = []
    var plan: String?
    var digest: String?
    var op: String?
    var minBytesMB: Int?
    var out: String?
    var diskView = false
    var statusView = false
    var opsView = false
    var listView = false
    var categories: [String] = []

    init(_ args: [String]) {
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--json":
                json = true
            case "--limit":
                index += 1
                if index < args.count, let value = Int(args[index]) { limit = max(1, value) }
            case "--min-size", "--minSize":
                index += 1
                if index < args.count, let value = UInt64(args[index]) { minSizeMB = max(1, value) }
            case "--days":
                index += 1
                if index < args.count, let value = Double(args[index]) { days = max(1, value) }
            case "--roots":
                index += 1
                if index < args.count {
                    roots = args[index].split(separator: ",").map(String.init)
                }
            case "--depth":
                index += 1
                if index < args.count, let value = Int(args[index]) { depth = max(1, value) }
            case "--no-save":
                save = false
            case "--snapshot":
                index += 1
                if index < args.count { snapshot = args[index] }
            case "--ids":
                index += 1
                if index < args.count { ids = args[index].split(separator: ",").map(String.init) }
            case "--plan":
                index += 1
                if index < args.count { plan = args[index] }
            case "--digest":
                index += 1
                if index < args.count { digest = args[index] }
            case "--op":
                index += 1
                if index < args.count { op = args[index] }
            case "--min-bytes":
                index += 1
                if index < args.count, let value = Int(args[index]) { minBytesMB = value }
            case "--disk":
                diskView = true
            case "--status":
                statusView = true
            case "--ops":
                opsView = true
            case "--list":
                listView = true
            case "--out":
                index += 1
                if index < args.count { out = args[index] }
            case "--categories":
                index += 1
                if index < args.count { categories = args[index].split(separator: ",").map(String.init) }
            default:
                break
            }
            index += 1
        }
    }
}

extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
