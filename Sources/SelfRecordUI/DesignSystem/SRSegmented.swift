import SwiftUI

// MARK: - SRSegmented（design.md §7.4 · Ely segmented.rs:77-218）

/// 分段控件：外层轨道 = sunken 底 + 1px border + 圆角 Lg 8 + 内边距 2
/// （:207-218）；滑块 = surface 底 + 1px border + 圆角 Md + Raised 阴影，
/// SLOW 滑动（:105-130）；选中 SEMIBOLD + fg、未选 MEDIUM + fg_muted
/// （:156-160）。窄时标签自动省略（SwiftUI 默认行为，:20 注释语义）。
/// 系统 Picker.segmented 不可定制到此程度，自绘（§7.4 裁决）。
public struct SRSegmented<Option: Hashable & Identifiable>: View {

    let options: [Option]
    let selection: Binding<Option>
    let label: (Option) -> String
    let size: SRControlSize

    @Namespace private var thumbNS
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        options: [Option],
        selection: Binding<Option>,
        size: SRControlSize = .md,
        label: @escaping (Option) -> String
    ) {
        self.options = options
        self.selection = selection
        self.label = label
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(2)                                   // p_0p5(2)
        .background(Color.srSunken)
        .clipShape(RoundedRectangle(cornerRadius: SRRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SRRadius.lg, style: .continuous)
                .stroke(Color.srBorder, lineWidth: 1)
        )
        .frame(minHeight: 44)                         // hit 区 ≥44
        .animation(
            reduceMotion ? nil : SRMotion.slow,       // 滑块 SLOW 320ms
            value: selection.wrappedValue
        )
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option == selection.wrappedValue
        return Button {
            selection.wrappedValue = option
        } label: {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: SRRadius.md, style: .continuous)
                        .fill(Color.srSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: SRRadius.md, style: .continuous)
                                .stroke(Color.srBorder, lineWidth: 1)
                        )
                        .srShadow(.raised)
                        .matchedGeometryEffect(id: "sr-segmented-thumb", in: thumbNS)
                }
                Text(label(option))
                    .srFont(.base, isSelected ? .semibold : .medium)
                    .foregroundStyle(isSelected ? Color.srForeground : Color.srForegroundMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, SRSpacing.md)
            }
            .frame(maxWidth: .infinity)
            .frame(height: size.height - 4)           // 轨道 32 − 内边距 2×2
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(option))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 便捷形态：String 选项

public extension SRSegmented where Option == SRSimpleOption {
    init(
        options: [String],
        selection: Binding<String>,
        size: SRControlSize = .md
    ) {
        let all = options.map { SRSimpleOption(id: $0) }
        let bound = Binding<SRSimpleOption>(
            get: { all.first { $0.id == selection.wrappedValue }
                ?? SRSimpleOption(id: selection.wrappedValue) },
            set: { selection.wrappedValue = $0.id }
        )
        self.init(options: all, selection: bound, size: size) { $0.id }
    }
}

/// String 直接作分段选项的包装（Records 三段「时间/睡眠/饮食」等场景，§6）。
public struct SRSimpleOption: Hashable, Identifiable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}
