import SwiftUI

// MARK: - SRField（design.md §7.4 · Ely input.rs:84-141）

/// 文本输入框。1px 边框三态（input.rs:84-90）：默认 border_strong、聚焦 focus、
/// 校验失败 danger；底色 surface、禁用改 sunken（:107-111）；圆角 Md 6、
/// 高 = 控件高度；前缀图标/后缀插槽 + 有内容时出清除按钮（:131-141）。
/// 高对比度：`colorSchemeContrast == .increased` 时边框换高对比档
/// （design.md §7.1 接线示范）。
/// PasswordInput（Lock/Eye）本应用不需要，未实现。
public struct SRField<Suffix: View>: View {

    let text: Binding<String>
    let placeholder: String
    let leadingIcon: String?
    let isInvalid: Bool
    let isEditable: Bool
    let keyboard: SRKeyboard
    let size: SRControlSize
    let showsClearButton: Bool
    let suffix: Suffix

    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        text: Binding<String>,
        placeholder: String = "",
        icon: String? = nil,
        isInvalid: Bool = false,
        isEditable: Bool = true,
        keyboard: SRKeyboard = .plain,
        size: SRControlSize = .md,
        showsClearButton: Bool = true,
        @ViewBuilder suffix: () -> Suffix = { EmptyView() }
    ) {
        self.text = text
        self.placeholder = placeholder
        self.leadingIcon = icon
        self.isInvalid = isInvalid
        self.isEditable = isEditable
        self.keyboard = keyboard
        self.size = size
        self.showsClearButton = showsClearButton
        self.suffix = suffix()
    }

    public var body: some View {
        HStack(spacing: SRSpacing.sm) {
            if let leadingIcon {
                Image(systemName: leadingIcon)
                    .font(.sr(.sm))
                    .foregroundStyle(Color.srForegroundMuted)
            }
            TextField(placeholder, text: text)
                .srFont(.base)
                .foregroundStyle(Color.srForeground)
                .focused($focused)
                .srKeyboard(keyboard)
                .disabled(!isEditable)
            if showsClearButton, isEditable, !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.sr(.sm))
                        .foregroundStyle(Color.srForegroundMuted)
                        .frame(minWidth: 24, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除输入")
            }
            suffix
        }
        .padding(.horizontal, SRSpacing.md)
        .frame(height: size.height)
        .frame(minHeight: 44)                      // hit 区 ≥44
        .background(isEditable ? Color.srSurface : Color.srSunken)
        .clipShape(RoundedRectangle(cornerRadius: SRRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SRRadius.md, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .animation(SRMotion.fast, value: focused)
        .animation(SRMotion.fast, value: isInvalid)
    }

    /// 边框三态 + 禁用 + 高对比度（§7.1）。
    private var borderColor: Color {
        if !isEditable { return .srBorder }
        if isInvalid { return .srDanger }
        if focused { return .srFocus }
        return contrast == .increased ? .srBorderStrongHighContrast : .srBorderStrong
    }
}

/// 无后缀插槽的便捷形态。
public extension SRField where Suffix == EmptyView {
    init(
        text: Binding<String>,
        placeholder: String = "",
        icon: String? = nil,
        isInvalid: Bool = false,
        isEditable: Bool = true,
        keyboard: SRKeyboard = .plain,
        size: SRControlSize = .md,
        showsClearButton: Bool = true
    ) {
        self.init(
            text: text, placeholder: placeholder, icon: icon, isInvalid: isInvalid,
            isEditable: isEditable, keyboard: keyboard, size: size,
            showsClearButton: showsClearButton, suffix: { EmptyView() }
        )
    }
}

// MARK: - 键盘类型（iOS 数字键盘场景，§7.4）

/// 键盘档（iOS-only API 的跨平台占位；macOS 分支恒等）。
public enum SRKeyboard: String, Sendable, CaseIterable {
    case plain
    case number
    case decimal
}

public extension View {
    @ViewBuilder
    func srKeyboard(_ keyboard: SRKeyboard) -> some View {
        #if os(iOS)
        switch keyboard {
        case .plain: self
        case .number: self.keyboardType(.numberPad)
        case .decimal: self.keyboardType(.decimalPad)
        }
        #else
        self
        #endif
    }
}
