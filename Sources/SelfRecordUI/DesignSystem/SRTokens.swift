import SelfRecordCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Ely 色彩令牌（design.md §7.1）
//
// 实现方式按 design.md §7.1 定型结论：**自研跨平台动态色构造器**，不用 Asset Catalog
// （CLT-only 环境无 actool 管线）——`Color(hex:)` + `Color(light:dark:)` 均为纯 Swift，
// 可 swift build、可对色值做单元断言。
//
// 色值来源（逐值照抄，未凭记忆造值）：
//   - 亮色：reference/ely/src/theme/palette.rs:176-243（Palette::light）
//   - 暗色：reference/ely/src/theme/palette.rs:247-314（Palette::dark）
//   - 高对比度变体：palette.rs:237-243 / :308-314（§1.3）
//   - 图表 8 hue：palette.rs:214-216（亮）/ :285-287（暗）；
//     色盲安全八色 palette.rs:151-165（color_blind_chart）
//   - 文档口径：docs/reference-ely.md §1 两张表 + docs/design.md §7.1 映射表
//
// 差异备注：design.md §7.1 表中 paper/ink 暗色标注「同左」，但源码暗色
// paper = 0xf3f1f0（palette.rs:285 附近）、ink = 0x181613——**以源码真实值为准**。
//
// `selection` token（#3772BB33 / #69A1E84D）按 design.md §7.1 裁决**不映射**：
// SwiftUI 文本选区色系统接管，不可定制。
//
// 原则（§7.1 / §1.5 原则第 4 条）：组件只写语义名，从不写字面色值；
// 彩色只出现在语义色与图表 hue。

public extension Color {

    /// 十六进制色值：`0xRRGGBB` 或带 alpha 的 `0xRRGGBBAA`
    /// （Ely 源码 8 位 hex 透明度即尾字节，如 backdrop 亮 `0x18161352` = 32% α）。
    init(hex: UInt32) {
        let hasAlpha = hex > 0xFF_FFFF
        let a: UInt32 = hasAlpha ? (hex >> 24) & 0xFF : 0xFF
        let r: Double = Double((hex >> 16) & 0xFF) / 255.0
        let g: Double = Double((hex >> 8) & 0xFF) / 255.0
        let b: Double = Double(hex & 0xFF) / 255.0
        let o: Double = Double(a) / 255.0
        self.init(red: r, green: g, blue: b, opacity: o)
    }

