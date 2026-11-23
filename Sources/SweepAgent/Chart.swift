import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import MacCleanKit

/// Renders scans and clean plans as PNGs so any client — not just DSH — can show
/// a picture instead of a wall of text. An image carries its own background:
/// a transparent PNG with dark text disappears on a dark theme, so every chart
/// is drawn as a dark card with light text, which reads the same either way.
public enum ChartRenderer {
    struct Slice {
        let label: String
        let bytes: UInt64
        let count: Int
    }

    static let palette: [CGColor] = [
        CGColor(srgbRed: 0.44, green: 0.58, blue: 0.71, alpha: 1),
        CGColor(srgbRed: 0.88, green: 0.64, blue: 0.36, alpha: 1),
        CGColor(srgbRed: 0.52, green: 0.72, blue: 0.64, alpha: 1),
        CGColor(srgbRed: 0.80, green: 0.52, blue: 0.52, alpha: 1),
        CGColor(srgbRed: 0.65, green: 0.59, blue: 0.80, alpha: 1),
        CGColor(srgbRed: 0.48, green: 0.66, blue: 0.76, alpha: 1),
    ]

    static let cardColor = CGColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)
    static let primary = CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
    static let secondary = CGColor(srgbRed: 0.66, green: 0.69, blue: 0.73, alpha: 1)

    // MARK: - Canvas

    private static func makeContext(width: Double, height: Double) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: Int(width), height: Int(height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "sweep.chart", code: 1) }

        context.setFillColor(cardColor)
        context.addPath(CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
            cornerWidth: 18, cornerHeight: 18, transform: nil
        ))
        context.fillPath()
        return context
    }

    private static func text(
        _ context: CGContext,
        _ string: String,
        x: Double, y: Double,
        size: Double,
        color: CGColor,
        weight: String = "Regular",
        maxWidth: Double? = nil
    ) {
        let font = CTFontCreateWithName("PingFangSC-\(weight)" as CFString, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        guard let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)
        else { return }
        var line = CTLineCreateWithAttributedString(attributed)

        if let maxWidth {
            let ellipsis = CTLineCreateWithAttributedString(
                CFAttributedStringCreate(nil, "…" as CFString, attributes as CFDictionary)!
            )
            line = CTLineCreateTruncatedLine(line, maxWidth, .end, ellipsis) ?? line
        }

        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }

    private static func write(_ context: CGContext, to output: URL) throws {
        guard let image = context.makeImage() else {
            throw NSError(domain: "sweep.chart", code: 2)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw NSError(domain: "sweep.chart", code: 3) }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "sweep.chart", code: 4)
        }
    }

    // MARK: - Scan summary

    public static func render(snapshot: URL, output: URL, top: Int = 8) throws {
        let data = try Data(contentsOf: snapshot)
        let entries = try JSONDecoder().decode([ScanEntry].self, from: data)

        var totals: [String: (bytes: UInt64, count: Int)] = [:]
        for entry in entries {
            let key = entry.category ?? "unknown"
            var current = totals[key] ?? (0, 0)
            current.bytes &+= entry.bytes
            current.count += 1
            totals[key] = current
        }

        let slices = Array(
            totals
                .map { Slice(label: CategoryLabels.label($0.key), bytes: $0.value.bytes, count: $0.value.count) }
                .sorted { $0.bytes > $1.bytes }
                .prefix(top)
        )

        let totalBytes = slices.reduce(0) { $0 &+ $1.bytes }
        let totalCount = slices.reduce(0) { $0 + $1.count }
        let maxBytes = slices.map(\.bytes).max() ?? 1

        let width = 1000.0
        let rowHeight = 56.0
        let height = 150.0 + Double(slices.count) * rowHeight + 40.0
        let context = try makeContext(width: width, height: height)

        text(context, "可清理空间 \(Util.bytes(totalBytes))", x: 40, y: height - 62, size: 34, color: primary, weight: "Semibold")
        text(context, "\(totalCount) 项候选 · 按类别汇总", x: 40, y: height - 96, size: 20, color: secondary)

        let barLeft = 300.0
        let barRight = width - 190.0
        let barWidth = barRight - barLeft

        var y = height - 165.0
        for (index, slice) in slices.enumerated() {
            let fraction = Double(slice.bytes) / Double(max(maxBytes, 1))
            let color = palette[index % palette.count]

            text(context, slice.label, x: 40, y: y + 6, size: 22, color: primary, maxWidth: 240)

            let track = CGRect(x: barLeft, y: y + 4, width: barWidth, height: 22)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
            context.addPath(CGPath(roundedRect: track, cornerWidth: 11, cornerHeight: 11, transform: nil))
            context.fillPath()

            let fill = CGRect(x: barLeft, y: y + 4, width: max(barWidth * fraction, 6), height: 22)
            context.setFillColor(color)
            context.addPath(CGPath(roundedRect: fill, cornerWidth: 11, cornerHeight: 11, transform: nil))
            context.fillPath()

            text(context, Util.bytes(slice.bytes), x: barRight + 22, y: y + 6, size: 20, color: primary)
            text(context, "\(slice.count) 项", x: barRight + 22, y: y - 16, size: 16, color: secondary)

            y -= rowHeight
        }

        text(context, "sweep · \(snapshot.lastPathComponent)", x: 40, y: 24, size: 15, color: secondary)
        try write(context, to: output)
    }

    // MARK: - Clean plan

    /// The picture of what `apply_clean` is about to move to the Trash: every
    /// path, its size, the total, and the digest the approval is bound to.
    public static func renderPlan(_ plan: CleanPlan, output: URL, maxRows: Int = 14) throws {
        let rows = plan.entries.sorted { $0.bytes > $1.bytes }
        let shown = Array(rows.prefix(maxRows))
        let hidden = rows.count - shown.count

        let width = 1000.0
        let rowHeight = 46.0
        let height = 210.0 + Double(shown.count + (hidden > 0 ? 1 : 0)) * rowHeight + 80.0
        let context = try makeContext(width: width, height: height)

        text(context, "待清理 \(Util.bytes(plan.totalBytes))", x: 40, y: height - 62, size: 34, color: primary, weight: "Semibold")
        text(context, "\(plan.entries.count) 项 · 计划 \(plan.id) · 移入废纸篓，可撤销",
             x: 40, y: height - 96, size: 20, color: secondary)

        let digest = String(plan.digest.prefix(16))
        text(context, "digest \(digest)…", x: 40, y: height - 124, size: 17, color: secondary)

        var y = height - 176.0
        for entry in shown {
            let home = NSHomeDirectory()
            let path = entry.path.hasPrefix(home) ? "~" + entry.path.dropFirst(home.count) : entry.path
            let category = entry.category.map { CategoryLabels.label($0) } ?? ""

            text(context, Util.bytes(entry.bytes), x: 40, y: y + 4, size: 20, color: primary, weight: "Medium")
            text(context, String(path), x: 190, y: y + 4, size: 19, color: primary, maxWidth: 640)
            text(context, category, x: width - 150, y: y + 4, size: 16, color: secondary)

            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08))
            context.fill(CGRect(x: 40, y: y - 12, width: width - 80, height: 1))
            y -= rowHeight
        }

        if hidden > 0 {
            text(context, "… 另有 \(hidden) 项", x: 190, y: y + 4, size: 18, color: secondary)
        }

        text(context, "确认后执行 apply_clean（带上面这串 digest）", x: 40, y: 30, size: 17, color: secondary)
        try write(context, to: output)
    }

    // MARK: - Operation result

    /// The picture to show after `apply_clean`: what moved, what failed, and the
    /// operation id that undoes it.
    public static func renderOperation(_ record: OperationRecord, output: URL, maxRows: Int = 12) throws {
        let rows = record.items.sorted { $0.bytes > $1.bytes }
        let shown = Array(rows.prefix(maxRows))
        let hidden = rows.count - shown.count

        let width = 1000.0
        let rowHeight = 46.0
        let height = 210.0 + Double(shown.count + (hidden > 0 ? 1 : 0)) * rowHeight + 90.0
        let context = try makeContext(width: width, height: height)

        let title = record.failCount == 0
            ? "已清理 \(Util.bytes(record.bytes))"
            : "已清理 \(Util.bytes(record.bytes)) · \(record.failCount) 项跳过"
        text(context, title, x: 40, y: height - 62, size: 34, color: primary, weight: "Semibold")
        text(context, "\(record.okCount) 项移入废纸篓 · 操作 \(record.id) · 模式 \(record.mode)",
             x: 40, y: height - 96, size: 20, color: secondary)

        var y = height - 168.0
        for item in shown {
            let home = NSHomeDirectory()
            let path = item.path.hasPrefix(home) ? "~" + item.path.dropFirst(home.count) : item.path
            let mark = item.ok ? "✓" : "✗"
            let markColor = item.ok
                ? CGColor(srgbRed: 0.52, green: 0.72, blue: 0.64, alpha: 1)
                : CGColor(srgbRed: 0.85, green: 0.55, blue: 0.45, alpha: 1)

            text(context, mark, x: 40, y: y + 4, size: 20, color: markColor, weight: "Medium")
            text(context, Util.bytes(item.bytes), x: 78, y: y + 4, size: 19, color: primary, weight: "Medium")
            text(context, String(path), x: 210, y: y + 4, size: 18, color: item.ok ? primary : secondary, maxWidth: 740)

            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08))
            context.fill(CGRect(x: 40, y: y - 12, width: width - 80, height: 1))
            y -= rowHeight
        }

        if hidden > 0 {
            text(context, "… 另有 \(hidden) 项", x: 78, y: y + 4, size: 18, color: secondary)
        }

        text(context, "撤销：restore_clean operation_id \(record.id)   ·   清空废纸篓后不再可撤销",
             x: 40, y: 30, size: 17, color: secondary)
        try write(context, to: output)
    }

    // MARK: - Disk gauge

    public static func renderDisk(total: UInt64, available: UInt64, output: URL) throws {
        let width = 1000.0, height = 360.0
        let context = try makeContext(width: width, height: height)
        let used = total > available ? total - available : 0
        let fraction = total > 0 ? Double(used) / Double(total) : 0

        text(context, "磁盘", x: 40, y: height - 62, size: 26, color: secondary)
        text(context, Util.bytes(available) + " 可用", x: 40, y: height - 118, size: 46, color: primary, weight: "Semibold")
        text(context, "共 \(Util.bytes(total)) · 已用 \(Util.bytes(used)) · \(Int(fraction * 100))%",
             x: 40, y: height - 156, size: 21, color: secondary)

        let barLeft = 40.0, barWidth = width - 80.0
        let track = CGRect(x: barLeft, y: 150, width: barWidth, height: 26)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
        context.addPath(CGPath(roundedRect: track, cornerWidth: 13, cornerHeight: 13, transform: nil))
        context.fillPath()

        let fill = CGRect(x: barLeft, y: 150, width: max(barWidth * fraction, 8), height: 26)
        context.setFillColor(fraction > 0.9
            ? CGColor(srgbRed: 0.85, green: 0.55, blue: 0.45, alpha: 1)
            : palette[0])
        context.addPath(CGPath(roundedRect: fill, cornerWidth: 13, cornerHeight: 13, transform: nil))
        context.fillPath()

        text(context, "sweep · /System/Volumes/Data", x: 40, y: 40, size: 15, color: secondary)
        try write(context, to: output)
    }

    // MARK: - Status

    public static func renderStatus(mode: String, fullDiskAccess: Bool, helperRunning: Bool, output: URL) throws {
        let width = 1000.0, height = 380.0
        let context = try makeContext(width: width, height: height)
        text(context, "sweep 状态", x: 40, y: height - 62, size: 32, color: primary, weight: "Semibold")

        let rows: [(String, String, Bool)] = [
            ("自主度", mode, mode != "readonly"),
            ("完全磁盘访问", fullDiskAccess ? "已授权" : "未授权 · 邮件/Safari/iOS 备份会被跳过", fullDiskAccess),
            ("权限 helper", helperRunning ? "运行中 · http://127.0.0.1:47901" : "未运行 · 执行 sweep helper-install", helperRunning),
        ]

        var y = height - 130.0
        for (label, value, good) in rows {
            text(context, label, x: 40, y: y, size: 21, color: secondary)
            text(context, value, x: 250, y: y, size: 21,
                 color: good ? CGColor(srgbRed: 0.52, green: 0.72, blue: 0.64, alpha: 1)
                             : CGColor(srgbRed: 0.85, green: 0.55, blue: 0.45, alpha: 1),
                 maxWidth: 700)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08))
            context.fill(CGRect(x: 40, y: y - 14, width: width - 80, height: 1))
            y -= 62
        }

        text(context, fullDiskAccess ? "" : "授权：系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 添加 Sweep Helper.app",
             x: 40, y: 44, size: 16, color: secondary, maxWidth: 920)
        try write(context, to: output)
    }

    // MARK: - Operations

    public static func renderOperations(_ records: [OperationRecord], output: URL) throws {
        let shown = Array(records.suffix(10).reversed())
        let width = 1000.0, rowHeight = 46.0
        let height = 170.0 + Double(max(shown.count, 1)) * rowHeight + 60.0
        let context = try makeContext(width: width, height: height)

        let totalBytes = shown.reduce(UInt64(0)) { $0 &+ $1.bytes }
        text(context, "清理记录", x: 40, y: height - 62, size: 32, color: primary, weight: "Semibold")
        text(context, "\(shown.count) 次操作 · 合计 \(Util.bytes(totalBytes)) · 均可用 restore_clean 还原",
             x: 40, y: height - 96, size: 20, color: secondary)

        var y = height - 150.0
        if shown.isEmpty {
            text(context, "还没有清理记录", x: 40, y: y, size: 21, color: secondary)
        }
        for record in shown {
            text(context, record.id, x: 40, y: y, size: 20, color: primary, weight: "Medium")
            text(context, "\(record.okCount) 项" + (record.failCount > 0 ? " · \(record.failCount) 跳过" : ""),
                 x: 200, y: y, size: 19, color: secondary)
            text(context, Util.bytes(record.bytes), x: 420, y: y, size: 20, color: primary)
            text(context, record.mode, x: 560, y: y, size: 17, color: secondary)
            text(context, String(record.createdAt.prefix(16)).replacingOccurrences(of: "T", with: " "),
                 x: 700, y: y, size: 17, color: secondary)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08))
            context.fill(CGRect(x: 40, y: y - 12, width: width - 80, height: 1))
            y -= rowHeight
        }

        text(context, "撤销：sweep restore --op <id>   ·   MCP: restore_clean", x: 40, y: 30, size: 16, color: secondary)
        try write(context, to: output)
    }

    // MARK: - Entry list

    /// Large files, old files and duplicates are a list of paths, not a
    /// category breakdown, so they get their own view.
    public static func renderEntries(
        snapshot: URL,
        title: String,
        output: URL,
        maxRows: Int = 14,
        subtitle: String? = nil
    ) throws {
        let data = try Data(contentsOf: snapshot)
        let entries = try JSONDecoder().decode([ScanEntry].self, from: data)
            .sorted { $0.bytes > $1.bytes }
        let shown = Array(entries.prefix(maxRows))
        let hidden = entries.count - shown.count
        let total = entries.reduce(UInt64(0)) { $0 &+ $1.bytes }

        let width = 1000.0, rowHeight = 46.0
        let height = 200.0 + Double(shown.count + (hidden > 0 ? 1 : 0)) * rowHeight + 70.0
        let context = try makeContext(width: width, height: height)

        text(context, "\(title) \(Util.bytes(total))", x: 40, y: height - 62, size: 32, color: primary, weight: "Semibold")
        text(context, subtitle ?? "\(entries.count) 项 · 按体积排序", x: 40, y: height - 96, size: 20, color: secondary)

        var y = height - 162.0
        for entry in shown {
            let home = NSHomeDirectory()
            let path = entry.path.hasPrefix(home) ? "~" + entry.path.dropFirst(home.count) : entry.path
            text(context, Util.bytes(entry.bytes), x: 40, y: y + 4, size: 19, color: primary, weight: "Medium")
            text(context, String(path), x: 190, y: y + 4, size: 18, color: primary, maxWidth: 760)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08))
            context.fill(CGRect(x: 40, y: y - 12, width: width - 80, height: 1))
            y -= rowHeight
        }
        if hidden > 0 {
            text(context, "… 另有 \(hidden) 项", x: 190, y: y + 4, size: 18, color: secondary)
        }

        text(context, "这些都是你自己的文件，逐项确认后再处理 · sweep", x: 40, y: 30, size: 16, color: secondary)
        try write(context, to: output)
    }
}
