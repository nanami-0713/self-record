import SwiftUI

// MARK: - SRButton（design.md §7.4 · Ely button.rs:17-99 / :255-313）

/// 8 变体按钮。规格（button.rs）：
/// - Primary = accent 底 + on_accent 字 + 无边框，hover/按压用 accent_hover；
/// - Secondary = surface 底 + border 边；
/// - Outline = 透明底 + border_strong；
/// - Ghost = 透明底，按压才出底色；
/// - Subtle = hover 色作底；
/// - Success / Danger = 语义色底 + on_accent 字，按压向 fg 混 14%（button.rs:39-99）；
/// - Link = 链接色文字（桌面 hover 下划线属悬停语义，触屏舍弃，§9-4）。
/// 结构：高 = 控件高度（28/32）、内边距 12/16、圆角 Md 6、1px 边框、
/// 字重 MEDIUM、图标与文字 gap 6（button.rs:255-276）。
/// 状态：禁用 opacity 0.45（:294-299）；loading = 内容隐形占位、居中转圈、
/// 拦截点击（:280-292）。
/// iOS 迁就（§7.4）：视觉 28/32 但 hit 区 ≥44（contentShape + minHeight 44）。
public struct SRButton: View {

    public enum Style: String, Sendable, CaseIterable {
        case primary, secondary, outline, ghost, subtle, success, danger, link
    }

    public enum Size: String, Sendable, CaseIterable {
        /// 视觉高 28。
        case sm
        /// 视觉高 32。
        case md

        var controlSize: SRControlSize {
            switch self {
            case .sm: .sm
            case .md: .md
            }
        }
    }

    let title: String
    let icon: String?
    let style: Style
    let size: Size
    let isLoading: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    public init(
        _ title: String,
        icon: String? = nil,
        style: Style = .primary,
        size: Size = .md,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.style = style
        self.size = size
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            content
                .opacity(contentOpacity)
                .overlay {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(spinnerTint)
                    }
                }
        }
        .buttonStyle(SRButtonStyle(style: style))
        // loading 拦截点击（Ely :305-308）；禁用态来自环境（.disabled(...)）
        .disabled(isLoading)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isLoading ? [.updatesFrequently] : [])
    }

    private var contentOpacity: Double {
        if isLoading { return 0 }              // 内容隐形占位，同宽保持
        return isEnabled ? 1 : 0.45            // 禁用 opacity 0.45
    }

    private var spinnerTint: Color {
        switch style {
        case .primary, .success, .danger: .srOnAccent
        default: .srForeground
        }
    }

    private var content: some View {
        HStack(spacing: 6) {                   // 图标与文字 gap 6（:255-276）
            if let icon {
                Image(systemName: icon)
                    .font(.sr(.sm))
            }
            Text(title)
        }
        .font(.sr(.base, .medium))             // 按钮字重 MEDIUM（:275）
        .padding(.horizontal, size.controlSize.horizontalPadding)
        .frame(height: size.controlSize.height)
        .frame(minWidth: 44, minHeight: 44)    // hit 区 ≥44（§7.4）
        .contentShape(Rectangle())
    }
}

/// 按压态色板映射（无桌面 hover，按压 = Ely hover/active 语义）。
struct SRButtonChrome: Equatable {
    let foreground: Color
    let background: Color
    let border: Color?

    init(style: SRButton.Style, pressed: Bool) {
        switch style {
        case .primary:
            foreground = .srOnAccent
            background = pressed ? .srAccentHover : .srAccent
            border = nil
        case .secondary:
            foreground = .srForeground
            background = pressed ? .srActive : .srSurface
            border = .srBorder
        case .outline:
            foreground = .srForeground
            background = pressed ? .srHover : .clear
            border = .srBorderStrong
        case .ghost:
            foreground = .srForeground
            background = pressed ? .srHover : .clear
            border = nil
        case .subtle:
            foreground = .srForeground
            background = pressed ? .srActive : .srHover
            border = nil
        case .success:
            foreground = .srOnAccent
            background = pressed
                ? Color.srBlend(.srSuccess, toward: .srForeground, fraction: 0.14)
                : .srSuccess
            border = nil
        case .danger:
            foreground = .srOnAccent
            background = pressed
                ? Color.srBlend(.srDanger, toward: .srForeground, fraction: 0.14)
                : .srDanger
            border = nil
        case .link:
            foreground = .srLink
            background = .clear
            border = nil
        }
    }
}

/// 按压视觉：底色/边框切换（Ely 无 scale 形变，纯色变）。
struct SRButtonStyle: ButtonStyle {
    let style: SRButton.Style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let chrome = SRButtonChrome(style: style, pressed: configuration.isPressed)
        return configuration.label
            .foregroundStyle(chrome.foreground)
            .background(chrome.background)
            .clipShape(RoundedRectangle(cornerRadius: SRRadius.md, style: .continuous))
            .overlay {
                if let border = chrome.border {
                    RoundedRectangle(cornerRadius: SRRadius.md, style: .continuous)
                        .stroke(border, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed && style == .link ? 0.7 : 1)  // Link 按压反馈
            .animation(reduceMotion ? nil : SRMotion.fast, value: configuration.isPressed)
    }
}
