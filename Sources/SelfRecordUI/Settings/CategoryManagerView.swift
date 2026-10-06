import SelfRecordCore
import SwiftUI

// MARK: - ChartHue 的展示扩展（CategoryManagerView 专用展示口径）

extension ChartHue {

    /// 8 个彩色档（§4.1 取色口径：neutral 为兜底分类专属，自建分类不提供）。
    var isColored: Bool { self != .neutral }

    /// 取色档中文名（无障碍标签 / 取色区标题用）。
    var displayName: String {
        switch self {
        case .blue: "蓝"
        case .teal: "青绿"
        case .ochre: "赭黄"
        case .rose: "玫红"
        case .violet: "紫"
        case .green: "绿"
        case .rust: "锈橙"
        case .cyan: "天蓝"
        case .neutral: "中性"
        }
    }
}

// MARK: - 分类编辑流程状态（宏禁令 §8 约定 5：页面局部状态走 ObservableObject）

/// 新建 / 编辑分类的 sheet 状态机：草稿 + 确认弹层 + 动作结果（toast）。
@MainActor
final class CategoryEditFlow: ObservableObject {

    enum Mode: Equatable {
        case create
        case edit(TimeCategory)
    }

    @Published var isPresented = false
    @Published var mode: Mode = .create
    @Published var label = ""
    @Published var hue: ChartHue = .blue
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var deleteConfirmPresented = false
    @Published var archiveConfirmPresented = false

    /// 本页轻反馈（「已删除，N 段历史归入其他」等，§6 toast 约定）。
    let toast = SRToastCenter()

    var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    /// 正在编辑的分类（create 模式为 nil）。
    var editingCategory: TimeCategory? {
        if case .edit(let category) = mode { return category }
        return nil
    }

    /// 开始新建：取色默认选一个尚未使用的彩色档。
    func startCreation(usedHues: Set<ChartHue>) {
        mode = .create
        label = ""
        hue = ChartHue.allCases.first { $0.isColored && !usedHues.contains($0) } ?? .blue
        errorMessage = nil
        isPresented = true
    }

    /// 开始编辑。
    func startEdit(_ category: TimeCategory) {
        mode = .edit(category)
        label = category.label
        hue = category.hue
        errorMessage = nil
        isPresented = true
    }

    func cancel() {
        isPresented = false
    }

    /// 保存（新建走 TimeEngine.addCategory，编辑走改名/改色；语义在 Core）。
    func save(_ model: AppModel) async {
        isBusy = true
        defer { isBusy = false }
        let ok: Bool
        switch mode {
        case .create:
            ok = await model.addCategory(label: label, hue: hue)
        case .edit(let category):
            ok = await model.updateCategory(id: category.id, label: label, hue: hue)
        }
        if ok {
            isPresented = false
        } else {
            errorMessage = "名称不能为空，且颜色须为 8 个彩色档之一"
        }
    }

    /// 删除（确认弹层后的落点；历史块归并由 TimeEngine 完成）。
    func performDelete(_ model: AppModel) async {
        guard let category = editingCategory else { return }
        let result = await model.deleteCategory(id: category.id)
        isPresented = false
        switch result {
        case .applied(let migrated):
            toast.show("已删除「\(category.label)」",
                       message: migrated > 0 ? "\(migrated) 段历史记录归入兜底分类" : nil,
                       severity: .success)
        case .rejectedFallback:
            toast.show("兜底分类不可删除", severity: .warning)
        case .notFound:
            break
        }
    }

    /// 归档（从选择列表退役；历史块同样归并兜底，可恢复）。
    func performArchive(_ model: AppModel) async {
        guard let category = editingCategory else { return }
        let result = await model.archiveCategory(id: category.id)
        isPresented = false
        switch result {
        case .applied(let migrated):
            toast.show("已归档「\(category.label)」",
                       message: migrated > 0 ? "\(migrated) 段历史记录归入兜底分类" : nil,
                       severity: .success)
        case .rejectedFallback:
            toast.show("兜底分类不可归档", severity: .warning)
        case .notFound:
            break
        }
    }

    /// 恢复已归档分类（仅恢复可选性，已归并的历史块不回迁）。
    func performRestore(_ model: AppModel) async {
        guard let category = editingCategory else { return }
        if await model.restoreCategory(id: category.id) {
            isPresented = false
        }
    }
}

