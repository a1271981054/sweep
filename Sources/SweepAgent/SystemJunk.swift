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
        limit: Int
    ) async -> (groups: [ScanGroup], denied: [URL], perCategory: [(ScanCategory, [FileItem])]) {
        var groups: [ScanGroup] = []
        var denied: [URL] = []
        var perCategory: [(ScanCategory, [FileItem])] = []

        for category in categories {
            let result = await walker.scan(targets: category.targets)
            denied.append(contentsOf: result.deniedPaths)
            perCategory.append((category.scanCategory, result.items))

            let bytes = FileWalker.leafBytes(of: result.items)
            guard !result.items.isEmpty || bytes > 0 else { continue }
            groups.append(
                ScanGroup(
                    category: category.scanCategory.rawValue,
                    label: CategoryLabels.label(category.scanCategory),
                    items: result.items.count,
                    bytes: bytes,
                    top: Util.entries(from: result.items, limit: limit, category: category.scanCategory.rawValue)
                )
            )
        }

        groups.sort { $0.bytes > $1.bytes }
        return (groups, Array(Set(denied)), perCategory)
    }
}
