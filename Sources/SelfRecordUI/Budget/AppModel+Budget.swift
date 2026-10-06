import Foundation
import SelfRecordCore

// MARK: - budget 分组（design.md §6 页面地图「预算」Tab / §8 约定 4）
//
// 界面工程师工作区：Sources/SelfRecordUI/Budget/ 由 budget 分组工程师独占。
// 页面：BudgetView（周/月切换、进度条 + 节奏预测、开销流列表 + auto 徽标、
// 蛋白质性价比卡、外卖聚餐/补剂占比诊断、自定义周期计划区块）+
// ExpenseEntrySheet（记一笔：金额/分类（不含 .meals）/计划外开关）+
// BudgetPlansSection（计划卡 + CustomPlanSheet 新建/编辑/再来一期）。
//
// 约定（与 today 分组同款，design.md §8 约定 4/5）：
//   - 动作与取数方法放本文件（extension AppModel），不改 AppModel.swift（冻结物 C）；
//   - 数据一律出自 SelfRecordCore 引擎：BudgetEngine.status / proteinEconomy /
//     mergedExpenses / summarize / outOfPlan / budgetAdvice（§2.1 冻结物 B 清单），
//     跨域 proteinHitRate 经参数注入通道组装——DietEngine.periodDiet 的
//     `proteinHitDays / daysTracked`（**全记录日**达标率，B1 口径；
//     lifttime budget.js:423-424），不调 diet 内部函数；
//   - 本层只做「域快照 → 引擎入参」的接线与展示分组，视图零业务逻辑；
//   - SwiftUI 宏禁令（§8 约定 5）：禁 @State 等；状态走 ObservableObject +
//     @Published（@ObservedObject / @StateObject propertyWrapper 路径）。

// MARK: - 周期切换

/// 周 / 月切换（SRSegmented 选项；lifttime budget.js:13 `view = 'week' | 'month'`）。
public enum BudgetPeriodScope: String, Hashable, CaseIterable, Identifiable, Sendable {
    case week
    case month

    public var id: String { rawValue }

    /// 分段标题（lifttime budget.js:392「本周 / 本月」）。
    public var title: String { self == .week ? "本周" : "本月" }
}

// MARK: - 表单产物

/// 记一笔表单的提交产物（View → AppModel 的值快照；写入由引擎侧校验语义兜底）。
public struct ExpenseDraft: Sendable, Equatable {
    /// nil = 新增；非 nil = 编辑该条手动开销。
    public var editingID: UUID?
    public var date: Date
    public var amountYuan: Double
    public var category: ExpenseCategory
    /// 空串语义：落库时归 nil。
    public var note: String?
    public var isOutOfPlan: Bool

    public init(editingID: UUID? = nil, date: Date, amountYuan: Double,
                category: ExpenseCategory, note: String?, isOutOfPlan: Bool) {
        self.editingID = editingID
        self.date = date
        self.amountYuan = amountYuan
        self.category = category
        self.note = note
        self.isOutOfPlan = isOutOfPlan
    }
}

/// 自定义周期计划表单的提交产物（View → AppModel 的值快照）。
/// 起止为 Date（DatePicker 产物），落库时按注入日历归一为日键（含首尾）。
public struct BudgetPlanDraft: Sendable, Equatable {
    /// nil = 新建；非 nil = 编辑该计划。
    public var editingID: UUID?
    /// 空白 → 落库回退「N天计划」（budget.js:352 同语义）。
    public var name: String?
    public var amountYuan: Double
    public var start: Date
    public var end: Date

    public init(editingID: UUID? = nil, name: String?, amountYuan: Double,
                start: Date, end: Date) {
        self.editingID = editingID
        self.name = name
        self.amountYuan = amountYuan
        self.start = start
        self.end = end
    }
}

// MARK: - 页面数据快照

/// 每日堆叠柱的单点（开销趋势卡；空日用 amount = 0 的占位点撑住 x 轴刻度，
/// 等价 lifttime budget.js:399-411 逐日全序列）。
struct BudgetDayPoint: Identifiable, Sendable {
    /// 轴标签「10/6」。
    let day: String
    let category: ExpenseCategory
    let amount: Double
    var id: String { day + ":" + category.rawValue }
}

