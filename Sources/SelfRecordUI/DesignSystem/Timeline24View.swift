import SelfRecordCore
import SwiftUI

// MARK: - Timeline24View（design.md §6 TimeView / §7.4 Chart 行）

/// 24h 一维时间轴（Swift Charts 无此图表，Canvas 自绘，§7.4）：
/// sunken 轨道 + 分类段（ChartHue 取色）+ **睡眠段叠加深色**（fg 半透明墨）+
/// 6h 间隔发丝刻度 + 当前时刻指示线（§6「自定义一维条」全部要素）。
///
/// 组件无状态：`nowMinutes` 由调用方驱动（如 TimelineView(.periodic) 重算），
/// 跨午夜段请先拆分（本组件按 0..<1440 截断绘制）。
public struct SRTimeSegment: Identifiable, Sendable {

    /// 段填充：图表 hue（时间分类）或睡眠叠加（墨色半透明）。
    public enum Fill: Sendable {
        case hue(ChartHue)
        case sleep
    }

    public var id: UUID
    /// 起始分钟（0…1440，越界段被裁剪/丢弃）。
    public var start: Double
    /// 结束分钟（>start 才绘制）。
    public var end: Double
    public var fill: Fill

    public init(id: UUID = UUID(), start: Double, end: Double, fill: Fill) {
        self.id = id
        self.start = start
        self.end = end
        self.fill = fill
    }
}

public struct Timeline24View: View {

    let segments: [SRTimeSegment]
    /// 当前时刻（分钟，0…1440）；nil 不画指示线。
    let nowMinutes: Double?
    let trackHeight: CGFloat
    let showsHourLabels: Bool
    let accessibilitySummary: String

    @Environment(\.colorScheme) private var scheme

    public init(
        segments: [SRTimeSegment],
        nowMinutes: Double? = nil,
        trackHeight: CGFloat = 28,
        showsHourLabels: Bool = true,
        accessibilitySummary: String = "24 小时时间轴"
    ) {
        self.segments = segments
        self.nowMinutes = nowMinutes
        self.trackHeight = trackHeight
        self.showsHourLabels = showsHourLabels
        self.accessibilitySummary = accessibilitySummary
    }

    public var body: some View {
        VStack(spacing: SRSpacing.xs) {
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(height: trackHeight)
            if showsHourLabels {
                hourLabels
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let track = CGRect(origin: .zero, size: size)
        let trackPath = Path(roundedRect: track, cornerRadius: SRRadius.md, style: .continuous)

        // 轨道
        context.fill(trackPath, with: .color(Color.srSunken))

        // 6h 发丝刻度（跳过首尾，首尾由边框承担）
        for hour in [6.0, 12.0, 18.0] {
            let x = size.width * hour / 24
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: 0))
            tick.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(tick, with: .color(Color.srBorder), lineWidth: SRChartMetrics.hairline)
        }

        // 分类段（后画的在上；睡眠叠加属墨色，应压在彩色段上——按传入顺序绘制）
        let inset: CGFloat = 2
        let segmentRect = track.insetBy(dx: inset, dy: inset)
        for segment in segments {
            let clamped = Swift.min(1440, Swift.max(0, segment.start))..<Swift.min(1440, Swift.max(0, segment.end))
            guard clamped.upperBound - clamped.lowerBound > 0 else { continue }
            let x0 = segmentRect.minX + segmentRect.width * clamped.lowerBound / 1440
            let x1 = segmentRect.minX + segmentRect.width * clamped.upperBound / 1440
            let rect = CGRect(x: x0, y: segmentRect.minY, width: x1 - x0, height: segmentRect.height)
            let color: Color
            switch segment.fill {
            case .hue(let hue):
                color = SRChartPalette.hue(hue, scheme)
            case .sleep:
                // 「睡眠段叠加深色」：fg 半透明墨，双模式语义一致（亮=压暗、暗=提亮轮廓）
                color = Color.srForeground.opacity(0.45)
            }
            context.fill(
                Path(roundedRect: rect, cornerRadius: 2, style: .continuous),
                with: .color(color)
            )
        }

        // 边框（1px，画最后盖住段边缘）
        context.stroke(trackPath, with: .color(Color.srBorder), lineWidth: SRChartMetrics.hairline)

        // 当前时刻指示线
        if let now = nowMinutes, (0...1440).contains(now) {
            let x = size.width * now / 1440
            var indicator = Path()
            indicator.move(to: CGPoint(x: x, y: 0))
            indicator.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(indicator, with: .color(Color.srForeground), lineWidth: 1.5)
            let dot = CGRect(x: x - 2, y: -1, width: 4, height: 4)
            context.fill(Path(ellipseIn: dot), with: .color(Color.srForeground))
        }
    }

    private var hourLabels: some View {
        HStack(spacing: 0) {
            ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                Text(String(format: "%02d", hour))
                    .font(.srMono(.xs))
                    .foregroundStyle(Color.srForegroundSubtle)
                    .frame(
                        maxWidth: .infinity,
                        alignment: hour == 0 ? .leading : (hour == 24 ? .trailing : .center)
                    )
            }
        }
        .accessibilityHidden(true)
    }
}
