import SelfRecordCore
import SwiftUI

// MARK: - 记一笔表单（design.md §6「预算」Tab：ExpenseEntrySheet）
//
// 对齐 lifttime expenseSheet（budget.js:181-271）：金额（round2、必须 > 0）、
// 分类（MANUAL_CATS——七档口径中不含 .meals 档，`.meals` 仅由记餐花费派生，
// §3.5）、计划归属（计划内/计划外双口径开关）、备注（可选，≤60 字）、日期
// （默认今天，落库归一到所选日 12:00）。编辑态多一个删除入口（破坏性确认）。
//
// 表单态走 ObservableObject（宏禁令）；焦点不挪进模型（§8 约定 5 例外条款——
// 本表单无需程序化焦点，金额校验以行内错误文案呈现）。

/// 记一笔表单模型（sheet(item:) 的 Item；@MainActor）。
@MainActor
public final class ExpenseFormModel: ObservableObject, Identifiable {

    public let id = UUID()
    /// nil = 新增。
    public let editingID: UUID?

    @Published public var amountText: String
    @Published public var category: ExpenseCategory
    @Published public var isOutOfPlan: Bool
    @Published public var noteText: String
    @Published public var date: Date
    /// 删除确认弹层（编辑态）。
    @Published public var showsDeleteConfirm = false
    /// 行内校验文案（金额非法时「先填金额」，budget.js:248 同语义）。
    @Published public var errorMessage: String?

    /// 新增（默认分类 .groceries、日期今天——budget.js:184/:249）。
    public init(newAt date: Date) {
        self.editingID = nil
        self.amountText = ""
        self.category = .groceries
        self.isOutOfPlan = false
        self.noteText = ""
        self.date = date
    }

    /// 编辑预填。
    public init(editing expense: Expense) {
        self.editingID = expense.id
        self.amountText = Self.plainNumber(expense.amountYuan)
        self.category = expense.category ?? .groceries
        self.isOutOfPlan = expense.isOutOfPlan
        self.noteText = expense.note ?? ""
        self.date = expense.date
    }

    /// 金额预填串：整数不带小数、其余两位小数（lifttime 表单 value 直填的等价物）。
    private static func plainNumber(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.2f", rounded)
    }
}

// MARK: - 表单视图

public struct ExpenseEntrySheet: View {

    @ObservedObject public var form: ExpenseFormModel
    let onSubmit: (ExpenseDraft) -> Void
    let onDelete: (UUID) -> Void
    let onCancel: () -> Void

    public init(form: ExpenseFormModel,
                onSubmit: @escaping (ExpenseDraft) -> Void,
                onDelete: @escaping (UUID) -> Void,
                onCancel: @escaping () -> Void) {
        self.form = form
        self.onSubmit = onSubmit
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SRSpacing.lg) {
                header
                amountSection
                categorySection
                planSection
                dateSection
                noteSection
                if let error = form.errorMessage {
                    Text(error)
                        .srFont(.sm)
                        .foregroundStyle(Color.srDanger)
                }
                buttons
            }
            .padding(SRSpacing.lg)
        }
        .background(Color.srBackground)
        .confirmationDialog("删除这笔开销？", isPresented: $form.showsDeleteConfirm,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let id = form.editingID { onDelete(id) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(form.editingID == nil ? "记一笔开销" : "编辑开销")
                .srFont(.lg, .semibold)
            Spacer()
            SRButton("取消", style: .ghost, size: .sm, action: onCancel)
        }
    }

    private var amountSection: some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            Text("金额")
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)
            SRField(text: $form.amountText,
                    placeholder: "0.00",
                    icon: "yensign",
                    isInvalid: form.errorMessage != nil,
                    keyboard: .decimal)
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            Text("分类")
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)
            CategoryChipGrid(selection: $form.category,
                             categories: BudgetEngine.manualCategories)
        }
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            Text("计划归属")
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)
            SRSwitch(isOn: $form.isOutOfPlan, label: "计划外开销")
            Text("计划外开销照常计入周/月与自定义周期计划的总账与统计，但不占任何周期预算额度（§3.5 双口径）。")
                .srFont(.sm)
                .foregroundStyle(form.isOutOfPlan ? Color.srWarning : Color.srForegroundSubtle)
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            Text("日期")
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)
            DatePicker("日期", selection: $form.date, displayedComponents: .date)
                .labelsHidden()
                .srFont(.base)
        }
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            Text("备注（可选）")
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)
            SRField(text: $form.noteText,
                    placeholder: "比如：超市买菜 / 蛋白粉一罐")
        }
    }

    private var buttons: some View {
        HStack(spacing: SRSpacing.md) {
            if form.editingID != nil {
                SRButton("删除", style: .danger) {
                    form.showsDeleteConfirm = true
                }
                Spacer(minLength: SRSpacing.sm)
            }
            SRButton(form.editingID == nil ? "保存" : "保存修改", style: .primary) {
                submit()
            }
        }
    }

    private func submit() {
        let normalized = form.amountText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(normalized), amount.isFinite, amount > 0 else {
            form.errorMessage = "先填金额"
            return
        }
        form.errorMessage = nil
        let note = String(form.noteText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(60))                       // budget.js:196 maxlength=60
        onSubmit(ExpenseDraft(editingID: form.editingID,
                              date: form.date,
                              amountYuan: amount,
                              category: form.category,
                              note: note.isEmpty ? nil : note,
                              isOutOfPlan: form.isOutOfPlan))
    }
}

// MARK: - 分类选择（chips；lifttime budget.js:201-212 的 iOS 形态）

/// 分类选择 chips：七档口径减去 .meals（`BudgetEngine.manualCategories`，
/// §3.5——记餐开销档仅由 DietEntry.costYuan 派生，手动记账不提供）。
private struct CategoryChipGrid: View {

    let selection: Binding<ExpenseCategory>
    let categories: [ExpenseCategory]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: SRSpacing.sm)],
                  spacing: SRSpacing.sm) {
            ForEach(categories, id: \.self) { category in
                chip(category)
            }
        }
    }

    private func chip(_ category: ExpenseCategory) -> some View {
        let isSelected = category == selection.wrappedValue
        return Button {
            selection.wrappedValue = category
        } label: {
            HStack(spacing: SRSpacing.xs) {
                Circle()
                    .fill(SRChartPalette.hue(category.budgetHue, scheme))
                    .frame(width: 8, height: 8)
                Text(BudgetEngine.categoryLabel(category))
                    .srFont(.base, .medium)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: SRControlSize.md.height)
            .padding(.horizontal, SRSpacing.md)
            .foregroundStyle(isSelected ? Color.srOnAccent : Color.srForeground)
            .background(isSelected ? Color.srAccent : Color.srSurface)
            .clipShape(RoundedRectangle(cornerRadius: SRRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SRRadius.md, style: .continuous)
                    .stroke(isSelected ? Color.srAccent : Color.srBorder, lineWidth: 1)
            )
            .frame(minHeight: 44)                       // hit 区 ≥44（§7.3）
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(BudgetEngine.categoryLabel(category))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