/// 分类构成行（趋势卡图例；share = 占周期总开销比例，统计口径含计划外）。
struct BudgetCategoryRow: Identifiable, Sendable {
    let category: ExpenseCategory
    let totalYuan: Double
    let share: Double
    var id: String { category.rawValue }
}

/// 自定义周期计划卡的单卡数据（由 `AppModel.budgetPlanCards` 组装；
/// 引擎产物 + 展示串，视图零业务逻辑）。
struct BudgetPlanCardData: Identifiable, Sendable {
    let plan: CustomBudgetPlan
    /// 计划状态（结构非法 → nil，净化后不应出现；视图按空态兜底）。
    let status: CustomPlanStatus?
    /// 拉回建议（planAdvice 产物；未开始/已结束/健康 → nil）。
    let advice: String?
    /// 展示名（回退「N天计划」）。
    let nameText: String
    /// 区间标签「9/1 – 9/14 · 14 天」。
    let rangeText: String

    var id: UUID { plan.id }
}

/// BudgetView 一次渲染所需的全部数据（由 `AppModel.budgetPageData` 组装）。
/// 全部字段出自 Core 引擎产物；本层只做展示分组，不产出口径。
struct BudgetPageData: Sendable {
    let scope: BudgetPeriodScope
    /// 区间起止展示串「10月6日 – 10月12日」。
    let spanText: String
    /// 选中周期的预算状态（未设预算 → nil；双口径见 BudgetStatus 注释）。
    let status: BudgetStatus?
    /// 另一周期的预算状态（未设 → nil；进度卡底部紧凑行）。
    let otherStatus: BudgetStatus?
    let otherScopeTitle: String
    /// 选中周期合并开销流汇总（统计口径，含计划外——空态与分类构成用）。
    let spanSummary: SpendSummary
    let outOfPlan: OutOfPlanSummary
    /// 蛋白质性价比（选中区间；lifttime budget.js:422 用当前 view 的 range）。
    let eco: ProteinEconomy?
    /// 近 7 天全记录日蛋白达标（B1 注入口径；budget.js:423-424）。
    let proteinHitDays: Int
    let proteinTrackedDays: Int
    let proteinHitRate: Double?
    let dayPoints: [BudgetDayPoint]
    let axisLabels: [String]
    let categoryRows: [BudgetCategoryRow]
    /// 最近开销（新→旧前 30 笔，lifttime budget.js:159 slice(0, 30)）。
    let recentExpenses: [MergedExpense]
    /// 全部合并开销总额（列表头「共 ¥X」，budget.js:154）。
    let allTotalYuan: Double
    /// 规则引擎建议（≤4 条；含外卖聚餐/补剂占比诊断文案）。
    let advice: [String]
    /// 外卖+聚餐 / 餐饮四档（meals+groceries+takeout+social），本周窗口；
    /// 分母为 0 → nil（finance.js:196-198 口径，阈值判定在引擎内）。
    let takeoutSocialShare: Double?
    /// 补剂 / 本周总开销；分母为 0 → nil（finance.js:212-214 口径）。
    let supplementShare: Double?
    /// 行时间戳格式化用（DayCalendar 随快照走，视图不私造时区语义）。
    let calendar: DayCalendar
}

// MARK: - 取数与动作

extension AppModel {

