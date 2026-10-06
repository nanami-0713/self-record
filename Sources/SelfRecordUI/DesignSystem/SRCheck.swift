import SwiftUI

// MARK: - SRCheck（design.md §7.4 · Ely check.rs:28-70）

/// 勾选框：16px 方框、圆角 Sm 4、1px 边框；选中 = accent 底 + on_accent 勾图标
/// （Xs 号）；**半选态 mixed 用减号图标**（列表批量选择场景，check.rs:28-42）；
/// 选中瞬间底色 surface→accent 过渡动画（:66-68）；禁用 opacity 0.5。
/// 系统 Toggle 无 checkbox 风格，自绘（§7.4 裁决）。
public enum SRCheckState: String, Sendable {
    case off
    case on
    case mixed
}

public struct SRCheck: View {

    let state: SRCheckState
    let isEnabled: Bool
    let accessibilityLabel: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        state: SRCheckState,
        isEnabled: Bool = true,
        accessibilityLabel: String = "",
        action: @escaping () -> Void
    ) {
        self.state = state
        self.isEnabled = isEnabled
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: SRRadius.sm, style: .continuous)
                    .fill(isChecked ? Color.srAccent : Color.srSurface)
                RoundedRectangle(cornerRadius: SRRadius.sm, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
                mark
            }
            .frame(width: 16, height: 16)             // check_size 16（tokens.rs:400-403）
            .frame(minWidth: 44, minHeight: 44)       // hit 区 ≥44
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(state == .on ? .isSelected : [])
        .animation(reduceMotion ? nil : SRMotion.base, value: state)  // surface→accent 过渡
    }

    private var isChecked: Bool { state != .off }

    @ViewBuilder
    private var mark: some View {
        switch state {
        case .on:
            Image(systemName: "checkmark")
                .font(.sr(.xs))                       // Xs 号勾图标
                .foregroundStyle(Color.srOnAccent)
                .accessibilityHidden(true)
        case .mixed:
            Image(systemName: "minus")                // 半选 = 减号
                .font(.sr(.xs))
                .foregroundStyle(Color.srOnAccent)
                .accessibilityHidden(true)
        case .off:
            EmptyView()
        }
    }

    private var borderColor: Color {
        if !isEnabled { return .srBorder }
        if isChecked { return .srAccent }
        return .srBorderStrong
    }
}

// MARK: - SRSwitch（design.md §7.4 · Ely switch.rs:65-127）

/// 开关：原生 Toggle + switch 样式，tint = srAccent（§7.4 裁决：轨道 32×18 的
/// 过冲弹簧交给系统，视觉对齐 SRMotion.toggle 的节奏）。标签在右侧（Ely 语义；
/// switch.rs:120-127）。禁用 opacity 0.5 由系统处理。
public struct SRSwitch<Label: View>: View {

    let isOn: Binding<Bool>
    let label: Label

    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.label = label()
    }

    public var body: some View {
        HStack(spacing: SRSpacing.sm) {
            Toggle(isOn: isOn) {}
                .toggleStyle(.switch)
                .tint(Color.srAccent)
                .fixedSize()
            label
                .srFont(.base)                       // 开关标签 Base（switch.rs:132）
                .foregroundStyle(Color.srForeground)
        }
    }
}

public extension SRSwitch where Label == Text {
    init(isOn: Binding<Bool>, label: String) {
        self.init(isOn: isOn) { Text(label) }
    }
}