    /// Ely 语义色构造：亮/暗双 hex 值，运行时按系统外观解析（iOS/macOS 双平台）。
    /// 必须以原始色值构造 UIColor/NSColor——iOS 没有公开的 Color→UIColor 转换，
    /// 早期 `init(light: Color, dark: Color)` 形态在 UIKit 分支首轮真实编译即报
    /// "cannot convert value of type 'Color' to closure result type 'UIColor'"
    /// （2026-10-06 装好 Xcode 后 xcodebuild 实测，已修复）。
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(srHex: dark) : UIColor(srHex: light)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark ? NSColor(srHex: dark) : NSColor(srHex: light)
        })
        #else
        self = Color(hex: light)
        #endif
    }

    // MARK: 表面四层（§1 原则第 5 条：分层靠表面而非线）

    /// 页面背景（暖白/暖近黑，非纯灰）。
    static let srBackground = Color(light: 0xFCFAF7, dark: 0x131110)
    /// 卡片/输入表面。
    static let srSurface = Color(light: 0xFFFFFF, dark: 0x1B1917)
    /// 凹陷区域（分段轨道/禁用输入）。
    static let srSunken = Color(light: 0xF6F4F1, dark: 0x0E0D0B)
    /// 弹层表面。
    static let srOverlay = Color(light: 0xFFFFFF, dark: 0x201F1D)
    /// 悬停/按压底。
    static let srHover = Color(light: 0xF2F0ED, dark: 0x252422)
    /// 按下底。
    static let srActive = Color(light: 0xE9E7E5, dark: 0x2C2B29)

    // MARK: 边框

    /// 常规 1px 边框。
    static let srBorder = Color(light: 0xE1DFDD, dark: 0x2C2B29)
    /// 输入框/勾选框边框。
    static let srBorderStrong = Color(light: 0xCCCAC8, dark: 0x413F3D)

    // MARK: 文字

    /// 一级文字。
    static let srForeground = Color(light: 0x181613, dark: 0xF3F1F0)
    /// 二级文字。
    static let srForegroundMuted = Color(light: 0x605D5A, dark: 0xAFADAB)
    /// 三级/辅助文字。
    static let srForegroundSubtle = Color(light: 0x696764, dark: 0x94928F)
    /// 禁用文字。
    static let srForegroundDisabled = Color(light: 0xACAAA8, dark: 0x5C5A58)

    // MARK: 主色（墨色反转，非品牌彩色）

    /// 主色：亮色=暖黑墨色，暗色=亮色前景反转（palette.rs §1 要点）。
    static let srAccent = Color(light: 0x181613, dark: 0xF3F1F0)
    /// 主色按压/hover。
    static let srAccentHover = Color(light: 0x302D2B, dark: 0xD9D7D5)
    /// 主色之上的文字。
    static let srOnAccent = Color(light: 0xFCFAF7, dark: 0x131110)

    // MARK: 焦点与链接

    /// 焦点环/聚焦输入边框（不与主色混用，§1.5 原则第 6 条）。
    static let srFocus = Color(light: 0x3772BB, dark: 0x69A1E8)
    /// 链接。
    static let srLink = Color(light: 0x2863AB, dark: 0x7EB1F3)

    // MARK: 语义色（唯一允许的彩色）

    static let srSuccess = Color(light: 0x267B4C, dark: 0x6BBC89)
    static let srWarning = Color(light: 0xA25F12, dark: 0xE8B45E)
    static let srDanger = Color(light: 0xBA3E38, dark: 0xE5756E)
    static let srInfo = Color(light: 0x2E69B2, dark: 0x77ABEC)

    /// 淡底成对色（横幅/图标底；暗色下是「深色化」而非淡化，§1.2 注）。
    static let srSuccessSubtle = Color(light: 0xE7F9EC, dark: 0x182C1F)
    static let srWarningSubtle = Color(light: 0xFEF2DD, dark: 0x342611)
    static let srDangerSubtle = Color(light: 0xFFEFEC, dark: 0x3A1D1B)
    static let srInfoSubtle = Color(light: 0xEBF4FF, dark: 0x19273A)

    // MARK: 遮罩 / 毛玻璃 / 阴影 / 提示

    /// 弹层遮罩（亮 32% α = 尾字节 0x52；暗 50% α = 0x80）。
    static let srBackdrop = Color(light: 0x18161352, dark: 0x00000080)
    /// 毛玻璃底（72% α，两模式同 α）。
    static let srGlass = Color(light: 0xFCFAF7B8, dark: 0x131110B8)
    /// 阴影色（暗色下阴影透明度数倍于亮色，见 srShadow 修饰器）。
    static let srShadowColor = Color(light: 0x181613, dark: 0x000000)
    /// 工具提示底/字（墨色反转）。第一版 Charts 用系统 tooltip，token 留位（§7.1 表）。
    static let srTooltipBackground = Color(light: 0x181613, dark: 0x373533)
    static let srTooltipForeground = Color(light: 0xFCFAF7, dark: 0xF3F1F0)

    // MARK: 打印式语义（与 surface/fg 同值，保留语义名；暗色以源码真实值为准）

    static let srPaper = Color(light: 0xFFFFFF, dark: 0xF3F1F0)
    static let srInk = Color(light: 0x181613, dark: 0x181613)

    // MARK: 高对比度变体（palette.rs:237-243 / :308-314）
    //
    // 使用方式（design.md §7.1）：组件读 @Environment(\.colorSchemeContrast)，
    // == .increased 时换用本组 token（读环境值不是宏，可用）。SRField 已示范接线。

    static let srForegroundMutedHighContrast =
        Color(light: 0x44423F, dark: 0xCFCDCB)
    static let srForegroundSubtleHighContrast =
        Color(light: 0x575552, dark: 0xAFADAB)
    static let srBorderHighContrast =
        Color(light: 0xA6A4A2, dark: 0x6A6966)
    static let srBorderStrongHighContrast =
        Color(light: 0x82807D, dark: 0x858380)
}

// MARK: - 语义严重度（severity.rs:16-42 的固定映射）

/// Severity：实色 `color` 与「安静底」`subtleColor` 成对提供（reference-ely.md §1.5）。
/// SF Symbols 对应 Ely 图标：Info→info / Success→circle-check /
/// Warning→triangle-alert / Danger→circle-alert。
public enum SRSeverity: String, Sendable, CaseIterable {
    case info, success, warning, danger

    public var color: Color {
        switch self {
        case .info: .srInfo
        case .success: .srSuccess
        case .warning: .srWarning
        case .danger: .srDanger
        }
    }

    public var subtleColor: Color {
        switch self {
        case .info: .srInfoSubtle
        case .success: .srSuccessSubtle
        case .warning: .srWarningSubtle
        case .danger: .srDangerSubtle
        }
    }

    public var symbolName: String {
        switch self {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .danger: "exclamationmark.circle"
        }
    }
}

// MARK: - 图表色板（palette.rs:151-165 / :214-216 / :285-287）

/// 图表 8 hue 双模式色板 + neutral 派生档（design.md §7.1 / §4.1）。
/// hue 顺序命名 Blue, Teal, Ochre, Rose, Violet, Green, Rust, Cyan（HUE_NAMES）。
/// `neutral` 非 Ely 源色：取 fg_muted 同值，供「其他」这类无倾向分类使用。
///
/// 为什么按显式 scheme 参数而不是动态色：图表色要求「在各自模式的页面上 ≥3:1」，
/// 显式传 scheme 使取色确定、可测试；组件经 @Environment(\.colorScheme) 注入。
public enum SRChartPalette {

