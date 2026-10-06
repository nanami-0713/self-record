import Charts
import SelfRecordCore
import SwiftUI

// MARK: - 预算页（design.md §6「预算」Tab：BudgetView）
//
// 结构对齐 lifttime budget.js:15-50 的卡片序：预算进度（周/月状态条 + 节奏预测）→
// 自定义周期计划（三态计划卡 + 双进度条 + 再来一期，BudgetPlansSection）→
// 记一笔 → 最近开销（auto 徽标）→ 开销趋势与分类构成（Swift Charts 每日堆叠）→
// 吃的值不值（蛋白质性价比 + 参考成本对照）→ 本周开销诊断（外卖聚餐/补剂占比
// + 规则建议）。数据全部来自 `AppModel.budgetPageData` / `budgetPlanCards`
// （Core 引擎产物），本文件只做排版与交互接线。
//
// SwiftUI 宏禁令（§8 约定 5）：无 @State；页面态集中在 BudgetViewState
// （ObservableObject），Toast 走 SRToastCenter（DesignSystem 组件）。
// 自定义周期计划数组也由此处状态持有（AppModel 为冻结外壳、不能加
// @Published 计划数组——extension 不允许存储属性；动作经 AppModel+Budget）。

/// 预算页状态（ObservableObject 路径；宏禁令下的页面态收敛点）。
final class BudgetViewState: ObservableObject {
    /// 周 / 月切换。
    @Published var scope: BudgetPeriodScope = .week
    /// 记一笔 sheet（非 nil 即呈现；sheet(item:)）。
    @Published var entrySheet: ExpenseFormModel?
    /// 列表上下文菜单发起的删除确认。
    @Published var pendingDeleteID: UUID?
    /// 自定义周期计划快照（onAppear 自 DataStore 载入；动作后以返回值更新）。
    @Published var plans: [CustomBudgetPlan] = []
    /// 计划新建/编辑 sheet（非 nil 即呈现）。
    @Published var planSheet: PlanFormModel?
    /// 计划卡删除确认。
    @Published var pendingDeletePlanID: UUID?
}

public struct BudgetView: View {

    @ObservedObject private var model: AppModel
    @StateObject private var state: BudgetViewState
    @StateObject private var toast: SRToastCenter

    public init(model: AppModel) {
        self.model = model
        _state = StateObject(wrappedValue: BudgetViewState())
        _toast = StateObject(wrappedValue: SRToastCenter())
    }