    /// 组装预算页数据（每帧调用，全部为内存值类型快照上的纯引擎调用）。
    ///
    /// 区间口径（lifttime budget.js:380-453）：
    /// - 选中 span = now 所在自然周（周一起）/自然月；
    /// - 蛋白性价比 = 选中 span；
    /// - proteinHitRate = `periodDiet(近 7 天)`（budget.js:423 的
    ///   `min(7, 区间天数)`——周/月两态下恒为自 now 往回 7 天）；
    /// - 建议与占比诊断 = 本周汇总 + 周/月双状态（budget.js:435-443）。
    func budgetPageData(scope: BudgetPeriodScope, now: Date = Date()) -> BudgetPageData {
        let calendar = DayCalendar()
        let span: DateSpan = scope == .week
            ? BudgetEngine.weekSpan(containing: now, calendar: calendar)
            : BudgetEngine.monthSpan(containing: now, calendar: calendar)
        let weekSpan = BudgetEngine.weekSpan(containing: now, calendar: calendar)
        let monthSpan = BudgetEngine.monthSpan(containing: now, calendar: calendar)

        let all = BudgetEngine.mergedExpenses(expenses, dietEntries: dietEntries)
        let inSpan = BudgetEngine.inRange(all, in: span, calendar: calendar)
        let spanSummary = BudgetEngine.summarize(inSpan, calendar: calendar)
        let outSummary = BudgetEngine.outOfPlan(inSpan)

        let weekStatus = BudgetEngine.status(budgetYuan: settings.weeklyBudgetYuan, span: weekSpan,
                                             expenses: expenses, dietEntries: dietEntries,
                                             calendar: calendar, now: now)
        let monthStatus = BudgetEngine.status(budgetYuan: settings.monthlyBudgetYuan, span: monthSpan,
                                              expenses: expenses, dietEntries: dietEntries,
                                              calendar: calendar, now: now)
        let selectedStatus = scope == .week ? weekStatus : monthStatus
        let otherStatus = scope == .week ? monthStatus : weekStatus

        // —— 饮食联动（budget.js:421-424）——
        let eco = BudgetEngine.proteinEconomy(dietEntries: dietEntries, in: span, calendar: calendar)
        let today = calendar.dayKey(for: now)
        let diet = DietEngine.periodDiet(
            dietEntries, workouts: workouts,
            in: DateSpan(startDay: calendar.addingDays(-6, to: today) ?? today, endDay: today),
            bodyweightKg: settings.bodyweightKg, calendar: calendar)
        let hitRate: Double? = diet.daysTracked > 0
            ? Double(diet.proteinHitDays) / Double(diet.daysTracked) : nil   // B1 全记录日口径

        // —— 建议（budget.js:435-443：周/月双状态 + 本周汇总 + 选中区间性价比）——
        let weekSummary: SpendSummary = scope == .week
            ? spanSummary
            : BudgetEngine.summarize(BudgetEngine.inRange(all, in: weekSpan, calendar: calendar),
                                     calendar: calendar)
        let advice = BudgetEngine.budgetAdvice(week: weekStatus, month: monthStatus,
                                               sumWeek: weekSummary, proteinEconomy: eco,
                                               proteinHitRate: hitRate)

        // —— 占比诊断（finance.js:196-198 / :212-214 的分母分子；阈值在引擎内）——
        let byCat = weekSummary.byCat
        let foodSpend = byCat[.meals, default: 0] + byCat[.groceries, default: 0]
            + byCat[.takeout, default: 0] + byCat[.social, default: 0]
        let takeoutSocial = byCat[.takeout, default: 0] + byCat[.social, default: 0]
        let takeoutShare: Double? = foodSpend > 0 ? takeoutSocial / foodSpend : nil
        let suppShare: Double? = weekSummary.totalYuan > 0
            ? byCat[.supplement, default: 0] / weekSummary.totalYuan : nil

        // —— 每日堆叠（budget.js:399-411：日序列截至今天，空日保留占位）——
        var byDay: [String: [MergedExpense]] = [:]
        for item in inSpan {
            byDay[calendar.dayKey(for: item.date).rawValue, default: []].append(item)
        }
        var dayPoints: [BudgetDayPoint] = []
        var axisLabels: [String] = []
        let lastRaw = min(span.endDay.rawValue, today.rawValue)
        var cursor = span.startDay
        while cursor.rawValue <= lastRaw {
            let label = BudgetDayLabel.short(cursor)
            axisLabels.append(label)
            let dayItems = byDay[cursor.rawValue, default: []]
            if dayItems.isEmpty {
                dayPoints.append(BudgetDayPoint(day: label, category: .other, amount: 0))
            } else {
                var dayByCat: [ExpenseCategory: Double] = [:]
                for item in dayItems { dayByCat[item.category, default: 0] += item.amountYuan }
                for cat in ExpenseCategory.allCases where (dayByCat[cat] ?? 0) > 0 {
                    dayPoints.append(BudgetDayPoint(day: label, category: cat,
                                                    amount: dayByCat[cat, default: 0]))
                }
            }
            guard let next = calendar.addingDays(1, to: cursor) else { break }
            cursor = next
        }

        let categoryRows = spanSummary.byCat
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { category, value in
                BudgetCategoryRow(category: category, totalYuan: value,
                                  share: spanSummary.totalYuan > 0
                                      ? value / spanSummary.totalYuan : 0)
            }

        return BudgetPageData(
            scope: scope,
            spanText: BudgetDayLabel.range(span),
            status: selectedStatus,
            otherStatus: otherStatus,
            otherScopeTitle: (scope == .week ? BudgetPeriodScope.month : BudgetPeriodScope.week).title,
            spanSummary: spanSummary,
            outOfPlan: outSummary,
            eco: eco,
            proteinHitDays: diet.proteinHitDays,
            proteinTrackedDays: diet.daysTracked,
            proteinHitRate: hitRate,
            dayPoints: dayPoints,
            axisLabels: axisLabels,
            categoryRows: categoryRows,
            recentExpenses: Array(all.prefix(30)),
            allTotalYuan: BudgetEngine.summarize(all, calendar: calendar).totalYuan,
            advice: advice,
            takeoutSocialShare: takeoutShare,
            supplementShare: suppShare,
            calendar: calendar)
    }