    /// 常规图表色（各模式页面对比度 ≥3:1）。
    public static func hue(_ hue: ChartHue, _ scheme: ColorScheme) -> Color {
        if hue == .neutral {
            return scheme == .dark ? Color(hex: 0xAFADAB) : Color(hex: 0x605D5A)
        }
        let hex: UInt32
        switch (hue, scheme) {
        case (.blue, .light): hex = 0x5182C1
        case (.blue, .dark): hex = 0x79A7E2
        case (.teal, .light): hex = 0x009589
        case (.teal, .dark): hex = 0x4EB9AD
        case (.ochre, .light): hex = 0xAA732B
        case (.ochre, .dark): hex = 0xCD995C
        case (.rose, .light): hex = 0xB8636B
        case (.rose, .dark): hex = 0xDC8A90
        case (.violet, .light): hex = 0x8572BB
        case (.violet, .dark): hex = 0xA998DD
        case (.green, .light): hex = 0x539156
        case (.green, .dark): hex = 0x7CB57D
        case (.rust, .light): hex = 0xB66946
        case (.rust, .dark): hex = 0xD9906F
        case (.cyan, .light): hex = 0x138DB1
        case (.cyan, .dark): hex = 0x56B2D4
        default: hex = 0x605D5A  // 上面已提前返回；非冻结枚举兜底
        }
        return Color(hex: hex)
    }

    /// 色盲安全八色（palette.rs:151-165 color_blind_chart）。第一版不实现全局开关
    /// （design.md §7.1「后置，token 留位」），但取色函数就位，接开关只改调用方。
    public static func colorBlindSafeHue(_ hue: ChartHue, _ scheme: ColorScheme) -> Color {
        if hue == .neutral {
            return scheme == .dark ? Color(hex: 0xAFADAB) : Color(hex: 0x605D5A)
        }
        let hex: UInt32
        switch (hue, scheme) {
        case (.blue, .light): hex = 0x0240B1
        case (.blue, .dark): hex = 0x3471E3
        case (.teal, .light): hex = 0x08A399
        case (.teal, .dark): hex = 0x57B6B2
        case (.ochre, .light): hex = 0xCD8017
        case (.ochre, .dark): hex = 0xF6A537
        case (.rose, .light): hex = 0x844954
        case (.rose, .dark): hex = 0xDE545A
        case (.violet, .light): hex = 0xA276E3
        case (.violet, .dark): hex = 0x695A91
        case (.green, .light): hex = 0x184606
        case (.green, .dark): hex = 0xC4ECB7
        case (.rust, .light): hex = 0xB84F10
        case (.rust, .dark): hex = 0xA93D0E
        case (.cyan, .light): hex = 0x20789D
        case (.cyan, .dark): hex = 0x52DAFE
        default: hex = 0x605D5A  // 上面已提前返回；非冻结枚举兜底
        }
        return Color(hex: hex)
    }
}

// MARK: - 颜色混合（按钮语义色按压态）

public extension Color {

    /// `self·(1−fraction) + other·fraction` 的 RGB 线性混合。
    /// 用途：Ely Button Success/Danger「hover 向 fg 混 14%」（button.rs:39-99）——
    /// 触屏无 hover，用作按压态。运行时按当前外观解析动态色分量。
    static func srBlend(_ from: Color, toward other: Color, fraction: Double) -> Color {
        let f = fraction.clamped(0, 1)
        let a = from.srRGBAComponents
        let b = other.srRGBAComponents
        return Color(
            red: a.0 + (b.0 - a.0) * f,
            green: a.1 + (b.1 - a.1) * f,
            blue: a.2 + (b.2 - a.2) * f,
            opacity: a.3 + (b.3 - a.3) * f
        )
    }

    /// 当前外观下的 RGBA 分量（0…1）。
    var srRGBAComponents: (Double, Double, Double, Double) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let converted = UIColor(self)
        if converted.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (Double(r), Double(g), Double(b), Double(a))
        }
        #elseif canImport(AppKit)
        if let converted = NSColor(self).usingColorSpace(.deviceRGB) {
            return (Double(converted.redComponent), Double(converted.greenComponent),
                    Double(converted.blueComponent), Double(converted.alphaComponent))
        }
        #endif
        return (0, 0, 0, 1)
    }
}

extension Double {
    fileprivate func clamped(_ lo: Double, _ hi: Double) -> Double {
        Swift.min(hi, Swift.max(lo, self))
    }
}

#if canImport(UIKit)
extension UIColor {
    /// `0xRRGGBB` / `0xRRGGBBAA` → UIColor（与 Color(hex:) 同一口径）。
    convenience init(srHex hex: UInt32) {
        let hasAlpha = hex > 0xFF_FFFF
        let a = hasAlpha ? CGFloat((hex >> 24) & 0xFF) / 255.0 : 1.0
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: a
        )
    }
}
#elseif canImport(AppKit)
extension NSColor {
    /// `0xRRGGBB` / `0xRRGGBBAA` → NSColor（与 Color(hex:) 同一口径）。
    convenience init(srHex hex: UInt32) {
        let hasAlpha = hex > 0xFF_FFFF
        let a = hasAlpha ? CGFloat((hex >> 24) & 0xFF) / 255.0 : 1.0
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: a
        )
    }
}
#endif
