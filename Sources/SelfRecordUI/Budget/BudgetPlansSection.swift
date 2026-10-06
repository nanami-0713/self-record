import SelfRecordCore
import SwiftUI

// MARK: - 自定义周期计划区块（design.md §9-6 后置项，本次实装）
//
// 对齐 lifttime budget.js 的自定义周期部分：计划卡 planCard（:102-124：
// 未开始行 / 已结束行 + 再来一期 / 进行中走状态条）、空态与「＋ 自定义
// 周度计划」入口（:78-85）、planSheet 表单（:300-360：名称 ≤12 字可选、
// 金额 > 0、起止实时「共 N 天」提示、最长 365 天）、「再来一期」（:90-97
// 的交互入口，语义升级为等长等额、紧接上一期结束日之后开新期）。
// 数据全部来自 `AppModel.budgetPlanCards`（Core 引擎产物），本文件只做
// 排版与交互接线；状态管理走 ObservableObject（§8 约定 5，无 @State）。

// MARK: - 表单模型

/// 计划新建/编辑表单模型（sheet(item:) 的 Item；@MainActor）。
@MainActor
public final class PlanFormModel: ObservableObject, Identifiable {

    public let id = UUID()
    /// nil = 新建。
    public let editingID: UUID?

    @Published public var nameText: String
    @Published public var amountText: String
    @Published public var start: Date
    @Published public var end: Date
    /// 删除确认弹层（编辑态）。
    @Published public var showsDeleteConfirm = false
    /// 行内校验文案（金额非法 / 日期非法，budget.js:348-351 同语义）。
    @Published public var errorMessage: String?

    /// 新建：默认今天起 14 天（budget.js:325 `now + 13 * 86400000`）。
    public init(newAt now: Date) {
        self.editingID = nil
        self.nameText = ""
        self.amountText = ""
        self.start = now
        let calendar = DayCalendar()
        self.end = calendar.calendar.date(byAdding: .day, value: 13, to: now) ?? now
    }

    /// 编辑预填（起止取计划首末日 0 点）。
    public init(editing plan: CustomBudgetPlan) {
        self.editingID = plan.id
        self.nameText = plan.name
        self.amountText = Self.plainNumber(plan.amountYuan)
        let calendar = DayCalendar()
        self.start = calendar.date(of: plan.startDay) ?? Date()
        self.end = calendar.date(of: plan.endDay) ?? Date()
    }

    /// 金额预填串：整数不带小数、其余两位小数（与 ExpenseFormModel 同式）。
    private static func plainNumber(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.2f", rounded)
    }
}

// MARK: - 表单视图

public struct CustomPlanSheet: View {

    @ObservedObject public var form: PlanFormModel
    let onSubmit: (BudgetPlanDraft) -> Void
    let onDelete: (UUID) -> Void
    let onCancel: () -> Void

    public init(form: PlanFormModel,
                onSubmit: @escaping (BudgetPlanDraft) -> Void,
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
                nameSection
                amountSection
                dateSection
                daysHint
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
        .confirmationDialog("删除这个计划？", isPresented: $form.showsDeleteConfirm,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let id = form.editingID { onDelete(id) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(form.editingID == nil ? "自定义周期计划" : "编辑周期计划")
                .srFont(.lg, .semibold)
            Spacer()
            SRButton("取消", style: .ghost, size: .sm, action: onCancel)
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            Text("计划名称（可选）")
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)
            SRField(text: $form.nameText,
                    placeholder: "如：两周冲刺 / 国庆长假",
                    showsClearButton: false)
        }
    }

