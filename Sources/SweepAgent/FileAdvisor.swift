import Foundation

public struct FileClassification: Sendable {
    public let subCategory: String
    public let subLabel: String
    public let risk: String       // "safe" | "confirm" | "caution"
    public let riskLabel: String
    public let ageDays: Int?
}

public struct FileAnalysis: Sendable {
    public let subCategory: String
    public let subLabel: String
    public let purpose: String
    public let advice: String
    public let risk: String       // "safe" | "confirm" | "caution"
    public let riskLabel: String
    public let ageDays: Int?

    public func asDictionary(for entry: ScanEntry) -> [String: Any] {
        var dict: [String: Any] = [
            "id": entry.id,
            "path": entry.path,
            "bytes": entry.bytes,
            "category": entry.category ?? "",
            "subCategory": subCategory,
            "subLabel": subLabel,
            "purpose": purpose,
            "advice": advice,
            "risk": risk,
            "riskLabel": riskLabel,
        ]
        if let modified = entry.modified { dict["modified"] = modified }
        if let kind = entry.kind { dict["kind"] = kind }
        if let ageDays { dict["ageDays"] = ageDays }
        return dict
    }
}

public enum FileAdvisor {
    public static func currentEpochDay(now: Date = Date()) -> Int {
        Int(now.timeIntervalSince1970 / 86_400)
    }

    public static func analyze(_ entry: ScanEntry, now: Date = Date()) -> FileAnalysis {
        let cls = classify(entry, todayEpochDay: currentEpochDay(now: now))
        return describe(entry, classification: cls)
    }