    public var body: some View {
        let data = model.budgetPageData(scope: state.scope)
        return ScrollView {
            VStack(alignment: .leading, spacing: SRSpacing.lg) {
                Text("预算")
                    .srFont(.xl, .semibold)
                SRSegmented(options: BudgetPeriodScope.allCases,
                            selection: $state.scope) { $0.title }
                BudgetProgressCard(data: data) { scope in
                    state.scope = scope
                }
                BudgetPlansCard(
                    cards: model.budgetPlanCards(plans: state.plans),
                    onAdd: { state.planSheet = PlanFormModel(newAt: Date()) },
                    onEdit: { plan in state.planSheet = PlanFormModel(editing: plan) },
                    onDelete: { plan in state.pendingDeletePlanID = plan.id },
                    onRenew: { plan in renewPlan(plan) })
                addExpenseCard
                BudgetExpensesCard(data: data,
                                   onEdit: { openEditor(for: $0) },
                                   onAutoTap: { showAutoHint() },
                                   onDelete: { requestDelete($0) })
                BudgetTrendCard(data: data)
                BudgetEconomyCard(data: data)
                BudgetDiagnosticsCard(data: data)
            }
            .padding(SRSpacing.lg)
        }
        .background(Color.srBackground)
        .sheet(item: $state.entrySheet) { form in
            ExpenseEntrySheet(
                form: form,
                onSubmit: { submit($0) },
                onDelete: { remove(id: $0) },
                onCancel: { state.entrySheet = nil })
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled(true)      // 表单防误关（§6 全局交互约定）
        }
        .sheet(item: $state.planSheet) { form in
            CustomPlanSheet(
                form: form,
                onSubmit: { submitPlan($0) },
                onDelete: { removePlan(id: $0) },
                onCancel: { state.planSheet = nil })
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled(true)      // 表单防误关（§6 全局交互约定）
        }
        .confirmationDialog("删除这笔开销？", isPresented: deleteConfirmVisible,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let id = state.pendingDeleteID { remove(id: id) }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除这个计划？", isPresented: planDeleteConfirmVisible,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let id = state.pendingDeletePlanID { removePlan(id: id) }
            }
            Button("取消", role: .cancel) {}
        }
        .srToastHost(toast)
        .onAppear {                                   // 计划数组自 DataStore 载入（§9-6）
            Task { state.plans = await model.loadBudgetPlans() }
        }
    }

    // MARK: 记一笔入口卡（budget.js:21-24）

    private var addExpenseCard: some View {
        SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                SRButton("记一笔开销", icon: "plus", style: .primary) {
                    state.entrySheet = ExpenseFormModel(newAt: Date())
                }
                Text("在「饮食」页记餐时填了花费的，会自动计入这里的「记餐开销」。")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 动作接线

    /// 打开编辑表单（仅手动条目；auto 项源头在 DietEntry，点按走引导提示）。
    private func openEditor(for item: MergedExpense) {
        guard !item.isAuto, let id = UUID(uuidString: item.id),
              let expense = model.expense(id: id) else { return }
        state.entrySheet = ExpenseFormModel(editing: expense)
    }

    /// auto 项点按引导（lifttime budget.js:171-173 同文案语义）。
    private func showAutoHint() {
        toast.show("这笔来自饮食记录", message: "去「饮食」页编辑对应那餐", severity: .info)
    }

    private func requestDelete(_ item: MergedExpense) {
        guard !item.isAuto, let id = UUID(uuidString: item.id) else { return }
        state.pendingDeleteID = id
    }

    private var deleteConfirmVisible: Binding<Bool> {
        Binding(get: { state.pendingDeleteID != nil },
                set: { if !$0 { state.pendingDeleteID = nil } })
    }

    private var planDeleteConfirmVisible: Binding<Bool> {
        Binding(get: { state.pendingDeletePlanID != nil },
                set: { if !$0 { state.pendingDeletePlanID = nil } })
    }

    private func submit(_ draft: ExpenseDraft) {
        Task {
            if let saved = await model.saveExpense(draft) {
                let detail = "¥" + BudgetEngine.fmtMoney(saved.amountYuan)
                    + " · " + BudgetEngine.categoryLabel(saved.category ?? .other)
                    + (saved.isOutOfPlan ? "（计划外）" : "")
                toast.show(draft.editingID == nil ? "已记录：\(detail)" : "开销已更新",
                           severity: .success)
            }
            state.entrySheet = nil
        }
    }

    private func remove(id: UUID) {
        state.pendingDeleteID = nil
        state.entrySheet = nil
        Task {
            await model.deleteExpense(id: id)
            toast.show("已删除", severity: .success)
        }
    }

    // MARK: 自定义周期计划动作（budget.js:85-99/:344-360 的接线形态）

    /// 新建/更新（非法输入 AppModel 侧拦下 → 仅关 sheet 不弹成功反馈）。
    private func submitPlan(_ draft: BudgetPlanDraft) {
        Task {
            if let plans = await model.saveBudgetPlan(draft) {
                state.plans = plans
                let calendar = DayCalendar()
                let saved = draft.editingID == nil ? plans.last
                    : plans.first { $0.id == draft.editingID }
                if let saved {
                    let name = BudgetEngine.planDisplayName(saved, calendar: calendar)
                    let days = BudgetEngine.planDays(from: saved.startDay, to: saved.endDay,
                                                      calendar: calendar)
                    if draft.editingID == nil {
                        toast.show("已创建「\(name)」", message: "\(days) 天 · ¥\(BudgetEngine.fmtMoney(saved.amountYuan))",
                                   severity: .success)
                    } else {
                        toast.show("计划已更新", severity: .success)
                    }
                }
            }
            state.planSheet = nil
        }
    }

    private func removePlan(id: UUID) {
        state.pendingDeletePlanID = nil
        state.planSheet = nil
        Task {
            if let plans = await model.deleteBudgetPlan(id: id) {
                state.plans = plans
                toast.show("已删除计划", severity: .success)
            }
        }
    }

    /// 再来一期（等长等额、紧接上一期结束日之后；budget.js:90-97 的入口）。
    private func renewPlan(_ plan: CustomBudgetPlan) {
        Task {
            if let result = await model.renewBudgetPlan(id: plan.id) {
                state.plans = result.plans
                let calendar = DayCalendar()
                let name = BudgetEngine.planDisplayName(result.renewed, calendar: calendar)
                let start = BudgetDayLabel.cn(result.renewed.startDay)
                toast.show("「\(name)」已开启新一期", message: "\(start) 起 · 等长等额",
                           severity: .success)
            }
        }
    }
}

