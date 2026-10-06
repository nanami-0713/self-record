import SwiftUI

// MARK: - SRStatCard（design.md §7.4 · Ely stat.rs:13-151）

/// 统计卡：标签 Sm fg_muted 在上（:126）；数值 Xxl（全库统一 `.srFont(.xxl, .semibold)`，
/// 见 SRTypography 头注裁决）+ `contentTransition(.numericText())` 数值滚动
/// （AnimatedNumber 语义，§2 排版）；前缀/后缀 Md fg_muted 与数值**基线对齐**
/// （:133、:126-151）；趋势 = Trending 图标 + 文本，**好方向 success、坏方向
/// danger、不动 fg_muted**，成本类可配 downIsGood（:13-15、:44-67）。
public struct SRStatCard: View {

    public enum TrendDirection: String, Sendable {
        case up, down, flat
    }

    public struct Trend: Sendable, Equatable {
        public var direction: TrendDirection
        /// 展示文本（如 "+12.5%"）。
        public var text: String
        /// 成本类指标：下降才是好方向（stat.rs down_is_good）。
        public var downIsGood: Bool

        public init(direction: TrendDirection, text: String, downIsGood: Bool = false) {
            self.direction = direction
            self.text = text
            self.downIsGood = downIsGood
        }
    }

    let label: String
    let value: String
    let prefix: String
    let suffix: String
    let trend: Trend?
    let elevation: SRCardElevation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        label: String,
        value: String,
        prefix: String = "",
        suffix: String = "",
        trend: Trend? = nil,
        elevation: SRCardElevation = .flat
    ) {
        self.label = label
        self.value = value
        self.prefix = prefix
        self.suffix = suffix
        self.trend = trend
        self.elevation = elevation
    }

    public var body: some View {
        SRCard(elevation: elevation) {
            VStack(alignment: .leading, spacing: SRSpacing.xs) {
                Text(label)
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
                HStack(alignment: .firstTextBaseline, spacing: SRSpacing.xs) {
                    if !prefix.isEmpty {
                        Text(prefix)
                            .srFont(.md)
                            .foregroundStyle(Color.srForegroundMuted)
                    }
                    Text(value)
                        .srFont(.xxl, .semibold)
                        .monospacedDigit()
                        .foregroundStyle(Color.srForeground)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : SRMotion.base, value: value)
                    if !suffix.isEmpty {
                        Text(suffix)
                            .srFont(.md)
                            .foregroundStyle(Color.srForegroundMuted)
                    }
                }
                if let trend {
                    trendView(trend)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func trendView(_ trend: Trend) -> some View {
        let isGood = trend.direction != .flat
            && trend.direction == (trend.downIsGood ? .down : .up)
        let color: Color = {
            switch trend.direction {
            case .flat: .srForegroundMuted
            case .up, .down: isGood ? .srSuccess : .srDanger
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: trend.direction.symbolName)
                .font(.sr(.xs))
                .foregroundStyle(color)
            Text(trend.text)
                .srFont(.sm, .medium)
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .accessibilityLabel("趋势 \(trend.text)")
    }
}

extension SRStatCard.TrendDirection {
    var symbolName: String {
        switch self {
        case .up: "arrow.trending.up"
        case .down: "arrow.trending.down"
        case .flat: "minus"
        }
    }
}