    /// Fast classification without allocating purpose/advice prose strings.
    /// Used when indexing 100k+ snapshot entries in memory.
    public static func classify(_ entry: ScanEntry, todayEpochDay: Int) -> FileClassification {
        let category = entry.category ?? ""
        let path = entry.path
        let name: Substring = {
            if let slash = path.lastIndex(of: "/") {
                return path[path.index(after: slash)...]
            }
            return path[...]
        }()
        let ageDays = parseAgeDaysFast(entry.modified, todayEpochDay: todayEpochDay)

        switch category {
        case "package_manager_caches":
            if containsASCII(path, "/.cache/uv/") || containsASCII(path, "/caches/uv/") {
                return FileClassification(subCategory: "pkg_uv", subLabel: "uv Python 缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/.npm/") || containsASCII(path, "/npm-cache/") {
                return FileClassification(subCategory: "pkg_npm", subLabel: "npm 包缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/pnpm/") || containsASCII(path, "/.pnpm") {
                return FileClassification(subCategory: "pkg_pnpm", subLabel: "pnpm 全局存储", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/yarn/") || containsASCII(path, "/.yarn/") {
                return FileClassification(subCategory: "pkg_yarn", subLabel: "Yarn 包缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/.bun/") {
                return FileClassification(subCategory: "pkg_bun", subLabel: "Bun 安装缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/pip/") || containsASCII(path, "/.cache/pip") {
                return FileClassification(subCategory: "pkg_pip", subLabel: "pip 包缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/homebrew/") || containsASCII(path, "/caches/homebrew") {
                return FileClassification(subCategory: "pkg_brew", subLabel: "Homebrew 下载缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/.cargo/") || containsASCII(path, "/.rustup/") {
                return FileClassification(subCategory: "pkg_cargo", subLabel: "Cargo / Rust 缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/.cache/huggingface") || containsASCII(path, "/huggingface/") {
                return FileClassification(subCategory: "pkg_hf", subLabel: "Hugging Face 模型缓存", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)
            }
            if containsASCII(path, "/ms-playwright") {
                return FileClassification(subCategory: "pkg_playwright", subLabel: "Playwright 浏览器内核", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)
            }
            if containsASCII(path, "/.gradle/") || containsASCII(path, "/.m2/") {
                return FileClassification(subCategory: "pkg_jvm", subLabel: "Gradle / Maven 缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/cocoapods/") {
                return FileClassification(subCategory: "pkg_pods", subLabel: "CocoaPods 缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/go/pkg/") {
                return FileClassification(subCategory: "pkg_go", subLabel: "Go 模块缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            return FileClassification(subCategory: "pkg_other", subLabel: "其他包管理器缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)

        case "user_caches":
            if containsASCII(path, "/caches/com.google.antigravity") || containsASCII(path, "/caches/antigravity") {
                let isUpdate = hasSuffixASCII(path, ".zip") || containsASCII(path, "/pending/")
                return FileClassification(
                    subCategory: "cache_antigravity",
                    subLabel: "Antigravity 应用缓存",
                    risk: isUpdate ? "confirm" : "safe",
                    riskLabel: isUpdate ? "按需确认" : "推荐清理",
                    ageDays: ageDays
                )
            }
            if containsASCII(path, "/caches/codex") || containsASCII(path, "/caches/com.openai.codex") {
                return FileClassification(subCategory: "cache_codex", subLabel: "Codex 桌面端缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/caches/google/chrome") || containsASCII(path, "/caches/com.google.chrome") {
                return FileClassification(subCategory: "cache_chrome", subLabel: "Chrome 浏览器缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/caches/com.apple.safari") {
                return FileClassification(subCategory: "cache_safari", subLabel: "Safari 浏览器缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/caches/company.thebrowser.browser") || containsASCII(path, "/caches/arc") {
                return FileClassification(subCategory: "cache_arc", subLabel: "Arc 浏览器缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/caches/com.bytedance.") || containsASCII(path, "doubao") {
                return FileClassification(subCategory: "cache_bytedance", subLabel: "豆包 / 字节系应用缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/caches/com.tencent.") || containsASCII(path, "wechat") {
                return FileClassification(subCategory: "cache_tencent", subLabel: "微信 / 腾讯系应用缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/caches/com.apple.") {
                return FileClassification(subCategory: "cache_apple", subLabel: "macOS 自带应用缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            for app in Self.knownCacheApps where containsASCII(path, app.needle) {
                return FileClassification(subCategory: app.sub, subLabel: app.label, risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            return FileClassification(subCategory: "cache_other", subLabel: "其他桌面应用缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)

        case "system_caches":
            return FileClassification(subCategory: "sys_cache", subLabel: "系统级共享缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)

        case "ai_tool_caches":
            if containsASCII(path, "/.codex/.tmp/") {
                return FileClassification(subCategory: "ai_codex_tmp", subLabel: "Codex 插件市场临时库", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/.codex/") {
                return FileClassification(subCategory: "ai_codex_cache", subLabel: "Codex 工具缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/.ollama/") {
                return FileClassification(subCategory: "ai_ollama", subLabel: "Ollama 本地模型缓存", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)
            }
            if containsASCII(path, "huggingface") || containsASCII(path, "modelscope") {
                return FileClassification(subCategory: "ai_models", subLabel: "本地 AI 模型缓存", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)
            }
            return FileClassification(subCategory: "ai_other", subLabel: "其他 AI 工具缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)

        case "ide_caches":
            if containsASCII(path, "/antigravity/") {
                return FileClassification(subCategory: "ide_antigravity", subLabel: "Antigravity IDE 缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/cursor/") {
                return FileClassification(subCategory: "ide_cursor", subLabel: "Cursor IDE 缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/code/") || containsASCII(path, "vscode") {
                return FileClassification(subCategory: "ide_vscode", subLabel: "VS Code 缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "jetbrains") {
                return FileClassification(subCategory: "ide_jetbrains", subLabel: "JetBrains IDE 缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            return FileClassification(subCategory: "ide_other", subLabel: "其他编辑器缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)

        case "project_junk":
            let (subCat, subLabel): (String, String) = {
                switch entry.kind ?? "" {
                case "nodeModules": return ("proj_node", "Node.js 依赖 (node_modules)")
                case "pythonVenv": return ("proj_venv", "Python 虚拟环境 (.venv)")
                case "nextBuild": return ("proj_next", "Next.js 构建缓存 (.next)")
                case "dist": return ("proj_dist", "前端构建产物 (dist/build)")
                case "rustTarget": return ("proj_target", "Rust / Maven 构建目录 (target)")
                case "gradleBuild": return ("proj_gradle", "Gradle 构建输出")
                case "mavenBuild": return ("proj_maven", "Maven 构建输出")
                case "cocoaPods": return ("proj_pods", "CocoaPods 依赖 (Pods)")
                default: return ("proj_other", "其他项目构建依赖")
                }
            }()
            if let age = ageDays, age <= 7 {
                return FileClassification(subCategory: subCat, subLabel: subLabel, risk: "caution", riskLabel: "谨慎保留", ageDays: ageDays)
            }
            return FileClassification(subCategory: subCat, subLabel: subLabel, risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)

        case "user_logs":
            if containsASCII(path, "diagnosticreports") {
                return FileClassification(subCategory: "log_crash", subLabel: "应用崩溃与诊断报告", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "com.openai.codex") {
                return FileClassification(subCategory: "log_codex", subLabel: "Codex 运行日志", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "antigravity") {
                return FileClassification(subCategory: "log_antigravity", subLabel: "Antigravity 运行日志", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            return FileClassification(subCategory: "log_user_other", subLabel: "其他桌面应用日志", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)

        case "system_logs":
            if containsASCII(path, "diagnosticreports") {
                return FileClassification(subCategory: "log_sys_diag", subLabel: "系统诊断与磁盘报告", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "install.log") {
                return FileClassification(subCategory: "log_sys_install", subLabel: "系统安装历史日志", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)
            }
            return FileClassification(subCategory: "log_sys_other", subLabel: "系统守护进程日志", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)

        case "incomplete_downloads", "broken_downloads":
            if containsASCII(path, "/var/folders/") || name.hasPrefix(".com.") {
                return FileClassification(subCategory: "dl_app_tmp", subLabel: "应用临时下载与更新碎片", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            return FileClassification(subCategory: "dl_incomplete", subLabel: "未完成的下载文件", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)

        case "unused_disk_images", "uninstalled_installers":
            let kind = entry.kind ?? ""
            if category == "uninstalled_installers" || kind == "未安装" {
                return FileClassification(subCategory: "inst_uninstalled", subLabel: "未安装软件的安装包", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)
            }
            if kind.hasPrefix("已安装") {
                return FileClassification(subCategory: "inst_installed", subLabel: "已安装软件的旧安装包", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            return FileClassification(subCategory: "inst_dmg", subLabel: "磁盘映像与安装文件 (.dmg/.pkg)", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)

        case "duplicates":
            let ext: String = {
                guard let dot = name.lastIndex(of: ".") else { return "" }
                return name[name.index(after: dot)...].lowercased()
            }()
            if ["dmg", "pkg", "zip", "tar", "gz", "rar", "7z", "iso"].contains(ext) {
                return FileClassification(subCategory: "dup_archives", subLabel: "重复压缩包与安装镜像", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)
            }
            if ["mp4", "mov", "mkv", "avi", "mp3", "wav", "flac", "m4a"].contains(ext) {
                return FileClassification(subCategory: "dup_media", subLabel: "重复视频与音频", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)
            }
            if ["jpg", "jpeg", "png", "heic", "webp", "gif", "svg", "psd"].contains(ext) {
                return FileClassification(subCategory: "dup_images", subLabel: "重复图片与素材", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)
            }
            if ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "md", "txt", "csv"].contains(ext) {
                return FileClassification(subCategory: "dup_docs", subLabel: "重复文档与资料", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)
            }
            return FileClassification(subCategory: "dup_other", subLabel: "其他重复文件", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)

        case "broken_preferences":
            if name.hasPrefix("com.apple.") {
                return FileClassification(subCategory: "pref_apple", subLabel: "Apple 系统服务偏好设置", risk: "caution", riskLabel: "谨慎保留", ageDays: ageDays)
            }
            return FileClassification(subCategory: "pref_apps", subLabel: "第三方应用偏好设置 (.plist)", risk: "caution", riskLabel: "谨慎保留", ageDays: ageDays)

        case "broken_login_items":
            return FileClassification(subCategory: "sys_login_items", subLabel: "疑似失效启动项 (LaunchAgents)", risk: "caution", riskLabel: "谨慎保留", ageDays: ageDays)

        case "xcode_junk":
            if containsASCII(path, "/deriveddata/") {
                return FileClassification(subCategory: "xcode_derived", subLabel: "Xcode DerivedData 编译缓存", risk: "safe", riskLabel: "推荐清理", ageDays: ageDays)
            }
            if containsASCII(path, "/coresimulator/") {
                return FileClassification(subCategory: "xcode_sim", subLabel: "Xcode 模拟器数据", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)
            }
            return FileClassification(subCategory: "xcode_other", subLabel: "Xcode 支持与归档缓存", risk: "confirm", riskLabel: "按需确认", ageDays: ageDays)

        case "ios_device_backups":
            return FileClassification(subCategory: "ios_backups", subLabel: "iOS 本地设备备份", risk: "caution", riskLabel: "谨慎保留", ageDays: ageDays)

        default:
            return FileClassification(
                subCategory: category.isEmpty ? "other" : category,
                subLabel: CategoryLabels.label(category),
                risk: "confirm",
                riskLabel: "按需确认",
                ageDays: ageDays
            )
        }
    }

    private static let knownCacheApps: [(needle: StaticString, sub: String, label: String)] = [
        ("firefox", "cache_firefox", "Firefox 浏览器缓存"),
        ("microsoft.edgemac", "cache_edge", "Edge 浏览器缓存"),
        ("docker", "cache_docker", "Docker 缓存"),
        ("raycast", "cache_raycast", "Raycast 缓存"),
        ("spotify", "cache_spotify", "Spotify 媒体缓存"),
        ("slack", "cache_slack", "Slack 应用缓存"),
        ("discord", "cache_discord", "Discord 应用缓存"),
        ("telegram", "cache_telegram", "Telegram 缓存"),
        ("notion", "cache_notion", "Notion 缓存"),
        ("figma", "cache_figma", "Figma 缓存"),
        ("obsidian", "cache_obsidian", "Obsidian 缓存"),
        ("xcode", "cache_xcode", "Xcode 用户缓存"),
        ("jetbrains", "cache_jetbrains", "JetBrains 用户缓存"),
        ("ms-playwright", "cache_playwright", "Playwright 缓存"),
    ]

    private static func containsASCII(_ haystack: String, _ needle: StaticString) -> Bool {
        var copy = haystack
        return copy.withUTF8 { hPtr in
            needle.withUTF8Buffer { nPtr in
                let hCount = hPtr.count
                let nCount = nPtr.count
                if nCount == 0 { return true }
                if hCount < nCount { return false }
                let first = nPtr[0]
                let limit = hCount - nCount
                for i in 0...limit {
                    var hb = hPtr[i]
                    if hb >= 65 && hb <= 90 { hb &+= 32 }
                    if hb != first { continue }
                    var matched = true
                    for j in 1..<nCount {
                        var b = hPtr[i + j]
                        if b >= 65 && b <= 90 { b &+= 32 }
                        if b != nPtr[j] {
                            matched = false
                            break
                        }
                    }
                    if matched { return true }
                }
                return false
            }
        }
    }

    private static func hasSuffixASCII(_ haystack: String, _ suffix: StaticString) -> Bool {
        var copy = haystack
        return copy.withUTF8 { hPtr in
            suffix.withUTF8Buffer { sPtr in
                let hCount = hPtr.count
                let sCount = sPtr.count
                if hCount < sCount { return false }
                let start = hCount - sCount
                for j in 0..<sCount {
                    var hb = hPtr[start + j]
                    if hb >= 65 && hb <= 90 { hb &+= 32 }
                    if hb != sPtr[j] { return false }
                }
                return true
            }
        }
    }

    /// Generates rich purpose & cleanup advice strings on demand for displayed items.
    public static func describe(_ entry: ScanEntry, classification cls: FileClassification) -> FileAnalysis {
        let path = entry.path
        let lower = path.lowercased()
        let name = (path as NSString).lastPathComponent
        let ageDays = cls.ageDays

        let purpose: String
        let advice: String

        switch cls.subCategory {
        case "pkg_uv":
            if lower.contains("/git-v0/") {
                purpose = "uv 拉取的 Python Git 依赖仓库包（\(name)），用于加速 git+https 依赖离线构建。"
            } else if lower.contains("/archive-v0/") || lower.contains("/wheels") {
                purpose = "uv 解压或编译后的 Python 轮子缓存文件（\(name)），用于加快虚拟环境安装。"
            } else {
                purpose = "uv 包管理器的 Python 依赖本地缓存文件（\(name)）。"
            }
            advice = "推荐清理：纯可重建缓存，删除不影响现有 .venv；下次运行 uv pip/sync 时会按需重下。"

        case "pkg_npm":
            purpose = "npm 内容寻址本地缓存对象（\(name)），保存曾下载过的 JS/TS 依赖 tarball 数据。"
            advice = "推荐清理：删除不会破坏任何项目的 node_modules；后续 npm install 会按需重新下载。"

        case "pkg_pnpm":
            purpose = "pnpm 全局硬链接包存储或下载缓存（\(name)），供多项目复用依赖。"
            advice = "推荐清理前留意：孤立包可安全清理（pnpm store prune）；删除整个缓存后重装会重新拉取。"

        case "pkg_yarn":
            purpose = "Yarn 离线包归档与镜像缓存文件（\(name)）。"
            advice = "推荐清理：不影响已有项目依赖，下次执行 yarn install 会自动按需重建缓存。"

        case "pkg_bun":
            purpose = "Bun 包管理器全局依赖安装缓存（\(name)）。"
            advice = "推荐清理：删除后不影响已有项目，下次运行 bun install 自动恢复。"

        case "pkg_pip":
            purpose = "Python pip 下载的 .whl / 源码包 HTTP 缓存（\(name)）。"
            advice = "推荐清理：仅缓存历史下载包，删除后不影响已安装的 Python 环境。"

        case "pkg_brew":
            purpose = "Homebrew 安装或升级软件时留存的瓶装包（bottle）与压缩档「\(name)」。"
            advice = "推荐清理：软件已安装完成，保留旧安装包意义不大，清理后可安全释放空间。"

        case "pkg_cargo":
            purpose = "Rust Cargo 拉取的 crate 源码压缩包与索引缓存「\(name)」。"
            advice = "推荐清理：仅删除下载缓存，不删除工具链与项目源码，下次 cargo build 会重新拉取。"

        case "pkg_hf":
            purpose = "Hugging Face 下载的模型权重、分词器或数据集分片「\(name)」。"
            advice = "按需确认：虽可重新下载，但大模型重新拉取耗时较长；确认该模型不再使用后再清理。"

        case "pkg_playwright":
            purpose = "Playwright 自动化测试下载的独立 Chromium / Firefox / WebKit 浏览器二进制。"
            advice = "按需确认：若近期不做浏览器自动化测试可删除，后续可用 playwright install 重装。"

        case "pkg_jvm":
            purpose = "Java / Kotlin / Android 构建工具缓存的 JAR / AAR 依赖制品「\(name)」。"
            advice = "推荐清理：删除后下次编译项目会自动回源拉取所需版本。"

        case "pkg_pods":
            purpose = "CocoaPods 缓存的 iOS/macOS 第三方库归档与 Spec 索引「\(name)」。"
            advice = "推荐清理：删除后不影响现有工程的 Pods，下次 pod install 按需重新下载。"

        case "pkg_go":
            purpose = "Go 工具链在 GOMODCACHE 中保存的模块源码归档「\(name)」。"
            advice = "推荐清理：可随时通过 go mod download 重新拉取。"

        case "pkg_other":
            purpose = "开发工具或包管理器生成的本地下载缓存文件「\(name)」。"
            advice = "推荐清理：通常为可自动重建的缓存文件，删除不影响系统核心功能。"

        case "cache_antigravity":
            let isUpdate = name.lowercased().hasSuffix(".zip") || lower.contains("/pending/")
            purpose = isUpdate
                ? "Antigravity 客户端后台预下载的更新包「\(name)」。"
                : "Antigravity 应用运行时缓存文件「\(name)」。"
            advice = isUpdate
                ? "按需确认：若 Antigravity 已是最新版本且运行正常，该离线更新包可安全清理。"
                : "推荐清理：属于应用临时缓存，重启后会按需自动重建。"

        case "cache_codex":
            let isPendingDelete = name.hasPrefix("todelete_")
            purpose = isPendingDelete
                ? "Codex 内核已标记待回收的旧缓存数据块「\(name)」。"
                : "Codex 桌面客户端 Chromium/Electron 资源与 JS 编译缓存「\(name)」。"
            advice = "推荐清理：删除不会丢失对话历史或本地项目，重启客户端会自动重建。"

        case "cache_chrome":
            purpose = "Google Chrome 缓存的网页图片、脚本与媒体资源「\(name)」。"
            advice = "推荐清理：仅清理离线网页缓存，不会删除书签、密码或登录状态。"

        case "cache_safari":
            purpose = "Safari 缓存的网页图标、离线静态资源与预览缩略图「\(name)」。"
            advice = "推荐清理：不会影响书签、历史记录或钥匙串密码。"

        case "cache_arc":
            purpose = "Arc 浏览器运行时写入的网页资源与渲染缓存「\(name)」。"
            advice = "推荐清理：不会删除标签页空间或扩展配置，可安全释放空间。"

        case "cache_bytedance":
            purpose = "豆包输入法或字节系桌面应用的本地数据库日志与临时缓存「\(name)」。"
            advice = "推荐清理：可安全清理，不影响账号与基础词库，使用时会按需重建。"

        case "cache_tencent":
            purpose = "微信或腾讯系应用生成的临时媒体资源与网页缓存「\(name)」。"
            advice = "推荐清理：清理 ~/Library/Caches 下缓存不会删除聊天记录主库，请避开 Documents 目录。"

        case "cache_apple":
            purpose = "Apple 系统内置组件（如 Spotlight、照片、地图等）缓存文件「\(name)」。"
            advice = "推荐清理：系统会在需要时自动再生；建议先关闭对应软件后清理。"

        case "cache_other":
            if let appFolder = cacheAppBucket(path: path) {
                let cleanName = humanizeBundle(appFolder)
                purpose = "桌面应用「\(cleanName)」保存在用户缓存目录的临时资源「\(name)」。"
            } else {
                purpose = "用户级应用生成的缓存数据「\(name)」。"
            }
            advice = "推荐清理：常规应用运行缓存，清理后下次启动应用会自动重建。"

        case "sys_cache":
            purpose = "macOS 系统或跨用户共享服务在 /Library/Caches 写入的运行时缓存或文件锁。"
            advice = "一般占用极小；除非排查系统缓存异常，否则系统会按需自动覆盖或清理。"

        case "ai_codex_tmp":
            purpose = "Codex 客户端拉取内置/三方插件市场时留在 .tmp 目录的 Git 临时对象与素材「\(name)」。"
            advice = "推荐清理：临时工作区缓存，删除后下次打开插件市场会重新同步。"

        case "ai_codex_cache":
            purpose = "Codex 运行时缓存的工具索引或元数据「\(name)」。"
            advice = "推荐清理：不会删除配置与主要工作文件，可安全清理。"

        case "ai_ollama":
            purpose = "Ollama 下载的本地大模型权重文件或临时分片「\(name)」。"
            advice = "按需确认：模型文件体积较大，重下耗时；仅确认该本地模型已不再需要时再清理。"

        case "ai_models":
            purpose = "AI 框架缓存的模型权重、分词词表或推理缓存「\(name)」。"
            advice = "按需确认：删除不会破坏代码，但再次加载对应模型需重新联网下载。"

        case "ai_other":
            purpose = "AI 编程/推理工具生成的本地缓存数据「\(name)」。"
            advice = "推荐清理：常规可重建缓存；若含离线权重文件请先确认后再清理。"

        case "ide_antigravity":
            purpose = "Antigravity 编辑器内嵌视图缓存或扩展元数据缓存「\(name)」。"
            advice = "推荐清理：不会影响工作区代码与插件设置，重启编辑器自动恢复。"

        case "ide_cursor":
            purpose = "Cursor 编辑器内置扩展索引或渲染层缓存「\(name)」。"
            advice = "推荐清理：不影响代码、Rules 或已安装的扩展，下次启动自动重建。"

        case "ide_vscode":
            purpose = "VS Code 缓存的扩展列表、语言服务或 Webview 数据「\(name)」。"
            advice = "推荐清理：不会删除工作区与 settings.json，可安全释放。"

        case "ide_jetbrains":
            purpose = "JetBrains 系列 IDE（PyCharm / WebStorm / IDEA 等）的代码索引缓存「\(name)」。"
            advice = "推荐清理：旧版本或超大索引可清理，重启 IDE 后会重新建立索引。"

        case "ide_other":
            purpose = "代码编辑器生成的索引与界面缓存「\(name)」。"
            advice = "推荐清理：不影响源代码，可安全清理。"

        case "proj_node", "proj_venv", "proj_next", "proj_dist", "proj_target", "proj_gradle", "proj_maven", "proj_pods", "proj_other":
            let projectName = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            let rebuildCmd: String = {
                switch cls.subCategory {
                case "proj_node": return "npm / pnpm / yarn install"
                case "proj_venv": return "uv sync 或 python -m venv && pip install"
                case "proj_next": return "next dev / next build"
                case "proj_dist": return "npm run build"
                case "proj_target": return "cargo build"
                case "proj_gradle": return "./gradlew build"
                case "proj_maven": return "mvn package"
                case "proj_pods": return "pod install"
                default: return "对应项目构建命令"
                }
            }()
            purpose = "项目「\(projectName)」下的「\(cls.subLabel)」（\(name)）。"
            if let age = ageDays, age <= 7 {
                advice = "谨慎保留：该项目 \(age) 天前仍有修改，可能正在开发中；确认暂停开发后再删（可用 \(rebuildCmd) 恢复）。"
            } else if let age = ageDays, age >= 30 {
                advice = "建议清理：项目已超过 \(age) 天未改动，删除不影响源码；需要时在项目目录运行 \(rebuildCmd) 即可恢复。"
            } else {
                advice = "按需确认：不会删除源码；若近期不再运行该项目可清理，日后通过 \(rebuildCmd) 一键重建。"
            }

        case "log_crash":
            purpose = "macOS 记录的程序崩溃堆栈或性能诊断报告「\(name)」。"
            advice = "推荐清理：仅用于排错溯源，无需排查闪退问题时可全部清理。"

        case "log_codex":
            purpose = "Codex 桌面端各会话实例生成的本地调试日志文件「\(name)」。"
            advice = "推荐清理：纯历史诊断文本，删除不影响聊天记录与功能。"

        case "log_antigravity":
            purpose = "Antigravity 编辑器与语言服务输出的运行日志「\(name)」。"
            advice = "推荐清理：纯调试日志，无排错需求可直接清理。"

        case "log_user_other":
            purpose = "用户级桌面软件运行过程中写入的日志记录「\(name)」。"
            advice = "推荐清理：不影响软件数据与配置，可安全删除。"

        case "log_sys_diag":
            purpose = "系统记录的磁盘写入/唤醒/内核诊断报告「\(name)」。"
            advice = "推荐清理：历史诊断文件，无排查系统异常需求可清理。"

        case "log_sys_install":
            purpose = "macOS 软件安装与系统更新详细流水记录（install.log）。"
            advice = "按需确认：仅作系统安装审计记录，通常可清理旧日志，但系统日志会持续重新写入。"

        case "log_sys_other":
            purpose = "launchd、Wi-Fi 等 macOS 系统底层服务的运行日志「\(name)」。"
            advice = "按需确认：单文件通常仅数百 KB，无排障需求可清理。"

        case "dl_app_tmp":
            purpose = "桌面应用（如 Codex 等）在系统临时区写入的下载/更新临时文件「\(name)」。"
            advice = "推荐清理：属于临时目录残留文件；若对应应用当前未在更新下载，可安全清理。"

        case "dl_incomplete":
            purpose = "中断或未完成的下载残留文件「\(name)」。"
            advice = "按需确认：如确定不再续传该下载任务，可删除以释放空间。"

        case "inst_uninstalled":
            purpose = "磁盘映像/安装包「\(name)」，在 /Applications 中未匹配到同名已装软件。"
            advice = "按需确认：若你不再准备安装该软件（或已改用其他版本/安装包），可安全移入废纸篓。"

        case "inst_installed":
            let app = (entry.kind ?? "").replacingOccurrences(of: "已安装 ", with: "")
            purpose = "安装包「\(name)」，对应软件（\(app)）已存在于应用程序目录。"
            advice = "推荐清理：应用已经安装完毕，保留原安装包通常是多余占用。"

        case "inst_dmg":
            purpose = "位于「\(shortParent(path))」的安装包文件「\(name)」。"
            advice = "按需确认：确认不再需要重装或离线存档后可清理。"

        case "dup_archives", "dup_media", "dup_images", "dup_docs", "dup_other":
            purpose = "经全量 SHA-256 哈希比对确认与磁盘中另一路径文件字节完全相同的副本「\(name)」。"
            advice = "按需确认：另一份主文件会被保留，建议确认当前路径无需独立引用后再清理此副本。"

        case "pref_apple":
            purpose = "macOS 系统或自带功能模块的配置清单「\(name)」。"
            advice = "建议保留：文件极小且系统组件会读取它，删除可能导致对应系统设置还原为默认值。"

        case "pref_apps":
            purpose = "第三方软件「\(humanizeBundle(name.replacingOccurrences(of: ".plist", with: "")))」的偏好设置文件。"
            advice = "谨慎保留：若该软件仍在使用切勿删除，否则会清空快捷键/登录与自定义设置；仅确认软件已卸载再删。"

        case "sys_login_items":
            purpose = "用户级后台服务配置文件「\(name)」，用于登录时自动拉起守护进程或代理。"
            advice = "请核对对应工具是否已卸载：若程序已彻底移除可安全删除；若仍在使用则必须保留。"

        case "xcode_derived":
            purpose = "Xcode 为工程生成的中间编译产物、索引数据库与构建缓存「\(name)」。"
            advice = "推荐清理：纯可重建编译缓存，删除后下次打开 Xcode 编译会自动重建。"

        case "xcode_sim":
            purpose = "iOS/watchOS 模拟器设备镜像或沙盒运行缓存「\(name)」。"
            advice = "按需确认：清理可释放大量空间，旧系统版本模拟器通常可放心删除。"

        case "xcode_other":
            purpose = "Xcode 缓存的设备调试符号（DeviceSupport）或构建归档「\(name)」。"
            advice = "按需确认：旧版本 iOS DeviceSupport 可安全清理，连真机时会按需重新提取。"

        case "ios_backups":
            purpose = "iPhone / iPad 通过 Finder 本地同步生成的完整设备备份快照「\(name)」。"
            advice = "含个人应用与系统配置数据；确认已有最新云备份或不再需要旧设备快照后再删除。"

        default:
            if cls.subCategory.hasPrefix("cache_") {
                purpose = "\(cls.subLabel.replacingOccurrences(of: " 缓存", with: ""))运行时写入的本地缓存文件「\(name)」。"
                advice = "推荐清理：常规可重建缓存，重启对应应用后自动恢复。"
            } else {
                purpose = "位于「\(shortParent(path))」的「\(name)」，被归类为「\(cls.subLabel)」。"
                advice = "建议确认路径与最近修改时间后再决定是否清理；清理操作会先移至废纸篓并支持撤销。"
            }
        }

        return FileAnalysis(
            subCategory: cls.subCategory,
            subLabel: cls.subLabel,
            purpose: purpose,
            advice: advice,
            risk: cls.risk,
            riskLabel: cls.riskLabel,
            ageDays: cls.ageDays
        )
    }

    // MARK: - Helpers

    /// Parses YYYY-MM-DD from ISO8601 prefix with pure integer math (~30,000x faster than ISO8601DateFormatter).
    private static func parseAgeDaysFast(_ iso: String?, todayEpochDay: Int) -> Int? {
        guard let iso else { return nil }
        var copy = iso
        return copy.withUTF8 { bytes in
            guard bytes.count >= 10, bytes[4] == 45, bytes[7] == 45 else { return nil } // '-'
            func digit(_ b: UInt8) -> Int? { b >= 48 && b <= 57 ? Int(b - 48) : nil }
            guard let y0 = digit(bytes[0]), let y1 = digit(bytes[1]), let y2 = digit(bytes[2]), let y3 = digit(bytes[3]),
                  let m0 = digit(bytes[5]), let m1 = digit(bytes[6]),
                  let d0 = digit(bytes[8]), let d1 = digit(bytes[9])
            else { return nil }

            var y = y0 * 1000 + y1 * 100 + y2 * 10 + y3
            let m = m0 * 10 + m1
            let d = d0 * 10 + d1
            guard m >= 1, m <= 12, d >= 1, d <= 31 else { return nil }

            y -= m <= 2 ? 1 : 0
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let entryEpochDay = era * 146097 + doe - 719468
            return max(0, todayEpochDay - entryEpochDay)
        }
    }

    private static func shortParent(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        if parent.hasPrefix(home) {
            return "~" + parent.dropFirst(home.count)
        }
        return parent
    }

    private static func cacheAppBucket(path: String) -> String? {
        guard let range = path.range(of: "/Library/Caches/") else { return nil }
        let tail = path[range.upperBound...]
        guard let first = tail.split(separator: "/").first else { return nil }
        return String(first)
    }

    private static func humanizeBundle(_ raw: String) -> String {
        let parts = raw.split(separator: ".").map(String.init)
        if parts.count >= 3, ["com", "org", "io", "ai", "net", "app", "co", "dev"].contains(parts[0].lowercased()) {
            let candidate = parts.last == "macos" || parts.last == "desktop" || parts.last == "app"
                ? parts[parts.count - 2]
                : parts.last ?? raw
            return candidate.prefix(1).uppercased() + candidate.dropFirst()
        }
        return raw
    }
}
