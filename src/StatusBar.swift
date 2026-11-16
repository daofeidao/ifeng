import AppKit

/// 把整条菜单栏内容画成一张图。
///
/// 为什么要这么绕：`MenuBarExtra` 的 label 只会渲染一个文本视图
/// （等价于 `Label` 语义 —— 图标钉在最左，其后只取第一个 `Text`，
/// 多个 `Text` / `if` 分支会被静默丢弃）。
/// 想让「网速 → 图标 → 温度 → 转速」这个顺序成立，只能自己排版再交给它一个 `Image`。
///
/// 附带收益：文字用等宽数字 + 定长格式，整张图宽度恒定，
/// 网速每秒跳动时菜单栏不会左右晃。
enum BarImage {

    static func make(net: String?, temp: String, rpm: String?) -> NSImage {
        let bodyFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let netFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        let body: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.black
        ]

        let out = NSMutableAttributedString()

        if let net = net, !net.isEmpty {
            out.append(NSAttributedString(string: net + " ", attributes: [
                .font: netFont,
                .foregroundColor: NSColor.black
            ]))
        }

        if let icon = fanIcon() {
            let att = NSTextAttachment()
            att.image = icon
            att.bounds = CGRect(x: 0,
                                y: (bodyFont.capHeight - icon.size.height) / 2,
                                width: icon.size.width,
                                height: icon.size.height)
            out.append(NSAttributedString(attachment: att))
            out.append(NSAttributedString(string: " ", attributes: body))
        }

        if !temp.isEmpty {
            out.append(NSAttributedString(string: temp, attributes: body))
        }

        if let rpm = rpm, !rpm.isEmpty {
            out.append(NSAttributedString(string: " " + rpm, attributes: body))
        }

        let textSize = out.size()
        let width = ceil(textSize.width) + 2
        let height = ceil(max(textSize.height, 14))

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        out.draw(in: NSRect(x: 1, y: 0, width: textSize.width, height: textSize.height))
        image.unlockFocus()

        // 模板图：由系统按菜单栏明暗自动上色
        image.isTemplate = true
        return image
    }

    private static func fanIcon() -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .regular)
        guard let base = NSImage(systemSymbolName: "fanblades.fill",
                                 accessibilityDescription: "风扇") else { return nil }
        let icon = base.withSymbolConfiguration(cfg) ?? base
        // 转换成模板图，跟着文字一起被系统上色
        icon.isTemplate = true
        return icon
    }
}
