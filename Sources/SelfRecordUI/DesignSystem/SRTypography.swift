import SwiftUI

// MARK: - 字体层级（design.md §7.2）
//
// 第一版用系统字体（SF 天然支持 Dynamic Type 与中文），Inter 捆绑后置（§9-8）。
// Ely 8 档字阶**不直接搬 pt 数值**（Ely 桌面密度：Base 13 在 iOS 偏小），映射到
// 系统 TextStyle——Dynamic Type 缩放由系统承载（同时规避 @ScaledMetric 宏，§0-2）。
//
// Ely 源字阶（tokens.rs:452-464）：Xs 11 / Sm 12 / Base 13 / Md 14 / Lg 16 /
// Xl 20 / Xxl 24 / Display 32；字重三档 NORMAL / MEDIUM / SEMIBOLD
// （按钮与选中 Tab MEDIUM、对话框标题与选中分段 SEMIBOLD，其余 REGULAR）。
//
// ⚠ 全库统一裁决（design.md §7.2 留给设计系统阶段的决策，在此定型）：
//   **统计数值 = `.srFont(.xxl, .semibold)`**（title2 ≈22pt + semibold 的
//   视觉分量 ≈ Ely 24px 细体；SRStatCard 已按此实现，各界面不得另立档）。

/// Ely 八档字阶 → SwiftUI TextStyle（design.md §7.2 映射表）。
public enum SRTextSize: String, Sendable, CaseIterable {
    /// 11 · 徽标、小标签（badge.rs:118）
    case xs
    /// 12 · 副文本、Tab 文字（tabs.rs:185）
    case sm
    /// 13 · 控件正文默认（按钮/输入框/开关标签）
    case base
    /// 14 · 统计单位、Lg 控件正文（stat.rs:133）
    case md
    /// 16 · 对话框标题（dialog.rs:130）
    case lg
    /// 20 · 大标题
    case xl
    /// 24 · 统计数值默认（stat.rs:93）
    case xxl
    /// 32 · 展示型大数字
    case display

    public var textStyle: Font.TextStyle {
        switch self {
        case .xs: .caption2
        case .sm: .caption
        case .base: .subheadline
        case .md: .callout
        case .lg: .body
        case .xl: .title3
        case .xxl: .title2
        case .display: .largeTitle
        }
    }
}

public extension Font {

    /// Ely 字阶 + 字重（三档：.regular / .medium / .semibold）。
    static func sr(_ size: SRTextSize, _ weight: Font.Weight = .regular) -> Font {
        Font.system(size.textStyle).weight(weight)
    }

    /// 等宽档（数字表格/统计数值对齐；Ely 用 JetBrains Mono，第一版系统等宽，§9-8）。
    static func srMono(_ size: SRTextSize, _ weight: Font.Weight = .regular) -> Font {
        Font.system(size.textStyle, design: .monospaced).weight(weight)
    }
}

public extension View {
    /// `.srFont(.base, .medium)` 等价 `font(.sr(.base, .medium))`。
    func srFont(_ size: SRTextSize, _ weight: Font.Weight = .regular) -> some View {
        font(.sr(size, weight))
    }
}
