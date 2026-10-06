import Testing
import Foundation
@testable import SelfRecordCore

// MARK: - budget 模块测试（design.md §3.5 测试清单）
//
// 移植 lifttime finance.test.mjs 断言语义：周/月区间（:19-25）、记餐 cost 派生
// auto（:27-48，byCat[.meals] == 23、.takeout/.groceries 分类断言）、节奏预测
// （:59-69）、三档建议文案（:71-87）、蛋白性价比 ¥/10g == 3.65（:50-57）、
// 计划外双口径（:129-146，以周窗口代表第一版周期）、格式化（:148-151）。
// 自定义周期计划（planRange/planStatus/planDays/planAdvice，:89-127）已随
// 功能实装移植（§9-6 解除后置），另含「再来一期」推演、多计划并存与
// 计划外不计计划额度的窗口映射用例（:141-145）。
//
// 时间锚定 UTC+8（§8 约定 2）；lifttime 用例的「2026-08-23 周日 18:00 /
// 2026-08-17 周一 00:00」等价物（finance.test.mjs:14-16）。

@Suite
struct BudgetFinanceTests {

    private let cal = DayCalendar.utc8()

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return cal.calendar.date(from: components)!
    }

    /// 2026-08-17 周一 00:00（finance.test.mjs:16）
    private var monday: Date { date(2026, 8, 17) }
    /// 2026-08-23 周日 18:00（finance.test.mjs:15）
    private var sunday: Date { date(2026, 8, 23, 18) }
    private var mondayKey: DayKey { DayKey(rawValue: "2026-08-17")! }

    // finance.test.mjs:28-36 的 fixture（2 手动 + 3 记餐，其中 1 笔无花费）
    private func makeFixtures() -> (expenses: [Expense], diet: [DietEntry]) {
        let expenses = [
            Expense(date: monday.addingTimeInterval(3_600), amountYuan: 120,
                    category: .groceries, note: "买菜"),
            Expense(date: monday.addingTimeInterval(7_200), amountYuan: 45,
                    category: .takeout, note: "黄焖鸡"),
        ]
        let diet = [
            DietEntry(date: monday.addingTimeInterval(8_000), meal: .lunch,
                      rawText: "一份鸡胸肉", totals: MacroTotals(proteinG: 40), costYuan: 15),
            DietEntry(date: monday.addingTimeInterval(9_000), meal: .dinner,
                      rawText: "一碗米饭", totals: MacroTotals(proteinG: 5), costYuan: 0),
            DietEntry(date: monday.addingTimeInterval(9_500), meal: .postworkout,
                      rawText: "一勺蛋白粉", totals: MacroTotals(proteinG: 23), costYuan: 8),
        ]
        return (expenses, diet)
    }

    // MARK: - 冻结签名（design.md §2.1）

    @Test func frozenSignaturesPresent() {
        // 占位期断言的 `== nil` 是桩行为；实现后语义锚点换成
        // 「无预算返回 nil」（finance.test.mjs:69）+ 可正常调用。
        let span = DateSpan(startDay: DayKey(rawValue: "2026-10-01")!,
                            endDay: DayKey(rawValue: "2026-10-07")!)
        #expect(BudgetEngine.status(budgetYuan: nil, span: span, expenses: [], dietEntries: [],
                                    calendar: cal, now: sunday) == nil)
        #expect(BudgetEngine.status(budgetYuan: 500, span: span, expenses: [], dietEntries: [],
                                    calendar: cal, now: sunday) != nil)
        #expect(BudgetEngine.proteinEconomy(dietEntries: [], in: span, calendar: cal) == nil)
    }

    // MARK: - 区间（finance.test.mjs:18-25）

    @Test func weekAndMonthSpans() {
        let week = BudgetEngine.weekSpan(containing: sunday, calendar: cal)
        #expect(week.startDay.rawValue == "2026-08-17")    // 周日所在周 = 周一 8/17 起
        #expect(week.endDay.rawValue == "2026-08-23")      // 含首尾共 7 天
        let sameWeek = BudgetEngine.weekSpan(containing: monday.addingTimeInterval(3_600), calendar: cal)
        #expect(sameWeek.startDay.rawValue == "2026-08-17")  // 周一当天属于本周
        let month = BudgetEngine.monthSpan(containing: sunday, calendar: cal)
        #expect(month.startDay.rawValue == "2026-08-01")   // 月区间 8/1 起
        #expect(month.endDay.rawValue == "2026-08-31")     // 8/31 止（9/1 前一天）
    }

    // MARK: - 合并记餐开销（finance.test.mjs:27-41）

    @Test func mergedFlowDerivesAutoFromDietCost() {
        let (expenses, diet) = makeFixtures()
        let all = BudgetEngine.mergedExpenses(expenses, dietEntries: diet)
        #expect(all.count == 4)                                   // 2 手动 + 2 记餐带花费
        #expect(all.filter(\.isAuto).count == 2)                  // 记餐花费标记 auto
        let postWorkout = all.first { $0.mealEntryID == diet[2].id }
        #expect(postWorkout?.note.contains("练后餐") == true)     // 记餐备注含餐次
        #expect(postWorkout?.category == .meals)                  // 派生项分类恒 .meals
        #expect(all.contains { $0.mealEntryID == diet[1].id } == false)  // 无花费的记餐不计入
        #expect(all.map(\.date) == all.map(\.date).sorted(by: >))  // 新→旧排序（:57）
        // 手动条目保留计划内外标记与分类
        #expect(all.first { $0.note == "买菜" }?.category == .groceries)
        #expect(all.first { $0.note == "黄焖鸡" }?.category == .takeout)
    }

    // MARK: - 汇总（finance.test.mjs:43-48）

    @Test func summarizeByCategory() {
        let (expenses, diet) = makeFixtures()
        let summary = BudgetEngine.summarize(
            BudgetEngine.mergedExpenses(expenses, dietEntries: diet), calendar: cal)
        #expect(summary.totalYuan == 188)                          // 120+45+15+8 = 188
        #expect(summary.byCat[.meals] == 23 && summary.byCat[.groceries] == 120)  // 按分类聚合
        #expect(summary.byCat[.takeout] == 45)
        #expect(summary.maxExpense?.note == "买菜")                // 最大单笔识别
        #expect(summary.daysWithSpend == 1)                        // 活跃天数
        #expect(summary.count == 4)
    }

    // MARK: - 蛋白质性价比（finance.test.mjs:50-57）

    @Test func proteinEconomyPer10g() {
        let (_, diet) = makeFixtures()
        let daySpan = DateSpan(startDay: mondayKey, endDay: mondayKey)
        let eco = BudgetEngine.proteinEconomy(dietEntries: diet, in: daySpan, calendar: cal)
        #expect(eco?.costYuan == 23 && eco?.proteinG == 63)        // 15+8 花费 / 40+23 蛋白
        #expect(abs((eco?.per10gYuan ?? 0) - 3.65) < 0.01)         // 23/63*10 ≈ 3.65
        // 三餐带花费用于建议触发（:54-55）
        let m4 = DietEntry(date: monday.addingTimeInterval(9_600), meal: .breakfast,
                           rawText: "两个鸡蛋", totals: MacroTotals(proteinG: 13), costYuan: 4)
        let eco3 = BudgetEngine.proteinEconomy(dietEntries: diet + [m4], in: daySpan, calendar: cal)
        #expect(eco3?.meals == 3)
        #expect(BudgetEngine.proteinEconomy(dietEntries: [], in: daySpan, calendar: cal) == nil)  // 无数据
        // 有花费但零蛋白 → per10g 为 null（finance.js:106）
        let noProtein = DietEntry(date: monday.addingTimeInterval(1_000), meal: .snack,
                                  rawText: "一瓶可乐", totals: MacroTotals(), costYuan: 3)
        let ecoNoProtein = BudgetEngine.proteinEconomy(dietEntries: [noProtein], in: daySpan,
                                                       calendar: cal)
        #expect(ecoNoProtein?.per10gYuan == nil && ecoNoProtein?.meals == 1)
    }

    // MARK: - 预算状态与节奏预测（finance.test.mjs:59-69）

    @Test func budgetStatusPaceProjection() {
        let (expenses, diet) = makeFixtures()
        let week = BudgetEngine.weekSpan(containing: sunday, calendar: cal)
        // 周日 18:00，本周花 188，预算 500（finance.test.mjs:61-65）
        let status = BudgetEngine.status(budgetYuan: 500, span: week, expenses: expenses,
                                         dietEntries: diet, calendar: cal, now: sunday)
        #expect(status?.spentYuan == 188)
        #expect(status?.pct == 38)                                 // 已用 38%
        #expect(status?.remainingYuan == 312 && status?.daysLeft == 1)
        #expect(status?.overProjected == false)                    // 6.75/7 天 → projected ≈ 194.96
        #expect((status?.projectedYuan ?? 0) < 200)
        #expect(status?.totalYuan == 188 && status?.outOfPlanYuan == 0)
        // 花 495（+307）→ projected ≈ 513 > 500，接近全额即超节奏（:66-68）
        let extra = Expense(date: monday.addingTimeInterval(1_000), amountYuan: 307,
                            category: .takeout, note: "x")
        let over = BudgetEngine.status(budgetYuan: 500, span: week, expenses: expenses + [extra],
                                       dietEntries: diet, calendar: cal, now: sunday)
        #expect(over?.overProjected == true)
        // 无预算返回 null（:69）
        #expect(BudgetEngine.status(budgetYuan: 0, span: week, expenses: expenses,
                                   dietEntries: diet, calendar: cal, now: sunday) == nil)
    }

    // MARK: - 计划外双口径（finance.test.mjs:129-146；第一版周期 = 周/月）

    @Test func outOfPlanDualTrack() {
        let x1 = Expense(date: sunday.addingTimeInterval(3_600), amountYuan: 100,
                         category: .groceries, note: "买菜")
        let x2 = Expense(date: sunday.addingTimeInterval(7_200), amountYuan: 250,
                         category: .other, note: "体检", isOutOfPlan: true)
        let x3 = Expense(date: sunday.addingTimeInterval(10_800), amountYuan: 50,
                         category: .takeout, note: "外卖")
        let mixed = BudgetEngine.mergedExpenses([x1, x2, x3], dietEntries: [])
        #expect(mixed.first { $0.id == x2.id.uuidString }?.isOutOfPlan == true)   // 保留计划外标记
        #expect(mixed.first { $0.id == x3.id.uuidString }?.isOutOfPlan == false)  // 未标记默认计划内
        let inPlan = BudgetEngine.inPlan(mixed)
        #expect(inPlan.count == 2
                && BudgetEngine.summarize(inPlan, calendar: cal).totalYuan == 150)  // 额度只算计划内
        let outOfPlan = BudgetEngine.outOfPlan(mixed)
        #expect(outOfPlan.totalYuan == 250 && outOfPlan.count == 1)                // 计划外单独合计
        // 周窗口内：总账口径含计外 400，周期进度口径 150（:141-145 的 SelfRecord 映射）
        let week = BudgetEngine.weekSpan(containing: sunday, calendar: cal)
        let status = BudgetEngine.status(budgetYuan: 1_000, span: week, expenses: [x1, x2, x3],
                                         dietEntries: [], calendar: cal,
                                         now: sunday.addingTimeInterval(4 * 3_600))
        #expect(status?.totalYuan == 400)          // 总开销含计外
        #expect(status?.spentYuan == 150)          // 周期额度只算计划内
        #expect(status?.outOfPlanYuan == 250 && status?.outOfPlanCount == 1)
        #expect(status?.pct == 15)                 // 计外不推高周期进度
        // 空输入不崩溃（:146）
        #expect(BudgetEngine.summarize(BudgetEngine.inPlan([]), calendar: cal).totalYuan == 0)
        #expect(BudgetEngine.outOfPlan([]) == OutOfPlanSummary())
    }

    // MARK: - 三档建议（finance.test.mjs:71-87）

    @Test func budgetAdviceNoBudgetHint() {
        // 无预算提示（:72-73）
        let advice = BudgetEngine.budgetAdvice(week: nil, month: nil,
                                               sumWeek: BudgetEngine.summarize([], calendar: cal),
                                               proteinEconomy: nil, proteinHitRate: nil)
        #expect(advice.first?.contains("还没有设置预算") == true)
    }

    @Test func budgetAdviceOverPaceAndDietDiagnosis() {
        // 超支预警 + 外卖占比高蛋白不达标联动 + 记餐性价比反馈（:74-83）
        let (expenses, diet) = makeFixtures()
        let extra = Expense(date: monday.addingTimeInterval(1_000), amountYuan: 307,
                            category: .takeout, note: "x")
        let m4 = DietEntry(date: monday.addingTimeInterval(9_600), meal: .breakfast,
                           rawText: "两个鸡蛋", totals: MacroTotals(proteinG: 13), costYuan: 4)
        let week = BudgetEngine.weekSpan(containing: sunday, calendar: cal)
        let over = BudgetEngine.status(budgetYuan: 500, span: week, expenses: expenses + [extra],
                                       dietEntries: diet + [m4], calendar: cal, now: sunday)
        let sumWeek = BudgetEngine.summarize(
            BudgetEngine.mergedExpenses(expenses + [extra], dietEntries: diet + [m4]),
            calendar: cal)
        let eco3 = BudgetEngine.proteinEconomy(
            dietEntries: diet + [m4],
            in: DateSpan(startDay: week.startDay, endDay: week.startDay), calendar: cal)
        let advice = BudgetEngine.budgetAdvice(week: over, month: nil, sumWeek: sumWeek,
                                               proteinEconomy: eco3, proteinHitRate: 0.4)
        #expect(advice.contains { $0.contains("会超预算") })                     // 超支预警
        #expect(advice.contains { $0.contains("外卖") && $0.contains("鸡胸") })  // 联动建议
        #expect(advice.contains { $0.contains("折合") })                        // 性价比反馈
        #expect(advice.count <= 4)                                              // 上限 4 条
    }

    @Test func budgetAdviceNearLimitTier() {
        // 临期档：pct ≥ 85、未超节奏、daysLeft > 1（finance.js:188-190）
        // 周六 23:00 已过 5.958/7 天、花 425/500 → projected ≈ 499.3 < 500，pct = 85
        let saturdayLate = date(2026, 8, 22, 23)
        let week = BudgetEngine.weekSpan(containing: sunday, calendar: cal)
        let nearFull = BudgetEngine.status(budgetYuan: 500, span: week,
                                           expenses: [Expense(date: monday.addingTimeInterval(3_600),
                                                              amountYuan: 425, category: .groceries,
                                                              note: "囤货")],
                                           dietEntries: [], calendar: cal, now: saturdayLate)
        #expect(nearFull?.overProjected == false && nearFull?.pct == 85 && nearFull?.daysLeft == 2)
        let advice = BudgetEngine.budgetAdvice(week: nearFull, month: nil, sumWeek: nil,
                                               proteinEconomy: nil, proteinHitRate: nil)
        #expect(advice.first?.contains("本周预算已用 85%") == true)
        #expect(advice.first?.contains("还剩 2 天") == true)
    }

    @Test func budgetAdviceHealthyTier() {
        // 健康档：无任何触发 → 唯一文案（finance.js:217）
        let week = BudgetEngine.weekSpan(containing: sunday, calendar: cal)
        let healthy = BudgetEngine.status(budgetYuan: 500, span: week,
                                          expenses: [Expense(date: monday.addingTimeInterval(3_600),
                                                             amountYuan: 120, category: .groceries,
                                                             note: "买菜")],
                                          dietEntries: [], calendar: cal, now: sunday)
        let advice = BudgetEngine.budgetAdvice(week: healthy, month: nil,
                                               sumWeek: BudgetEngine.summarize([], calendar: cal),
                                               proteinEconomy: nil, proteinHitRate: nil)
        #expect(advice == ["花销节奏健康，继续保持。"])
    }

    @Test func budgetAdviceSupplementShare() {
        // 补剂占比提醒（finance.test.mjs:84-87；200/300 = 67% > 30%）
        let supplementHeavy = BudgetEngine.summarize(BudgetEngine.mergedExpenses([
            Expense(date: monday, amountYuan: 200, category: .supplement),
            Expense(date: monday, amountYuan: 100, category: .groceries),
        ], dietEntries: []), calendar: cal)
        let advice = BudgetEngine.budgetAdvice(week: nil, month: nil, sumWeek: supplementHeavy,
                                               proteinEconomy: nil, proteinHitRate: nil)
        #expect(advice.contains { $0.contains("补剂") })
    }

    // MARK: - 格式化与口径（finance.test.mjs:148-151）

    @Test func moneyAndCategoryVocabulary() {
        #expect(BudgetEngine.fmtMoney(1234.5) == "1,234.50")   // 千分位 + 两位小数
        #expect(BudgetEngine.fmtMoney(500) == "500")           // 整数无小数
        #expect(BudgetEngine.categoryLabel(.meals) == "记餐开销")  // 分类映射
        // 手动记账不提供 meals 档（finance.js:15 MANUAL_CATS；§3.5）
        #expect(BudgetEngine.manualCategories.contains(.meals) == false)
        #expect(BudgetEngine.manualCategories.count == 6)
        // 参考成本表口径（finance.js:18-23）
        #expect(BudgetEngine.proteinPriceRef.map(\.per10gYuan) == [0.8, 1.6, 2.2, 2.5])
        #expect(BudgetEngine.proteinPriceRef.map(\.name) == ["鸡胸肉", "鸡蛋", "蛋白粉", "牛肉"])
    }

    // MARK: - 自定义周期计划（finance.test.mjs:89-127，随功能移植）

    private func key(_ raw: String) -> DayKey { DayKey(rawValue: raw)! }

    /// finance.test.mjs:95 的 plan14：「两周冲刺」8/23 起 14 天 ¥1000。
    private func makePlan14() -> CustomBudgetPlan {
        CustomBudgetPlan(name: "两周冲刺", amountYuan: 1000,
                         startDay: key("2026-08-23"), endDay: key("2026-09-05"))
    }

    /// 单笔计划内开销（默认 groceries 档）。
    private func planExpense(_ amount: Double, at date: Date,
                             outOfPlan: Bool = false) -> Expense {
        Expense(date: date, amountYuan: amount, category: outOfPlan ? .other : .groceries,
                note: nil, isOutOfPlan: outOfPlan)
    }

    @Test func planDaysInclusiveCounting() {
        // 起止日期换算天数（finance.test.mjs:91-94）
        let start = key("2026-08-23")
        #expect(BudgetEngine.planDays(from: start, to: start, calendar: cal) == 1)        // 同一天 = 1 天
        #expect(BudgetEngine.planDays(from: start, to: key("2026-09-05"),
                                      calendar: cal) == 14)   // 起止相差 13 天 = 14 天
        #expect(BudgetEngine.planDays(from: start, to: key("2026-08-22"),
                                      calendar: cal) == 0)    // 结束早于开始 = 0（非法）
        // 跨月边界：8/31 – 9/1 = 2 天
        #expect(BudgetEngine.planDays(from: key("2026-08-31"), to: key("2026-09-01"),
                                      calendar: cal) == 2)
    }

    @Test func planRangeDayKeyNormalized() {
        // 计划起始归一到当天 0 点 + 14 天区间长度（finance.test.mjs:96-98）
        let plan = makePlan14()
        let span = BudgetEngine.planRange(plan)
        #expect(span.startDay == plan.startDay && span.endDay == plan.endDay)
        let start = cal.date(of: span.startDay)!
        let endExclusive = cal.date(of: span.endDay)!.addingTimeInterval(86_400)
        #expect(start == date(2026, 8, 23))                              // 起日 00:00
        #expect(endExclusive.timeIntervalSince(start) == 14 * 86_400)    // 含首尾 14 天
    }

    @Test func planStatusActiveFields() {
        // 进行中：周日 18:00（第 1 天）花 300/1000（finance.test.mjs:99-101）
        let st = BudgetEngine.planStatus(makePlan14(),
                                         expenses: [planExpense(300, at: sunday.addingTimeInterval(3_600))],
                                         dietEntries: [], calendar: cal, now: sunday)
        #expect(st?.phase == .active)                    // !notStarted && !ended
        #expect(st?.pct == 30)                           // 进行中: 30%
        #expect(st?.spentYuan == 300 && st?.remainingYuan == 700)
        #expect(st?.daysLeft == 14)                      // 第 1 天剩 14 天
        #expect(st?.daysTotal == 14)
        #expect((st?.timeProgress ?? 0) > 0.02 && (st?.timeProgress ?? 0) < 0.06)  // 18h/14d ≈ 0.054
        #expect(st?.perDayLeftYuan == 50)                // 700 / 14（今天起日均还能花）
    }

    @Test func planStatusUpcomingAndEnded() {
        // 未来计划 notStarted、未开始不给建议（finance.test.mjs:103-106）
        let future = CustomBudgetPlan(amountYuan: 500,
                                      startDay: key("2026-08-26"), endDay: key("2026-09-04"))
        let upcoming = BudgetEngine.planStatus(future, expenses: [], dietEntries: [],
                                               calendar: cal, now: sunday)
        #expect(upcoming?.phase == .upcoming && upcoming?.pct == 0)
        #expect(upcoming?.timeProgress == 0)
        #expect(BudgetEngine.planAdvice(future, status: upcoming, calendar: cal) == nil)
        // 过期计划 ended、已结束不给建议（finance.test.mjs:108-111）
        let past = CustomBudgetPlan(amountYuan: 500,
                                    startDay: key("2026-08-03"), endDay: key("2026-08-12"))
        let ended = BudgetEngine.planStatus(
            past, expenses: [planExpense(480, at: date(2026, 8, 5, 12))],
            dietEntries: [], calendar: cal, now: sunday)
        #expect(ended?.phase == .ended)                  // ended && !notStarted
        #expect(ended?.pct == 96 && ended?.timeProgress == 1)
        #expect(ended?.projectedYuan == 480)             // elapsed=total → projected=spent
        #expect(BudgetEngine.planAdvice(past, status: ended, calendar: cal) == nil)
    }

    @Test func planAdviceOverPacePullback() {
        // 第 7 天花 900/1000 → 超节奏 + 拉回文案（finance.test.mjs:113-116）
        let day6 = date(2026, 8, 29, 18)
        let plan = makePlan14()
        let st = BudgetEngine.planStatus(plan, expenses: [planExpense(900, at: day6)],
                                         dietEntries: [], calendar: cal, now: day6)
        #expect(st?.overProjected == true)               // 第 7 天 90% -> 超节奏
        let advice = BudgetEngine.planAdvice(plan, status: st, calendar: cal)
        #expect(advice?.contains("两周冲刺") == true)     // 文案带计划名
        #expect(advice?.contains("会超预算") == true)
        #expect(advice?.contains("每天控制在") == true)   // 拉回指引
    }

    @Test func planAdviceNearLimit() {
        // 第 12.75 天花 850/1000，projected≈933 未超、pct 85（finance.test.mjs:117-120）
        let day12 = date(2026, 9, 4, 18)
        let plan = makePlan14()
        let st = BudgetEngine.planStatus(plan, expenses: [planExpense(850, at: day12)],
                                         dietEntries: [], calendar: cal, now: day12)
        #expect(st?.overProjected == false && st?.pct == 85 && st?.daysLeft == 2)
        let advice = BudgetEngine.planAdvice(plan, status: st, calendar: cal)
        #expect(advice?.contains("85%") == true)         // 高占比提醒
        #expect(advice?.contains("还剩 2 天") == true)
    }

    @Test func planAdviceOverspent() {
        // 第 10 天花 1100/1000 → 已超预算文案（finance.test.mjs:121-124）
        let day9 = date(2026, 9, 1, 18)
        let plan = makePlan14()
        let st = BudgetEngine.planStatus(plan, expenses: [planExpense(1_100, at: day9)],
                                         dietEntries: [], calendar: cal, now: day9)
        let advice = BudgetEngine.planAdvice(plan, status: st, calendar: cal)
        #expect(advice?.contains("已超预算 ¥100") == true)
        #expect(advice?.contains("尽量零额外开销") == true)
    }

    @Test func planAdviceHealthySilent() {
        // 健康节奏不打扰：第 7 天花 300/1000（projected≈622）（finance.test.mjs:125-127）
        let day6 = date(2026, 8, 29, 18)
        let plan = makePlan14()
        let st = BudgetEngine.planStatus(plan, expenses: [planExpense(300, at: day6)],
                                         dietEntries: [], calendar: cal, now: day6)
        #expect(st?.overProjected == false)
        #expect(BudgetEngine.planAdvice(plan, status: st, calendar: cal) == nil)
    }

    @Test func planQuotaExcludesOutOfPlan() {
        // 计划外金额不计计划额度（finance.test.mjs:129-146 的自定义周期映射，
        // :141-145 的「计外不推高计划进度: 15%」）
        let x1 = planExpense(100, at: sunday.addingTimeInterval(3_600))
        let x2 = planExpense(250, at: sunday.addingTimeInterval(7_200), outOfPlan: true)
        let x3 = planExpense(50, at: sunday.addingTimeInterval(10_800))
        let mixed = BudgetEngine.mergedExpenses([x1, x2, x3], dietEntries: [])
        // planSpend：额度口径只算计划内（:138-139）
        let inQuota = BudgetEngine.planSpend(mixed)
        #expect(inQuota.count == 2
                && BudgetEngine.summarize(inQuota, calendar: cal).totalYuan == 150)
        let st = BudgetEngine.planStatus(makePlan14(), expenses: [x1, x2, x3],
                                         dietEntries: [], calendar: cal,
                                         now: sunday.addingTimeInterval(4 * 3_600))
        #expect(st?.totalYuan == 400)                    // 窗口内总开销含计外
        #expect(st?.spentYuan == 150)                    // 计划进度口径
        #expect(st?.outOfPlanYuan == 250 && st?.outOfPlanCount == 1)
        #expect(st?.pct == 15)                           // 计外不推高计划进度
        // 空输入不崩溃（:146）
        #expect(BudgetEngine.planSpend([]).isEmpty)
        #expect(BudgetEngine.planStatus(makePlan14(), expenses: [], dietEntries: [],
                                        calendar: cal, now: sunday)?.spentYuan == 0)
    }

    @Test func planStatusInvalidPlanReturnsNil() {
        // 结构非法（lifttime invalid:true 的 nil 形态，finance.js:126）
        let start = key("2026-08-23")
        let reversed = CustomBudgetPlan(amountYuan: 1_000, startDay: start,
                                        endDay: key("2026-08-22"))
        #expect(reversed.isValid == false)
        #expect(BudgetEngine.planStatus(reversed, expenses: [], dietEntries: [],
                                        calendar: cal, now: sunday) == nil)
        let zeroAmount = CustomBudgetPlan(amountYuan: 0, startDay: start, endDay: start)
        #expect(zeroAmount.isValid == false)
        #expect(BudgetEngine.planStatus(zeroAmount, expenses: [], dietEntries: [],
                                        calendar: cal, now: sunday) == nil)
    }

    @Test func planRenewalFollowsPreviousEnd() {
        // 再来一期：等长等额、紧接上一期结束日之后开新期；新 id、原计划保留
        let plan = makePlan14()                          // 8/23 – 9/5 · 14 天
        let renewed = BudgetEngine.renewedPlan(from: plan, calendar: cal)
        #expect(renewed?.startDay.rawValue == "2026-09-06")   // 上期止日 + 1
        #expect(renewed?.endDay.rawValue == "2026-09-19")     // 等长 14 天
        #expect(renewed?.amountYuan == 1_000 && renewed?.name == "两周冲刺")
        #expect(renewed?.id != plan.id)                       // 新一期新 id（并存）
        #expect(renewed?.isValid == true)
        // 1 天计划的再来一期 = 次日单日
        let oneDay = CustomBudgetPlan(amountYuan: 100, startDay: key("2026-08-23"),
                                      endDay: key("2026-08-23"))
        let next = BudgetEngine.renewedPlan(from: oneDay, calendar: cal)
        #expect(next?.startDay.rawValue == "2026-08-24" && next?.endDay.rawValue == "2026-08-24")
    }

    @Test func multiplePlansIndependentQuotas() {
        // 多计划并存：各计划窗口独立过滤，额度互不串
        let a = makePlan14()                              // 8/23 – 9/5 · ¥1000
        let b = CustomBudgetPlan(amountYuan: 500,         // 8/25 – 9/3 · 10 天
                                 startDay: key("2026-08-25"), endDay: key("2026-09-03"))
        let expenses = [
            planExpense(100, at: date(2026, 8, 24, 12)),                  // 仅 A
            planExpense(60, at: date(2026, 8, 26, 12)),                   // A、B 皆在
            planExpense(30, at: date(2026, 9, 4, 12)),                    // 仅 A
            planExpense(200, at: date(2026, 8, 27, 12), outOfPlan: true), // 计外不占额度
        ]
        let sa = BudgetEngine.planStatus(a, expenses: expenses, dietEntries: [],
                                         calendar: cal, now: sunday)
        let sb = BudgetEngine.planStatus(b, expenses: expenses, dietEntries: [],
                                         calendar: cal, now: sunday)
        #expect(sa?.spentYuan == 190 && sa?.pct == 19 && sa?.totalYuan == 390)
        #expect(sb?.spentYuan == 60 && sb?.pct == 12 && sb?.totalYuan == 260)
        #expect(sb?.outOfPlanYuan == 200)
    }

    @Test func planDisplayNameFallbackAndDecode() throws {
        // 展示名回退（budget.js:109/:133 `plan.name || plan.days + '天计划'`）
        #expect(BudgetEngine.planDisplayName(makePlan14(), calendar: cal) == "两周冲刺")
        let unnamed = CustomBudgetPlan(amountYuan: 500, startDay: key("2026-08-23"),
                                       endDay: key("2026-08-23"))
        #expect(BudgetEngine.planDisplayName(unnamed, calendar: cal) == "1天计划")
        let blank = CustomBudgetPlan(name: "   ", amountYuan: 500, startDay: key("2026-08-23"),
                                     endDay: key("2026-09-05"))
        #expect(BudgetEngine.planDisplayName(blank, calendar: cal) == "14天计划")
        // 宽松解码：name / amountYuan 缺 key 归默认（向后兼容），条目保留
        let json = #"[{"id":"11111111-1111-1111-1111-111111111111","startDay":"2026-08-23","endDay":"2026-09-05","amountYuan":800}]"#
        let plans = try JSONDecoder().decode([CustomBudgetPlan].self,
                                             from: Data(json.utf8))
        #expect(plans.count == 1 && plans[0].name == "" && plans[0].isValid)
        // 净化：结构性非法剔除、名称截 12 字（budget.js:312 maxlength=12）
        let tooLongName = String(repeating: "冲", count: 20)
        let sanitized = CustomBudgetPlan.sanitized([
            CustomBudgetPlan(name: tooLongName, amountYuan: 800,
                             startDay: key("2026-08-23"), endDay: key("2026-09-05")),
            CustomBudgetPlan(amountYuan: 800, startDay: key("2026-08-23"),
                             endDay: key("2026-08-22")),        // end<start → 剔除
            CustomBudgetPlan(amountYuan: 0, startDay: key("2026-08-23"),
                             endDay: key("2026-08-23")),        // 金额非正 → 剔除
        ])
        #expect(sanitized.count == 1 && sanitized[0].name.count == 12)
    }
}