// MARK: - 分类取色（展示层常量）

/// 开销分类 → ChartHue（§7.1 图表白名单）。对齐 §4.1 默认时间分类的用色习惯：
/// 补剂 teal、餐食 violet、食材 green；「其他」走 neutral 派生档（§4.1）。
extension ExpenseCategory {
    var budgetHue: ChartHue {
        switch self {
        case .meals: .violet
        case .groceries: .green
        case .takeout: .ochre
        case .social: .rose
        case .supplement: .teal
        case .fitness: .rust
        case .other: .neutral
        }
    }
}

// MARK: - 预算进度卡（budget.js:54-75 / statusBar :133-146）

struct BudgetProgressCard: View {

    let data: BudgetPageData
    let onSwitchScope: (BudgetPeriodScope) -> Void

    var body: some View {
        SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.lg) {
                if let status = data.status {
                    statusView(status)
                } else {
                    noBudgetView
                }
                if let other = data.otherStatus {
                    otherScopeRow(other)
                }
            }
        }
    }

    private func statusView(_ status: BudgetStatus) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(data.scope.title)预算")
                    .srFont(.lg, .semibold)
                Spacer()
                Text("\(status.pct)%")
                    .srFont(.lg, .semibold)
                    .monospacedDigit()
                    .foregroundStyle(statusColor(status))
            }
            Text(data.spanText)
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)
            SRProgressBar(progress: Double(status.pct) / 100,
                          tint: statusColor(status), thickness: 8)
            HStack(alignment: .firstTextBaseline) {
                Text("¥\(BudgetEngine.fmtMoney(status.spentYuan)) / ¥\(BudgetEngine.fmtMoney(status.budgetYuan))")
                    .srFont(.md)
                    .monospacedDigit()
                Spacer()
                Text(remainingText(status))
                    .srFont(.sm)
                    .monospacedDigit()
                    .foregroundStyle(Color.srForegroundMuted)
            }
            paceRow(status)
            if status.outOfPlanYuan > 0 {
                Text("另有 \(status.outOfPlanCount) 笔计划外 ¥\(BudgetEngine.fmtMoney(status.outOfPlanYuan))，计总账、不占周期额度。")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
            }
        }
    }

    /// 节奏预测（finance.js:148-165 的 projected；超速时给出警示徽标）。
    private func paceRow(_ status: BudgetStatus) -> some View {
        HStack(spacing: SRSpacing.sm) {
            Text("按当前节奏，\(data.scope.title)预计 ¥\(BudgetEngine.fmtMoney(status.projectedYuan))")
                .srFont(.sm)
                .monospacedDigit()
                .foregroundStyle(Color.srForegroundMuted)
            if status.overProjected {
                SRBadge("节奏超支", tone: .danger)
            }
        }
    }

    private var noBudgetView: some View {
        VStack(alignment: .leading, spacing: SRSpacing.sm) {
            Text("\(data.scope.title)预算未设置")
                .srFont(.lg, .semibold)
            Text("\(data.scope.title)已花 ¥\(BudgetEngine.fmtMoney(data.spanSummary.totalYuan))（统计口径含计划外）。在「设置」页填写周/月预算后，这里帮你盯节奏。")
                .srFont(.base)
                .foregroundStyle(Color.srForegroundMuted)
        }
    }

    /// 另一周期紧凑行（点按切换；lifttime 进度区周/月双状态条的信息压缩形态）。
    private func otherScopeRow(_ other: BudgetStatus) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.md) {
            Rectangle().fill(Color.srBorder).frame(height: 1)
            Button {
                onSwitchScope(data.scope == .week ? .month : .week)
            } label: {
                HStack(spacing: SRSpacing.xs) {
                    Text("\(data.otherScopeTitle)预算已用 \(other.pct)%")
                        .srFont(.sm)
                        .monospacedDigit()
                    Text(other.remainingYuan >= 0
                         ? "剩 ¥\(BudgetEngine.fmtMoney(other.remainingYuan))"
                         : "已超 ¥\(BudgetEngine.fmtMoney(-other.remainingYuan))")
                        .srFont(.sm)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.sr(.xs))
                        .foregroundStyle(Color.srForegroundSubtle)
                }
                .foregroundStyle(Color.srForegroundMuted)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(data.otherScopeTitle)预算已用 \(other.pct)%，点按切换查看")
        }
    }

    /// 状态色（lifttime budget.js:134：超速红 / 已用 ≥85% 琥珀 / 其余绿）。
    private func statusColor(_ status: BudgetStatus) -> Color {
        if status.overProjected { return .srDanger }
        if status.pct >= 85 { return .srWarning }
        return .srSuccess
    }

    /// 剩余额度文案（budget.js:135-137；日均负值收敛为 0）。
    private func remainingText(_ status: BudgetStatus) -> String {
        if status.remainingYuan < 0 {
            return "已超 ¥\(BudgetEngine.fmtMoney(-status.remainingYuan))"
        }
        return "剩 ¥\(BudgetEngine.fmtMoney(status.remainingYuan)) · 余 \(status.daysLeft) 天 · 日均 ¥\(BudgetEngine.fmtMoney(max(0, status.perDayLeftYuan)))"
    }
}

