import Charts
import SelfRecordCore
import SwiftUI

// MARK: - 图表度量（Ely chart.rs:7-43）

/// 全部图表度量集中于此（chart.rs:30-43 逐值照抄）。
public enum SRChartMetrics {
    /// 整高（图例与轴含）。
    public static let height: CGFloat = 280
    /// 值域 gutter（值标签旁位）。
    public static let gutter: CGFloat = 48
    /// 类目脚（类目标签下位）。
    public static let foot: CGFloat = 28
    /// 安全区 inset（点/描边保持完整）。
    public static let inset: CGFloat = 8
    /// 类目标签沿轴最小间距，更近则抽稀。
    public static let minLabelSpacing: CGFloat = 64
    /// 线宽。
    public static let strokeWidth: CGFloat = 2
    /// 网格/坐标发丝线。
    public static let hairline: CGFloat = 1
    /// 饼图悬停切片外抬（留位，Swift Charts 无此钩子）。
    public static let pieLift: CGFloat = 6
}

// MARK: - SRChartContainer（design.md §7.4）

/// Swift Charts 容器：统一图表高度与轴样式，图表依赖单点收口（§11 风险 9）。
/// donut/堆叠柱/横条/折线全走 Swift Charts（§7.4）；取色用
/// `SRChartPalette.hue(_:scheme:)`（暗色自动切由 colorScheme 驱动）。
///
/// 用法：
/// ```
/// SRChartContainer {
///     Chart(series) { item in
///         LineMark(x: .value("日", item.day), y: .value("分", item.value))
///             .foregroundStyle(SRChartPalette.hue(.blue, scheme))
///             .lineStyle(StrokeStyle(lineWidth: SRChartMetrics.strokeWidth))
///     }
///     .srYAxisGrid()
/// }
/// ```
public struct SRChartContainer<Content: View>: View {

    let height: CGFloat
    let content: Content

    public init(height: CGFloat = SRChartMetrics.height, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
    }

    public var body: some View {
        content
            .frame(height: height)
            .padding(.vertical, SRChartMetrics.inset / 2)
    }
}

public extension Chart {
    /// Y 轴发丝网格（1px srBorder）+ 值标签（Sm fg_muted）——Ely 图表轴规格
    /// （chart.rs hairline、§5-13）。x 轴需要同款时调用方再挂 `.chartXAxis`。
    func srYAxisGrid() -> some View {
        chartYAxis {
            AxisMarks { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: SRChartMetrics.hairline))
                    .foregroundStyle(Color.srBorder)
                AxisValueLabel()
                    .font(.sr(.sm))
                    .foregroundStyle(Color.srForegroundMuted)
            }
        }
    }

    /// x 轴类目标签（Sm fg_muted；标签抽稀交给 Charts 自动，
    /// minLabelSpacing=64 作为调用方自定义 `.stride` 时的参考常量）。
    func srXAxisCategories() -> some View {
        chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(.sr(.sm))
                    .foregroundStyle(Color.srForegroundMuted)
            }
        }
    }
}

// MARK: - 图表取色修饰器

/// 非 Charts 场景（图例点/自定义条）按 hue 取色；Charts mark 内直接调
/// `SRChartPalette.hue(_:scheme:)`。
public extension View {
    func srChartHue(_ hue: ChartHue) -> some View {
        modifier(SRHueModifier(hue: hue))
    }
}

struct SRHueModifier: ViewModifier {
    let hue: ChartHue
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.foregroundStyle(SRChartPalette.hue(hue, scheme))
    }
}