// MARK: - CategoryManagerView（design.md §6：分类增删改 + 删除归并兜底说明）

public struct CategoryManagerView: View {

    @EnvironmentObject private var model: AppModel
    @StateObject private var flow = CategoryEditFlow()
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        let usage = model.categoryUsageCounts()
        let active = model.categories.filter { !$0.isArchived }
        let archived = model.categories.filter { $0.isArchived }

        ScrollView {
            VStack(alignment: .leading, spacing: SRSpacing.xl) {
                fallbackBanner
                categoryList(title: "使用中", categories: active, usage: usage)
                if !archived.isEmpty {
                    categoryList(title: "已归档", categories: archived, usage: usage)
                }
            }
            .padding(.horizontal, SRSpacing.lg)
            .padding(.vertical, SRSpacing.xl)
        }
        .background(Color.srBackground)
        .navigationTitle("时间分类")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SRButton("新建分类", icon: "plus", style: .primary, size: .sm) {
                    flow.startCreation(usedHues: Set(model.categories.map(\.hue)))
                }
            }
        }
        .sheet(isPresented: $flow.isPresented) {
            CategoryEditSheet(flow: flow)
        }
        .srToastHost(flow.toast)
    }

    // MARK: 分区与行

    private func categoryList(title: String, categories: [TimeCategory], usage: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.sm) {
            Text(title)
                .srFont(.sm, .medium)
                .foregroundStyle(Color.srForegroundMuted)
            SRCard(padding: SRSpacing.md) {
                VStack(spacing: 0) {
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.srBorder)
                                .frame(height: 1)
                        }
                        row(category, usage: usage[category.id] ?? 0)
                    }
                }
            }
        }
    }

    private func row(_ category: TimeCategory, usage: Int) -> some View {
        Button {
            flow.startEdit(category)
        } label: {
            HStack(spacing: SRSpacing.md) {
                Circle()
                    .fill(SRChartPalette.hue(category.hue, scheme))
                    .frame(width: 12, height: 12)
                Text(category.label)
                    .srFont(.base)
                    .foregroundStyle(Color.srForeground)
                if category.isFallback {
                    SRBadge("兜底")
                }
                if category.isArchived {
                    SRBadge("已归档", tone: .warning)
                }
                Spacer()
                Text("\(usage) 段记录")
                    .srFont(.sm)
                    .monospacedDigit()
                    .foregroundStyle(Color.srForegroundMuted)
                Image(systemName: "chevron.right")
                    .font(.sr(.sm))
                    .foregroundStyle(Color.srForegroundSubtle)
            }
            .padding(.vertical, SRSpacing.sm)
            .padding(.horizontal, SRSpacing.xs)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("编辑分类")
    }

    /// 兜底语义说明横幅（info 淡底，§7.1 *_subtle 用途行）。
    private var fallbackBanner: some View {
        let fallbackLabel = model.categories.first(where: \.isFallback)?.label ?? "其他"
        return HStack(alignment: .top, spacing: SRSpacing.md) {
            Image(systemName: SRSeverity.info.symbolName)
                .font(.sr(.base))
                .foregroundStyle(Color.srInfo)
            Text("「\(fallbackLabel)」是兜底分类：删除或归档其他分类时，其历史时间块会归入它；它本身不可删除，颜色固定为中性档。")
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SRSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.srInfoSubtle)
        .clipShape(RoundedRectangle(cornerRadius: SRRadius.lg, style: .continuous))
    }
}

// MARK: - 新建/编辑 sheet

private struct CategoryEditSheet: View {

    @ObservedObject var flow: CategoryEditFlow
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme

    private var editingCategory: TimeCategory? { flow.editingCategory }