    private var amountSection: some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            Text("预算金额（¥）")
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)
            SRField(text: $form.amountText,
                    placeholder: "如 800",
                    icon: "yensign",
                    isInvalid: form.errorMessage != nil,
                    keyboard: .decimal)
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            Text("起止日期")
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)
            HStack(spacing: SRSpacing.md) {
                DatePicker("开始", selection: $form.start, displayedComponents: .date)
                    .labelsHidden()
                DatePicker("结束", selection: $form.end, displayedComponents: .date)
                    .labelsHidden()
            }
            .srFont(.base)
        }
    }

    /// 起止日期 → 时长实时提示（budget.js:330-341：非法红字，合法「共 N 天」）。
    private var daysHint: some View {
        let days = Self.dayCount(start: form.start, end: form.end)
        return Text(days < 1
                    ? "结束日期不能早于开始日期"
                    : "共 \(days) 天（从开始日 0 点到结束日 24 点）；结束后保留总结，可一键「再来一期」。")
            .srFont(.sm)
            .foregroundStyle(days < 1 ? Color.srDanger : Color.srForegroundSubtle)
    }

    private var buttons: some View {
        HStack(spacing: SRSpacing.md) {
            if form.editingID != nil {
                SRButton("删除计划", style: .danger) {
                    form.showsDeleteConfirm = true
                }
                Spacer(minLength: SRSpacing.sm)
            }
            SRButton(form.editingID == nil ? "创建计划" : "保存修改", style: .primary) {
                submit()
            }
        }
    }

    /// 起止时刻 → 含首尾天数（表单实时校验用；设备时区口径）。
    private static func dayCount(start: Date, end: Date) -> Int {
        let calendar = DayCalendar()
        return BudgetEngine.planDays(from: calendar.dayKey(for: start),
                                     to: calendar.dayKey(for: end),
                                     calendar: calendar)
    }

    private func submit() {
        // 金额：round2 且必须 > 0（budget.js:346-348）
        let normalized = form.amountText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(normalized), amount.isFinite, amount > 0 else {
            form.errorMessage = "先填预算金额"
            return
        }
        // 天数：1…365（budget.js:349-351）
        let days = Self.dayCount(start: form.start, end: form.end)
        guard (1...365).contains(days) else {
            form.errorMessage = "结束日期要晚于或等于开始日期（最长 365 天）"
            return
        }
        form.errorMessage = nil
        let name = String(form.nameText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(12))                       // budget.js:312 maxlength=12
        onSubmit(BudgetPlanDraft(editingID: form.editingID,
                                 name: name.isEmpty ? nil : name,
                                 amountYuan: amount,
                                 start: form.start,
                                 end: form.end))
    }
}

// MARK: - 计划区块卡（budget.js:65-100）

/// 「自定义周期计划」区块：空态提示 + 计划卡列表 + 新建入口。
/// 计划卡三态（budget.js:110-124）：未开始（区间 + 额度预告）、进行中
/// （双进度条 + 剩余额度 + 计外行 + 拉回建议）、已结束（总结 + 再来一期）。
struct BudgetPlansCard: View {

    let cards: [BudgetPlanCardData]
    let onAdd: () -> Void
    let onEdit: (CustomBudgetPlan) -> Void
    let onDelete: (CustomBudgetPlan) -> Void
    let onRenew: (CustomBudgetPlan) -> Void

