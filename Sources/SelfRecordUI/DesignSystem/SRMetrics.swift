import SwiftUI

// MARK: - 度量与动效令牌（design.md §7.3）
//
// 源值：reference/ely/src/theme/tokens.rs（间距/圆角/控件高/阴影）与
// reference/ely/src/motion/curve.rs（时长/缓动/弹簧）；文档口径
// docs/design.md §7.3、docs/reference-ely.md §3/§4。

/// 间距阶梯（Ely gap_1/2/3/4/5/6 = 4/8/12/16/20/24）。
public enum SRSpacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 24
}

/// 圆角阶梯（tokens.rs:466-474：Sm 4 / Md 6 / Lg 8 / Xl 12）。
public enum SRRadius {
    public static let sm: CGFloat = 4
    public static let md: CGFloat = 6
    public static let lg: CGFloat = 8
    public static let xl: CGFloat = 12
}

/// 控件视觉高度（tokens.rs:83-108：Sm 24 / Md 28 / Lg 32；iOS 取 28/32 两档，
/// design.md §7.3）。水平内边距同源（24→8 / 28→12 / 32→16）。
///
/// ⚠ iOS 触控目标 ≥44pt：视觉 28/32 的控件必须用 `.contentShape` +
/// `frame(minWidth: 44, minHeight: 44)` 撑出最小 hit 区（§7.3 注），
/// SR 组件已内置，界面层不必重复。
public enum SRControlSize: String, Sendable, CaseIterable {
    /// 视觉高 28（Ely Md）。
    case sm
    /// 视觉高 32（Ely Lg）。
    case md

    public var height: CGFloat {
        switch self {
        case .sm: 28
        case .md: 32
        }
    }

    public var horizontalPadding: CGFloat {
        switch self {
        case .sm: SRSpacing.md   // 12
        case .md: SRSpacing.lg   // 16
        }
    }
}

/// 动效三档 + 阻尼弹簧（curve.rs:7-10、:44-51）。
/// 无障碍（curve.rs:19-25）：reduced_motion 时一切时长压为 1ms——用
/// `SRMotion.resolve(_:reduceMotion:)` 统一替换（读环境值不是宏，可用）。
public enum SRMotion {
    /// FAST 120ms · ease_out · 进场。
    public static let fast = Animation.easeOut(duration: 0.12)
    /// BASE 200ms · ease_in_out · 对称过渡。
    public static let base = Animation.easeInOut(duration: 0.2)
    /// SLOW 320ms · ease_out · 滑块/指示条。
    public static let slow = Animation.easeOut(duration: 0.32)
    /// 阻尼弹簧：开关拇指/滑块过冲 1–5%（design.md §7.3 定型值）。
    public static let toggle = Animation.spring(duration: 0.2, bounce: 0.03)
    /// reduce-motion 替身（1ms 无位移）。
    public static let reduced = Animation.linear(duration: 0.001)

    public static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }
}

// MARK: - 三档阴影（tokens.rs:476-495，色 = srShadowColor）

/// 海拔层级。暗色阴影透明度数倍于亮色（暗色靠阴影分层吃力，§3 表）：
/// Raised 亮 α.06 / 暗 α.40；Floating 亮 (.04,.08) / 暗 (.30,.45)；Modal 亮 (.04,.14) / 暗 (.30,.55)。
public enum SRShadowLevel: String, Sendable, CaseIterable {
    /// y1 blur2 α.06 / 暗 α.40 —— 分段滑块、开关拇指。
    case raised
    /// 亮 (y1,b2,.04)+(y6,b16,.08) / 暗 (y2,b4,.30)+(y8,b24,.45) —— Toast。
    case floating
    /// 亮 (y2,b4,.04)+(y16,b40,.14) / 暗 (y4,b8,.30)+(y20,b48,.55) —— 对话框。
    case modal
}

struct SRShadowLayer: Sendable {
    let y: CGFloat
    let blur: CGFloat
    let alpha: Double

    /// SwiftUI shadow radius ≈ GPUI blur_radius / 2（blur 直径 vs 半径约定，
    /// 取 /2 逼近源值；SwiftUI 多重 shadow 链式叠加等效多层 BoxShadow）。
    var radius: CGFloat { blur / 2 }

    static func layers(_ level: SRShadowLevel, dark: Bool) -> [SRShadowLayer] {
        switch (level, dark) {
        case (.raised, false): [SRShadowLayer(y: 1, blur: 2, alpha: 0.06)]
        case (.floating, false):
            [SRShadowLayer(y: 1, blur: 2, alpha: 0.04),
             SRShadowLayer(y: 6, blur: 16, alpha: 0.08)]
        case (.modal, false):
            [SRShadowLayer(y: 2, blur: 4, alpha: 0.04),
             SRShadowLayer(y: 16, blur: 40, alpha: 0.14)]
        case (.raised, true): [SRShadowLayer(y: 1, blur: 2, alpha: 0.40)]
        case (.floating, true):
            [SRShadowLayer(y: 2, blur: 4, alpha: 0.30),
             SRShadowLayer(y: 8, blur: 24, alpha: 0.45)]
        case (.modal, true):
            [SRShadowLayer(y: 4, blur: 8, alpha: 0.30),
             SRShadowLayer(y: 20, blur: 48, alpha: 0.55)]
        }
    }
}

struct SRElevationModifier: ViewModifier {
    let level: SRShadowLevel
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let layers = SRShadowLayer.layers(level, dark: scheme == .dark)
        return content
            .srShadowLayer(layers[0], then: layers.count > 1 ? layers[1] : nil)
    }
}

extension View {
    /// 施加一层 BoxShadow；至多两层（Elevation 最多双层），无需泛化成循环。
    @ViewBuilder
    fileprivate func srShadowLayer(_ first: SRShadowLayer, then second: SRShadowLayer?) -> some View {
        if let second {
            self
                .srOneShadow(first)
                .srOneShadow(second)
        } else {
            self.srOneShadow(first)
        }
    }

    private func srOneShadow(_ layer: SRShadowLayer) -> some View {
        shadow(
            color: Color.srShadowColor.opacity(layer.alpha),
            radius: layer.radius, x: 0, y: layer.y
        )
    }
}

public extension View {
    /// 三档海拔阴影（暗色自动加重；nil = 无阴影）。
    func srShadow(_ level: SRShadowLevel?) -> some View {
        modifier(SROptionalShadowModifier(level: level))
    }
}

struct SROptionalShadowModifier: ViewModifier {
    let level: SRShadowLevel?

    func body(content: Content) -> some View {
        if let level {
            content.modifier(SRElevationModifier(level: level))
        } else {
            content
        }
    }
}

// MARK: - 表面四层修饰器（§7.3：底色 + 1px srBorder）

/// bg → sunken → surface → overlay 四层表面（§1 原则第 5 条）。
public enum SRSurfaceLevel: String, Sendable, CaseIterable {
    case background, sunken, surface, overlay

    public var color: Color {
        switch self {
        case .background: .srBackground
        case .sunken: .srSunken
        case .surface: .srSurface
        case .overlay: .srOverlay
        }
    }
}

public extension View {
    /// 表面修饰 = 层级底色 + 1px srBorder（圆角默认 0＝直角；需要圆角时传
    /// SRRadius.*，配 SRCard 用完整卡片样式）。
    func srSurface(_ level: SRSurfaceLevel, radius: CGFloat = 0) -> some View {
        background(level.color)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.srBorder, lineWidth: 1)
            )
    }
}