    var body: some View {
        VStack(alignment: .leading, spacing: SRSpacing.lg) {
            Text(flow.isCreate ? "新建分类" : "编辑分类")
                .srFont(.lg, .semibold)

            VStack(alignment: .leading, spacing: SRSpacing.xs) {
                Text("名称")
                    .srFont(.base)
                    .foregroundStyle(Color.srForeground)
                SRField(text: $flow.label, placeholder: "如 学习、阅读")
                if let error = flow.errorMessage {
                    Text(error)
                        .srFont(.sm)
                        .foregroundStyle(Color.srDanger)
                }
            }

            huePicker

            if let category = editingCategory, !category.isFallback {
                VStack(alignment: .leading, spacing: SRSpacing.md) {
                    separator
                    if category.isArchived {
                        SRButton("恢复使用", icon: "arrow.uturn.backward", style: .secondary) {
                            Task { await flow.performRestore(model) }
                        }
                    } else {
                        SRButton("归档分类", icon: "archivebox", style: .secondary) {
                            flow.archiveConfirmPresented = true
                        }
                    }
                    SRButton("删除分类", icon: "trash", style: .danger) {
                        flow.deleteConfirmPresented = true
                    }
                }
            } else if editingCategory?.isFallback == true {
                Text("兜底分类不可删除；名称可修改，颜色固定为中性档。")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
            }

            Spacer(minLength: 0)

            HStack {
                SRButton("取消", style: .ghost) { flow.cancel() }
                Spacer()
                SRButton("保存", style: .primary, isLoading: flow.isBusy) {
                    Task { await flow.save(model) }
                }
            }
        }
        .padding(SRSpacing.lg)
        .frame(maxWidth: 520, alignment: .leading)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(true)   // 表单防误关（§6 全局交互约定）
        .confirmationDialog(deleteDialogTitle,
                            isPresented: $flow.deleteConfirmPresented,
                            titleVisibility: .visible) {
            Button("删除分类", role: .destructive) {
                Task { await flow.performDelete(model) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteDialogMessage)
        }
        .confirmationDialog(archiveDialogTitle,
                            isPresented: $flow.archiveConfirmPresented,
                            titleVisibility: .visible) {
            Button("归档分类", role: .destructive) {
                Task { await flow.performArchive(model) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(archiveDialogMessage)
        }
    }

    // MARK: 取色（8 彩色档，不含 neutral——§4.1「UI 不提供选择」）

    @ViewBuilder
    private var huePicker: some View {
        if let category = editingCategory, category.isFallback {
            VStack(alignment: .leading, spacing: SRSpacing.xs) {
                Text("颜色")
                    .srFont(.base)
                    .foregroundStyle(Color.srForeground)
                HStack(spacing: SRSpacing.sm) {
                    Circle()
                        .fill(SRChartPalette.hue(.neutral, scheme))
                        .frame(width: 32, height: 32)
                    Text("中性（兜底分类专属）")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: SRSpacing.sm) {
                Text("颜色")
                    .srFont(.base)
                    .foregroundStyle(Color.srForeground)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: SRSpacing.sm)],
                          spacing: SRSpacing.sm) {
                    ForEach(ChartHue.allCases.filter(\.isColored), id: \.self) { hue in
                        HueSwatch(hue: hue, isSelected: flow.hue == hue) {
                            flow.hue = hue
                        }
                    }
                }
            }
        }
    }

    // MARK: 确认弹层文案

    private var fallbackLabel: String {
        model.categories.first(where: \.isFallback)?.label ?? "其他"
    }

    private var deleteDialogTitle: String {
        "删除分类「\(editingCategory?.label ?? "")」？"
    }

    private var deleteDialogMessage: String {
        let count = model.categoryUsageCounts()[editingCategory?.id ?? ""] ?? 0
        if count > 0 {
            return "其 \(count) 段历史时间块将归入兜底分类「\(fallbackLabel)」，本操作不可撤销。"
        }
        return "该分类没有历史时间块。本操作不可撤销。"
    }

    private var archiveDialogTitle: String {
        "归档分类「\(editingCategory?.label ?? "")」？"
    }

    private var archiveDialogMessage: String {
        "归档后不再出现在计时选择列表，历史时间块同样归入「\(fallbackLabel)」。之后可随时恢复使用（已归并的历史不回迁）。"
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.srBorder)
            .frame(height: 1)
    }
}

// MARK: - 取色色板按钮

/// 单个 ChartHue 色板圆点：选中 = 外圈描边 + 对勾；hit 区 ≥44（§7.3）。
private struct HueSwatch: View {

    let hue: ChartHue
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(SRChartPalette.hue(hue, scheme))
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.sr(.xs, .semibold))
                        .foregroundStyle(Color.srOnAccent)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 32, height: 32)
            .padding(2)
            .overlay(
                Circle().stroke(isSelected ? Color.srForeground : Color.srBorderStrong,
                                lineWidth: isSelected ? 2 : 1)
            )
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hue.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