// MARK: - 最近开销卡（budget.js:150-177）

struct BudgetExpensesCard: View {

    let data: BudgetPageData
    let onEdit: (MergedExpense) -> Void
    let onAutoTap: () -> Void
    let onDelete: (MergedExpense) -> Void

    var body: some View {
        SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("最近开销")
                        .srFont(.lg, .semibold)
                    Spacer()
                    if data.allTotalYuan > 0 {
                        Text("共 ¥\(BudgetEngine.fmtMoney(data.allTotalYuan))")
                            .srFont(.sm)
                            .monospacedDigit()
                            .foregroundStyle(Color.srForegroundMuted)
                    }
                }
                if data.recentExpenses.isEmpty {
                    Text("还没有开销记录")
                        .srFont(.base)
                        .foregroundStyle(Color.srForegroundMuted)
                    Text("点上面「记一笔开销」记第一笔；在「饮食」页记餐时填花费，也会自动出现在这里。")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundSubtle)
                } else {
                    VStack(spacing: 0) {
                        ForEach(data.recentExpenses) { item in
                            row(item)
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: MergedExpense) -> some View {
        Button {
            if item.isAuto { onAutoTap() } else { onEdit(item) }
        } label: {
            HStack(spacing: SRSpacing.md) {
                RoundedRectangle(cornerRadius: SRRadius.sm, style: .continuous)
                    .srChartHue(item.category.budgetHue)
                    .frame(width: 3, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SRSpacing.xs) {
                        Text(BudgetEngine.categoryLabel(item.category))
                            .srFont(.base, .medium)
                        if item.isOutOfPlan {
                            SRBadge("计外", tone: .warning)
                        }
                        if item.isAuto {
                            SRBadge("自动", tone: .neutral)
                        }
                    }
                    Text(subtitle(item))
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: SRSpacing.sm)
                Text("¥\(BudgetEngine.fmtMoney(item.amountYuan))")
                    .srFont(.base)
                    .monospacedDigit()
            }
            .padding(.vertical, SRSpacing.sm)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {                              // 手动条目：编辑 / 删除（iOS 习惯）
            if !item.isAuto {
                Button("编辑") { onEdit(item) }
                Button("删除", role: .destructive) { onDelete(item) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(item.isAuto ? "来自饮食记录" : "点按编辑")
    }

    private func subtitle(_ item: MergedExpense) -> String {
        let stamp = BudgetDayLabel.timestamp(item.date, calendar: data.calendar)
        return item.note.isEmpty ? stamp : "\(item.note) · \(stamp)"
    }
}

// MARK: - 开销趋势与分类构成（budget.js:398-419）

struct BudgetTrendCard: View {

    let data: BudgetPageData
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                Text("开销趋势与分类构成")
                    .srFont(.lg, .semibold)
                if data.spanSummary.count == 0 {
                    Text("\(data.scope.title)还没有开销记录")
                        .srFont(.base)
                        .foregroundStyle(Color.srForegroundMuted)
                } else {
                    SRChartContainer(height: 180) {
                        Chart(data.dayPoints) { point in
                            BarMark(x: .value("日期", point.day),
                                    y: .value("金额", point.amount))
                                .foregroundStyle(SRChartPalette.hue(point.category.budgetHue, scheme))
                        }
                        .srYAxisGrid()
                        .chartXAxis {
                            AxisMarks(values: thinnedLabels) { _ in
                                AxisValueLabel()
                                    .font(.sr(.sm))
                                    .foregroundStyle(Color.srForegroundMuted)
                            }
                        }
                        .chartLegend(.hidden)
                    }
                    legend
                }
            }
        }
    }

    /// x 轴抽稀：最多约 7 个标签（周全显、月每 3 天左右一个）。
    private var thinnedLabels: [String] {
        let count = data.axisLabels.count
        guard count > 7 else { return data.axisLabels }
        let stride = (count + 6) / 7
        return data.axisLabels.enumerated()
            .filter { $0.offset % stride == 0 || $0.offset == count - 1 }
            .map(\.element)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: SRSpacing.sm) {
            ForEach(data.categoryRows) { row in
                HStack(spacing: SRSpacing.sm) {
                    Circle()
                        .srChartHue(row.category.budgetHue)
                        .frame(width: 8, height: 8)
                    Text(BudgetEngine.categoryLabel(row.category))
                        .srFont(.base)
                    Spacer()
                    Text("¥\(BudgetEngine.fmtMoney(row.totalYuan))")
                        .srFont(.base)
                        .monospacedDigit()
                    Text("\(Int((row.share * 100).rounded()))%")
                        .srFont(.sm)
                        .monospacedDigit()
                        .foregroundStyle(Color.srForegroundMuted)
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - 蛋白质性价比卡（budget.js:421-432）

struct BudgetEconomyCard: View {

    let data: BudgetPageData

    var body: some View {
        SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                Text("吃的值不值")
                    .srFont(.lg, .semibold)
                if let eco = data.eco {
                    VStack(alignment: .leading, spacing: SRSpacing.xs) {
                        Text("每 10g 蛋白质成本")
                            .srFont(.sm)
                            .foregroundStyle(Color.srForegroundMuted)
                        HStack(alignment: .firstTextBaseline, spacing: SRSpacing.xs) {
                            Text(eco.per10gYuan.map { "¥\(BudgetEngine.fmtMoney($0))" } ?? "—")
                                .srFont(.xxl, .semibold)
                                .monospacedDigit()
                            Text("/10g 蛋白质")
                                .srFont(.md)
                                .foregroundStyle(Color.srForegroundMuted)
                        }
                        Text("\(data.scope.title)记餐花费 ¥\(BudgetEngine.fmtMoney(eco.costYuan))（\(eco.meals) 餐），换来蛋白质约 \(Int(eco.proteinG.rounded()))g。")
                            .srFont(.base)
                            .foregroundStyle(Color.srForegroundMuted)
                    }
                    referenceRows(mine: eco.per10gYuan)
                } else {
                    Text("在「饮食」页记餐时填上花费，这里就能算出你每 10g 蛋白质花多少钱。")
                        .srFont(.base)
                        .foregroundStyle(Color.srForegroundMuted)
                }
                if data.proteinTrackedDays > 0 {
                    Text("近 7 天蛋白质达标 \(data.proteinHitDays) / \(data.proteinTrackedDays) 天（\(Int(((data.proteinHitRate ?? 0) * 100).rounded()))%）——全记录日口径。")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundSubtle)
                }
            }
        }
    }

    /// 参考成本对照（finance.js:18-23 PROTEIN_PRICE_REF；你的记餐条用主色强调）。
    private func referenceRows(mine: Double?) -> some View {
        let refs = BudgetEngine.proteinPriceRef
        let scale = max(mine ?? 0, refs.map(\.per10gYuan).max() ?? 1, 0.01)
        return VStack(alignment: .leading, spacing: SRSpacing.sm) {
            Text("参考成本（每 10g 蛋白质）")
                .srFont(.xs)
                .foregroundStyle(Color.srForegroundSubtle)
            if let mine {
                comparisonRow(label: "你的记餐", value: mine,
                              progress: mine / scale, tint: .srAccent, emphasized: true)
            }
            ForEach(refs, id: \.name) { ref in
                comparisonRow(label: ref.name, value: ref.per10gYuan,
                              progress: ref.per10gYuan / scale,
                              tint: .srForegroundSubtle, emphasized: false)
            }
        }
    }

    private func comparisonRow(label: String, value: Double, progress: Double,
                               tint: Color, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            HStack {
                Text(label)
                    .srFont(emphasized ? .base : .sm, emphasized ? .medium : .regular)
                    .foregroundStyle(emphasized ? Color.srForeground : Color.srForegroundMuted)
                Spacer()
                Text("¥\(BudgetEngine.fmtMoney(value))")
                    .srFont(emphasized ? .base : .sm, emphasized ? .semibold : .regular)
                    .monospacedDigit()
                    .foregroundStyle(emphasized ? Color.srForeground : Color.srForegroundMuted)
            }
            SRProgressBar(progress: progress, tint: tint)
        }
    }
}

// MARK: - 本周开销诊断卡（budget.js:434-452 的建议 + §3.5 两条占比诊断）

struct BudgetDiagnosticsCard: View {

    let data: BudgetPageData

    var body: some View {
        SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                Text("本周开销诊断")
                    .srFont(.lg, .semibold)
                shareRow(label: "外卖/聚餐占餐饮花费", share: data.takeoutSocialShare)
                shareRow(label: "补剂占本周总开销", share: data.supplementShare)
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(Color.srBorder).frame(height: 1)
                }
                .padding(.vertical, SRSpacing.xs)
                Text("建议")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
                ForEach(data.advice, id: \.self) { line in
                    HStack(alignment: .top, spacing: SRSpacing.sm) {
                        SRDotBadge(Color.srForegroundMuted)
                            .padding(.top, 5)
                        Text(line)
                            .srFont(.sm)
                            .foregroundStyle(Color.srForegroundMuted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// 占比行（阈值判定在 BudgetEngine.budgetAdvice 内——本行只呈现数值）。
    private func shareRow(label: String, share: Double?) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            HStack {
                Text(label)
                    .srFont(.base)
                Spacer()
                Text(share.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .srFont(.base, .medium)
                    .monospacedDigit()
            }
            SRProgressBar(progress: share ?? 0, tint: .srAccent)
        }
    }
}