    var body: some View {
        SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                Text("自定义周期计划")
                    .srFont(.lg, .semibold)
                if cards.isEmpty {
                    Text("还没有自定义计划——比如「14 天 ¥800」「10 天 ¥500」，天数金额随你定。")
                        .srFont(.base)
                        .foregroundStyle(Color.srForegroundMuted)   // budget.js:79
                } else {
                    VStack(spacing: 0) {
                        ForEach(cards) { card in
                            planRow(card)
                            if card.id != cards.last?.id {
                                Rectangle().fill(Color.srBorder).frame(height: 1)
                            }
                        }
                    }
                }
                SRButton("自定义周期计划", icon: "plus", style: .ghost, size: .sm,
                         action: onAdd)
            }
        }
    }

    // MARK: 单卡

    private func planRow(_ card: BudgetPlanCardData) -> some View {
        Button {
            onEdit(card.plan)                        // 点卡即编辑（budget.js:99）
        } label: {
            VStack(alignment: .leading, spacing: SRSpacing.sm) {
                headerRow(card)
                Text(card.rangeText)
                    .srFont(.sm)
                    .monospacedDigit()
                    .foregroundStyle(Color.srForegroundMuted)
                if let status = card.status {
                    switch status.phase {
                    case .upcoming:
                        upcomingBody(status)
                    case .active:
                        activeBody(card, status)
                    case .ended:
                        endedBody(card, status)
                    }
                } else {
                    Text("计划数据异常，点按重新编辑")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundSubtle)
                }
            }
            .padding(.vertical, SRSpacing.sm)
            .frame(minHeight: 44, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {                               // 编辑 / 删除（iOS 习惯）
            Button("编辑计划") { onEdit(card.plan) }
            Button("删除计划", role: .destructive) { onDelete(card.plan) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("点按编辑计划")
    }

    /// 名称行：展示名 + 三态徽标（budget.js:112-121）。
    private func headerRow(_ card: BudgetPlanCardData) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SRSpacing.sm) {
            Text(card.nameText)
                .srFont(.base, .semibold)
            phaseBadge(card.status?.phase)
            Spacer()
            if let status = card.status, status.phase == .active {
                Text("\(status.pct)%")
                    .srFont(.base, .semibold)
                    .monospacedDigit()
                    .foregroundStyle(spendTint(status))
            }
        }
    }

    private func phaseBadge(_ phase: CustomPlanStatus.Phase?) -> some View {
        switch phase {
        case .upcoming: SRBadge("未开始", tone: .info)
        case .active: SRBadge("进行中", tone: .success)
        case .ended: SRBadge("已结束", tone: .neutral)
        case nil: SRBadge("异常", tone: .danger)
        }
    }

    /// 未开始：额度预告（budget.js:113-115「X 开始 · ¥Y / N 天」）。
    private func upcomingBody(_ status: CustomPlanStatus) -> some View {
        Text("开始后自动计入周期内开销 · 额度 ¥\(BudgetEngine.fmtMoney(status.budgetYuan)) / \(status.daysTotal) 天")
            .srFont(.sm)
            .foregroundStyle(Color.srForegroundMuted)
    }

    /// 进行中：双进度条 + 剩余额度/日均 + 计外行 + 拉回建议。
    private func activeBody(_ card: BudgetPlanCardData, _ status: CustomPlanStatus) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            // 双进度条：时间进度 vs 花销进度（花销超时间进度变警示色）
            progressRow(label: "时间",
                        pct: Int((status.timeProgress * 100).rounded()),
                        progress: status.timeProgress,
                        tint: Color.srForegroundSubtle)
            progressRow(label: "花销",
                        pct: status.pct,
                        progress: status.spentYuan / status.budgetYuan,
                        tint: spendTint(status))
            Text(quotaText(status))
                .srFont(.sm)
                .monospacedDigit()
                .foregroundStyle(Color.srForegroundMuted)
            if status.outOfPlanYuan > 0 {
                outOfPlanRow(status)
            }
            if let advice = card.advice {
                adviceRow(advice)
            }
        }
    }

    /// 已结束：总结 + 计外行 + 再来一期（budget.js:116-123）。
    private func endedBody(_ card: BudgetPlanCardData, _ status: CustomPlanStatus) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.sm) {
            Text("共花 ¥\(BudgetEngine.fmtMoney(status.spentYuan)) / ¥\(BudgetEngine.fmtMoney(status.budgetYuan))（\(status.pct)%）")
                .srFont(.sm)
                .monospacedDigit()
                .foregroundStyle(Color.srForegroundMuted)
            if status.outOfPlanYuan > 0 {
                outOfPlanRow(status)
            }
            SRButton("再来一期", icon: "arrow.clockwise", style: .ghost, size: .sm) {
                onRenew(card.plan)
            }
            .accessibilityLabel("为「\(card.nameText)」再来一期")
        }
    }

    // MARK: 行组件

    private func progressRow(label: String, pct: Int, progress: Double,
                             tint: Color) -> some View {
        HStack(spacing: SRSpacing.sm) {
            Text(label)
                .srFont(.xs)
                .foregroundStyle(Color.srForegroundSubtle)
                .frame(width: 28, alignment: .leading)
            SRProgressBar(progress: progress, tint: tint)
            Text("\(pct)%")
                .srFont(.xs)
                .monospacedDigit()
                .foregroundStyle(Color.srForegroundMuted)
                .frame(width: 36, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)进度 \(pct)%")
    }

    /// 花销进度色：已超/超节奏 → danger；花销进度超过时间进度 → warning；
    /// 其余 → success（与 BudgetProgressCard.statusColor 同源，加时间对比档）。
    private func spendTint(_ status: CustomPlanStatus) -> Color {
        if status.remainingYuan < 0 || status.overProjected { return .srDanger }
        if status.spentYuan / status.budgetYuan > status.timeProgress { return .srWarning }
        return .srSuccess
    }

    /// 剩余额度文案：含「今天起日均还能花」（负剩余不给日均指引）。
    private func quotaText(_ status: CustomPlanStatus) -> String {
        if status.remainingYuan < 0 {
            return "已超 ¥\(BudgetEngine.fmtMoney(-status.remainingYuan)) · 余 \(status.daysLeft) 天"
        }
        return "剩 ¥\(BudgetEngine.fmtMoney(status.remainingYuan)) · 余 \(status.daysLeft) 天 · 今天起日均 ¥\(BudgetEngine.fmtMoney(max(0, status.perDayLeftYuan)))"
    }

    /// 计外行（budget.js:105「另有计划外 ¥X 不占额度」+ 计外徽标）。
    private func outOfPlanRow(_ status: CustomPlanStatus) -> some View {
        HStack(spacing: SRSpacing.xs) {
            SRBadge("计外", tone: .warning)
            Text("另有 \(status.outOfPlanCount) 笔计划外 ¥\(BudgetEngine.fmtMoney(status.outOfPlanYuan))，计总账、不占本期额度")
                .srFont(.sm)
                .monospacedDigit()
                .foregroundStyle(Color.srForegroundMuted)
        }
        .accessibilityElement(children: .combine)
    }

    /// 拉回建议行（planAdvice 产物；超支/临期时才有）。
    private func adviceRow(_ advice: String) -> some View {
        HStack(alignment: .top, spacing: SRSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.sr(.xs))
                .foregroundStyle(Color.srWarning)
                .padding(.top, 2)
            Text(advice)
                .srFont(.sm)
                .foregroundStyle(Color.srWarning)
        }
        .accessibilityElement(children: .combine)
    }
}
