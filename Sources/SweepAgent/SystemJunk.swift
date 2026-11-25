import Foundation
import MacCleanKit

public enum CategoryLabels {
    static let zh: [String: String] = [
        "user_caches": "用户缓存文件",
        "system_caches": "系统缓存文件",
        "user_logs": "用户日志文件",
        "system_logs": "系统日志文件",
        "language_files": "语言文件",
        "broken_preferences": "损坏的偏好设置",
        "broken_login_items": "失效的登录项",
        "document_versions": "文档版本",
        "broken_downloads": "残留下载文件",
        "ios_device_backups": "iOS 设备备份",
        "old_updates": "旧更新文件",
        "universal_binaries": "通用二进制",
        "xcode_junk": "Xcode 垃圾",
        "deleted_users": "已删除用户数据",
        "unused_disk_images": "未使用的磁盘映像",
        "incomplete_downloads": "未完成下载",
        "app_leftovers": "已删除应用的残留",
        "package_manager_caches": "包管理器缓存",
        "ide_caches": "IDE 与编辑器缓存",
        "ai_tool_caches": "AI 工具缓存",
        "clipboard_archives": "剪贴板归档",
        "mail_attachments": "邮件附件",
        "trash_bins": "废纸篓",
        "malware": "恶意软件",
        "possible_threats": "可能的威胁",
        "browser_privacy": "浏览器隐私",
        "system_privacy": "系统隐私",
        "large_files": "大文件",
        "old_files": "旧文件",
        "duplicates": "重复文件",
        "project_junk": "项目垃圾",
    ]

    public static func label(_ category: ScanCategory) -> String {
        zh[category.rawValue] ?? category.rawValue
    }

    public static func label(_ rawValue: String) -> String {
        zh[rawValue] ?? rawValue
    }
}

/// System Junk: the 21 categories Sweep composes for its Smart Scan.
public struct SystemJunkScanner {
    public static let allCategories: [any JunkCategory] = [
        UserCacheCategory(),
        SystemCacheCategory(),
        UserLogCategory(),
        SystemLogCategory(),
        LanguageFilesCategory(),
        BrokenPreferencesCategory(),
        BrokenLoginItemsCategory(),
        DocumentVersionsCategory(),
        BrokenDownloadsCategory(),
        IOSDeviceBackupsCategory(),
        OldUpdatesCategory(),
        UniversalBinariesCategory(),
        XcodeJunkCategory(),
        DeletedUsersCategory(),
        UnusedDiskImagesCategory(),
        IncompleteDownloadsCategory(),
        AppLeftoversCategory(),
        PackageManagerCachesCategory(),
        IDECachesCategory(),
        AIToolCachesCategory(),
        ClipboardArchivesCategory(),
    ]

    private let walker: FileWalker

    public init(walker: FileWalker = FileWalker()) {
        self.walker = walker
    }

    public func scan(
        categories: [any JunkCategory] = SystemJunkScanner.allCategories,
        limit: Int,
        onProgress: ((Double, String, String, UInt64, Int) -> Void)? = nil
    ) async -> (groups: [ScanGroup], denied: [URL], perCategory: [(ScanCategory, [FileItem])]) {
        let total = max(categories.count, 1)
        var completed = 0
        var totalBytes: UInt64 = 0
        var totalItems = 0

        onProgress?(0.02, "系统垃圾", "0/\(total)", 0, 0)

        let outcomes = await withTaskGroup(of: (Int, ScanCategory, ScanGroup?, [URL], [FileItem]).self) { group in
            let maxConcurrent = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount))
            var nextIdx = 0

            func enqueueNext(_ idx: Int) {
                let category = categories[idx]
                group.addTask {
                    let result = await walker.scan(
                        targets: category.targets,
                        options: ScanWalkOptions(leafOnly: false, includeIdentity: false)
                    )
                    let bytes = FileWalker.leafBytes(of: result.items)
                    let catLabel = CategoryLabels.label(category.scanCategory)
                    let scanGroup: ScanGroup? = (!result.items.isEmpty || bytes > 0)
                        ? ScanGroup(
                            category: category.scanCategory.rawValue,
                            label: catLabel,
                            items: result.items.count,
                            bytes: bytes,
                            top: Util.entries(from: result.items, limit: limit, category: category.scanCategory.rawValue)
                        )
                        : nil
                    return (idx, category.scanCategory, scanGroup, result.deniedPaths, result.items)
                }
            }

            for _ in 0..<min(maxConcurrent, categories.count) {
                enqueueNext(nextIdx)
                nextIdx += 1
            }

            var ordered = Array<(category: ScanCategory, group: ScanGroup?, denied: [URL], items: [FileItem])?>(
                repeating: nil,
                count: categories.count
            )

            while let (idx, cat, scanGroup, catDenied, items) = await group.next() {
                ordered[idx] = (cat, scanGroup, catDenied, items)

                completed += 1
                if let scanGroup {
                    totalBytes &+= scanGroup.bytes
                    totalItems += scanGroup.items
                }

                let catLabel = CategoryLabels.label(cat)
                onProgress?(Double(completed) / Double(total), catLabel, "\(completed)/\(total)", totalBytes, totalItems)

                if nextIdx < categories.count && !Task.isCancelled {
                    enqueueNext(nextIdx)
                    nextIdx += 1
                }
            }
            return ordered
        }

        var groups: [ScanGroup] = []
        var denied: [URL] = []
        var perCategory: [(ScanCategory, [FileItem])] = []
        perCategory.reserveCapacity(categories.count)

        for entry in outcomes {
            guard let entry else { continue }
            denied.append(contentsOf: entry.denied)
            perCategory.append((entry.category, entry.items))
            if let g = entry.group {
                groups.append(g)
            }
        }

        groups.sort { $0.bytes > $1.bytes }
        return (groups, Array(Set(denied)), perCategory)
    }
}