    /// 手动开销查找（列表行 → 编辑表单预填）。
    func expense(id: UUID) -> Expense? {
        expenses.first { $0.id == id }
    }

    /// 记一笔 / 更新（lifttime expenseSheet 保存语义，budget.js:246-261）：
    /// 金额 round2 且必须 > 0；日期归一到所选日 12:00（`hmToTs(day, "12:00")`）；
    /// 备注空白归 nil。返回落库后的条目（金额非法 → nil，调用方不弹成功反馈）。
    @discardableResult
    func saveExpense(_ draft: ExpenseDraft) async -> Expense? {
        let amount = (draft.amountYuan * 100).rounded() / 100
        guard amount.isFinite, amount > 0 else { return nil }
        let calendar = DayCalendar()
        let date = calendar.calendar.date(bySettingHour: 12, minute: 0, second: 0,
                                          of: draft.date) ?? draft.date
        let note = draft.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let editID = draft.editingID,
           let index = expenses.firstIndex(where: { $0.id == editID }) {
            expenses[index].date = date
            expenses[index].amountYuan = amount
            expenses[index].category = draft.category
            expenses[index].note = note.isEmpty ? nil : note
            expenses[index].isOutOfPlan = draft.isOutOfPlan
            await saveExpenses()
            return expenses[index]
        }
        let expense = Expense(date: date, amountYuan: amount, category: draft.category,
                              note: note.isEmpty ? nil : note, isOutOfPlan: draft.isOutOfPlan)
        expenses.append(expense)
        await saveExpenses()
        return expense
    }

    /// 删除手动开销（auto 派生项不经过本路径——源头在 DietEntry）。
    func deleteExpense(id: UUID) async {
        let before = expenses.count
        expenses.removeAll { $0.id == id }
        guard expenses.count != before else { return }
        await saveExpenses()
    }

    // MARK: - 自定义周期计划（design.md §9-6 后置项，本次实装）
    //
    // ⚠ 状态接线裁决：AppModel.swift 为冻结物 C（不能加 @Published 计划数组——
    // Swift 不允许 extension 存储属性，@Published 亦不行，已实测）且不在本任务
    // 允许改动清单内；故计划数组由 BudgetViewState（页面态容器，§8 约定 5 的
    // 收敛点）持有，本层提供「读盘 → 校验 → 落盘 → 返回新数组」的动作方法
    // （与 saveExpense 同为 AppModel 动作入口；状态在 @MainActor 串行域内更新）。

    /// 载入计划数组（BudgetView onAppear / 各动作后刷新；空文件 → []）。
    func loadBudgetPlans() async -> [CustomBudgetPlan] {
        await store.loadBudgetPlans()
    }

    /// 计划卡数据组装（全部为内存快照上的纯引擎调用；status/advice/展示串）。
    func budgetPlanCards(plans: [CustomBudgetPlan], now: Date = Date()) -> [BudgetPlanCardData] {
        let calendar = DayCalendar()
        return plans.map { plan in
            let status = BudgetEngine.planStatus(plan, expenses: expenses,
                                                 dietEntries: dietEntries,
                                                 calendar: calendar, now: now)
            let days = BudgetEngine.planDays(from: plan.startDay, to: plan.endDay,
                                             calendar: calendar)
            return BudgetPlanCardData(
                plan: plan,
                status: status,
                advice: BudgetEngine.planAdvice(plan, status: status, calendar: calendar),
                nameText: BudgetEngine.planDisplayName(plan, calendar: calendar),
                rangeText: BudgetDayLabel.short(plan.startDay) + " – "
                    + BudgetDayLabel.short(plan.endDay) + " · \(days) 天")
        }
    }

