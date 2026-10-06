import SwiftUI

// MARK: - SRTabs（design.md §7.4 · Ely tabs.rs:128-267）

/// 页面内页签：2px accent 下划线指示条（tokens.rs:252-255），切换 SLOW 320ms
/// 滑动（tabs.rs:128-153）；条目高 28、px_3(12)、文字 Sm、选中 MEDIUM + fg、
/// 未选 fg_muted（:159-194）；面板交叉淡出由调用方对 content 施加
/// `.animation(SRMotion.base, value: selection)`（:260-267 BASE 交叉淡入）。
///
/// ⚠ 顶层导航不用本组件——按 iOS 习惯走原生 TabView 底栏（§6/§7.4）。
/// Ely 的 Top/Bottom/Left 三摆放与右键菜单/方向键导航属桌面语义，不实现（§9-4）。
public struct SRTabItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    public let icon: String?

    public init(id: ID, title: String, icon: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
    }
}

public struct SRTabs<ID: Hashable>: View {

    let items: [SRTabItem<ID>]
    let selection: Binding<ID>

    @Namespace private var indicatorNS
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(items: [SRTabItem<ID>], selection: Binding<ID>) {
        self.items = items
        self.selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                tab(item)
            }
        }
        .animation(
            reduceMotion ? nil : SRMotion.slow,      // 指示条 SLOW 滑动
            value: selection.wrappedValue
        )
    }

    private func tab(_ item: SRTabItem<ID>) -> some View {
        let isSelected = item.id == selection.wrappedValue
        return Button {
            selection.wrappedValue = item.id
        } label: {
            HStack(spacing: 6) {
                if let icon = item.icon {
                    Image(systemName: icon)
                        .font(.sr(.sm))
                }
                Text(item.title)
                    .srFont(.sm, isSelected ? .medium : .regular)
            }
            .foregroundStyle(isSelected ? Color.srForeground : Color.srForegroundMuted)
            .padding(.horizontal, SRSpacing.md)      // px_3(12)
            .frame(height: 28)                       // 条目高 28
            .frame(minHeight: 44)                    // hit 区 ≥44
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if isSelected {
                    // 2px accent 指示条，跨条目 matchedGeometry 滑动
                    Capsule()
                        .fill(Color.srAccent)
                        .frame(height: 2)
                        .matchedGeometryEffect(id: "sr-tabs-indicator", in: indicatorNS)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
