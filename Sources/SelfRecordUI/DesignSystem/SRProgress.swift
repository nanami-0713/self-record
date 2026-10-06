import SwiftUI

// MARK: - SRProgressBar / SRProgressRing（Ely tokens.rs:180-198）

/// 进度条：粗细默认 2（progress_thickness，tokens.rs:191-198）、sunken 轨道 +
/// 语义色填充胶囊。BudgetView 日/周预算进度、TodayView 预算卡用（§6）；
/// 超支场景调用方传 `tint: .srDanger`。
public struct SRProgressBar: View {

    /// 0…1，越界自动收敛。
    let progress: Double
    let tint: Color
    let trackColor: Color
    let thickness: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        progress: Double,
        tint: Color = .srAccent,
        trackColor: Color = .srSunken,
        thickness: CGFloat = 2
    ) {
        self.progress = progress
        self.tint = tint
        self.trackColor = trackColor
        self.thickness = thickness
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, geo.size.width * clamped))
            }
        }
        .frame(height: thickness)
        .animation(SRMotion.resolve(SRMotion.base, reduceMotion: reduceMotion), value: clamped)
        .accessibilityElement()
        .accessibilityLabel("进度")
        .accessibilityValue("\(Int((clamped * 100).rounded()))%")
    }

    private var clamped: Double {
        Swift.min(1, Swift.max(0, progress))
    }
}

/// 进度环：直径默认 48（progress_ring，tokens.rs:191-198「room for a percent
/// inside」），中心可放百分比/数值（DietView 宏量环，§6）。
public struct SRProgressRing<Center: View>: View {

    /// 0…1，越界自动收敛。
    let progress: Double
    let tint: Color
    let trackColor: Color
    let lineWidth: CGFloat
    let diameter: CGFloat
    let center: Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        progress: Double,
        tint: Color = .srAccent,
        trackColor: Color = .srSunken,
        lineWidth: CGFloat = 4,
        diameter: CGFloat = 48,
        @ViewBuilder center: () -> Center = { EmptyView() }
    ) {
        self.progress = progress
        self.tint = tint
        self.trackColor = trackColor
        self.lineWidth = lineWidth
        self.diameter = diameter
        self.center = center()
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))       // 12 点起笔
            center
        }
        .frame(width: diameter, height: diameter)
        .animation(SRMotion.resolve(SRMotion.base, reduceMotion: reduceMotion), value: clamped)
        .accessibilityElement()
        .accessibilityLabel("进度")
        .accessibilityValue("\(Int((clamped * 100).rounded()))%")
    }

    private var clamped: Double {
        Swift.min(1, Swift.max(0, progress))
    }
}

public extension SRProgressRing where Center == EmptyView {
    init(
        progress: Double,
        tint: Color = .srAccent,
        trackColor: Color = .srSunken,
        lineWidth: CGFloat = 4,
        diameter: CGFloat = 48
    ) {
        self.init(
            progress: progress, tint: tint, trackColor: trackColor,
            lineWidth: lineWidth, diameter: diameter
        ) { EmptyView() }
    }
}