    /// 新建 / 更新计划（budget.js:344-356 保存语义）：金额 round2 且必须 > 0
    /// （净化域同 Expense）、end ≥ start（日粒度）、名称截 12 字、空白回退
    /// 「N天计划」。返回更新后的数组（非法输入 → nil，调用方不弹成功反馈）。
    @discardableResult
    func saveBudgetPlan(_ draft: BudgetPlanDraft) async -> [CustomBudgetPlan]? {
        let calendar = DayCalendar()
        let amount = (draft.amountYuan * 100).rounded() / 100
        let startKey = calendar.dayKey(for: draft.start)
        let endKey = calendar.dayKey(for: draft.end)
        guard amount.isFinite, amount > 0,
              SanitizeLimits.amountRange.contains(amount),
              startKey.rawValue <= endKey.rawValue else { return nil }

        var plans = await store.loadBudgetPlans()
        let days = BudgetEngine.planDays(from: startKey, to: endKey, calendar: calendar)
        let trimmed = draft.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmed.isEmpty ? "\(days)天计划" : String(trimmed.prefix(12))

        if let editID = draft.editingID,
           let index = plans.firstIndex(where: { $0.id == editID }) {
            plans[index].name = name
            plans[index].amountYuan = amount
            plans[index].startDay = startKey
            plans[index].endDay = endKey
        } else {
            plans.append(CustomBudgetPlan(name: name, amountYuan: amount,
                                          startDay: startKey, endDay: endKey))
        }
        await store.save(budgetPlans: plans)
        return plans
    }

    /// 删除计划。返回更新后的数组（id 不存在 → nil）。
    @discardableResult
    func deleteBudgetPlan(id: UUID) async -> [CustomBudgetPlan]? {
        var plans = await store.loadBudgetPlans()
        guard plans.contains(where: { $0.id == id }) else { return nil }
        plans.removeAll { $0.id == id }
        await store.save(budgetPlans: plans)
        return plans
    }

    /// 再来一期（仅对已结束/进行中计划有意义；引擎语义 = 等长等额、紧接
    /// 上一期结束日之后开新期、原计划保留）。返回更新后的数组与新计划
    /// （id 不存在或推演失败 → nil）。
    @discardableResult
    func renewBudgetPlan(id: UUID) async -> (plans: [CustomBudgetPlan],
                                             renewed: CustomBudgetPlan)? {
        let calendar = DayCalendar()
        var plans = await store.loadBudgetPlans()
        guard let source = plans.first(where: { $0.id == id }),
              let renewed = BudgetEngine.renewedPlan(from: source, calendar: calendar)
        else { return nil }
        plans.append(renewed)
        await store.save(budgetPlans: plans)
        return (plans, renewed)
    }
}

// MARK: - 展示格式化（纯函数；lifttime util.js fmtDateCN / fmtHM 的等价物）

/// DayKey / Date → 展示串。仅做「值 → 文本」，不承载任何口径。
enum BudgetDayLabel {

    /// 「2026-10-06」→「10/6」（趋势卡 x 轴）。
    static func short(_ key: DayKey) -> String {
        let parts = key.rawValue.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]), let day = Int(parts[2]) else { return key.rawValue }
        return "\(month)/\(day)"
    }

    /// 「2026-10-06」→「10月6日」。
    static func cn(_ key: DayKey) -> String {
        let parts = key.rawValue.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]), let day = Int(parts[2]) else { return key.rawValue }
        return "\(month)月\(day)日"
    }

    /// Date →「10月6日 14:30」（开销行时间戳）。
    static func timestamp(_ date: Date, calendar: DayCalendar) -> String {
        let c = calendar.calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return "\(c.month ?? 0)月\(c.day ?? 0)日 \(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))"
    }

    /// 区间 →「10月6日 – 10月12日」。
    static func range(_ span: DateSpan) -> String {
        cn(span.startDay) + " – " + cn(span.endDay)
    }
}
