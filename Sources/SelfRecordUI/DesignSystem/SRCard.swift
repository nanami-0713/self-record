import SwiftUI

// MARK: - SRCard（design.md §7.4「卡片」；Ely 表面分层 §1 原则第 5 条）

/// 卡片海拔档（独立类型：嵌套在泛型 SRCard 内无法被裸引用）。
public enum SRCardElevation: String, Sendable, CaseIterable {
    /// 无阴影（列表内嵌卡）。
    case flat
    /// Raised（浮起的分组卡）。
    case raised
    /// Floating（脱离页面的强调卡）。
    case floating
}

/// 通用卡片：surface 底 + 1px srBorder + 圆角 Lg 8 + 可选三档阴影。
/// TodayView「五张域卡片」、SRStatCard 均以它为底（§6）。
/// 卡片规格对齐 Ely 卡片族（Toast surface+border+Lg 8+Floating；Dialog
/// overlay+border+Xl 12+Modal）——弹层用 sheet/alert 原生（§7.4），本组件
/// 只服务页内静态卡。
public struct SRCard<Content: View>: View {

    let padding: CGFloat
    let elevation: SRCardElevation
    let content: Content

    public init(
        padding: CGFloat = SRSpacing.lg,
        elevation: SRCardElevation = .flat,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.elevation = elevation
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Color.srSurface)
            .clipShape(RoundedRectangle(cornerRadius: SRRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SRRadius.lg, style: .continuous)
                    .stroke(Color.srBorder, lineWidth: 1)
            )
            .srShadow(shadowLevel)
    }

    private var shadowLevel: SRShadowLevel? {
        switch elevation {
        case .flat: nil
        case .raised: .raised
        case .floating: .floating
        }
    }
}
