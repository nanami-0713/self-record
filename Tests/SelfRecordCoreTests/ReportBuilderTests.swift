import Testing
import Foundation
@testable import SelfRecordCore

// MARK: - report 模块测试（design.md §3.6 测试清单）
//
// 移植 lifttime tests/reportBuilder.test.mjs 断言语义（Swift 原生化）：
// - 时间区间：三档预设 + 自定义含首尾 / 超限拒 / end<start 拒（:50-61）；
// - 五域聚合数值锚点：时间 130 分 / 睡眠债 90 分 / 总账 310 含计外 250、
//   平均 435 分/晚、训练容量 > 1900、日均蛋白 70g（:63-76）；
// - 规则版文案锚点：总评含区间名、时间含总时长、睡眠含晚数与分数、
//   预算含总账与计划外、建议 1–5 条、空数据引导文案（:81-95）；
// - 自建：日简报五域合一（昨晚睡眠无单夜分数、近 7 晚睡眠债、训练日蛋白
//   缺口标志、当日/当周开销）与日期翻页。
//
// 例外（随功能后置，第一版不移植，design.md §3.6）：
// - planOverlaps[0].status.pct === 6 等自定义周期计划锚点（reportBuilder.test.mjs:77-79）；
// - buildReportPrompt / parseReportAI 的 AI 用例（:97-109，AI 网络层后置）。
// 注：lifttime「custom 缺日期 → null」由 Swift 类型系统保证
// （ReportCustomRange 的 startDay/endDay 非可选），不设等价用例。

// —— 固定基准（与 lifttime 同一套 fixture 语义：2026-09-07 周一 20:00，UTC+8）——

private let cal = DayCalendar.utc8()

private func ts(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var c = DateComponents()
    c.year = 2026; c.month = month; c.day = day; c.hour = hour; c.minute = minute
    return cal.calendar.date(from: c)!
}

private let NOW = ts(9, 7, 20, 0)
private let hour: TimeInterval = 3600

private func key(_ raw: String) -> DayKey { DayKey(rawValue: raw)! }

private func makeWorkout(_ start: Date, exercises: [(String, [(Double, Int)])]) -> Workout {
    Workout(startedAt: start, endedAt: start + hour,
            entries: exercises.map { name, sets in
                WorkoutExerciseEntry(exerciseID: name,
                                     sets: sets.map { WorkoutSet(weightKg: $0.0, reps: $0.1, timestamp: start) })
            },
            feeling: 3)
}

private func makeDietEntry(_ date: Date, meal: MealSlot, text: String,
                           kcal: Double, protein: Double, carbs: Double, fat: Double,
                           itemName: String? = nil) -> DietEntry {
    DietEntry(date: date, meal: meal, rawText: text,
              items: itemName.map { [FoodMatch(name: $0, grams: 100,
                                               per100g: Per100g(kcal: kcal, proteinG: protein,
                                                                carbsG: carbs, fatG: fat))] } ?? [],
              totals: MacroTotals(kcal: kcal, proteinG: protein, carbsG: carbs, fatG: fat))
}

/// 与 lifttime reportBuilder.test.mjs:19-48 同构的五域 fixture。
private var fixture: ReportInputs {
    ReportInputs(
        categories: [
            TimeCategory(id: "strength", label: "力量训练", hue: .rose),
            TimeCategory(id: "cardio", label: "有氧", hue: .rust),
            TimeCategory(id: "other", label: "其他", hue: .neutral, isFallback: true),
        ],
        timeBlocks: [
            TimeBlock(start: ts(9, 6, 10), end: ts(9, 6, 11, 30), categoryID: "strength"),  // 90 分
            TimeBlock(start: ts(9, 5, 8), end: ts(9, 5, 8, 40), categoryID: "cardio"),      // 40 分
        ],
        sleepSessions: [
            // 7.5h，归属 9/6（醒来 9/6 07:00 − 4h = 9/6 03:00）
            SleepSession(start: ts(9, 5, 23, 30), end: ts(9, 6, 7), feel: 4, wakeCount: 0, latency: .fast),
            // 7h，归属 9/7
            SleepSession(start: ts(9, 6, 23, 40), end: ts(9, 7, 6, 40), feel: 5),
            // 9/7 午睡 30 分（14:00 开始、<3h）
            SleepSession(start: ts(9, 7, 14), end: ts(9, 7, 14, 30)),
        ],
        workouts: [
            // 容量 60×8 + 60×8 + 62×8 + 100×5 = 1956
            makeWorkout(ts(9, 6, 19), exercises: [("卧推", [(60, 8), (60, 8), (62, 8)]),
                                                  ("深蹲", [(100, 5)])]),
        ],
        dietEntries: [
            makeDietEntry(ts(9, 6, 12), meal: .lunch, text: "一份鸡胸肉",
                          kcal: 250, protein: 46, carbs: 0, fat: 5, itemName: "鸡胸肉"),
            makeDietEntry(ts(9, 6, 19, 30), meal: .postworkout, text: "蛋白粉",
                          kcal: 120, protein: 24, carbs: 3, fat: 1, itemName: "蛋白粉"),
        ],
        expenses: [
            Expense(date: ts(9, 5, 12), amountYuan: 60, category: .groceries, note: "买菜"),
            Expense(date: ts(9, 6, 15), amountYuan: 250, category: .other, note: "体检", isOutOfPlan: true),
        ],
        bodyweightKg: 70,
        sleepGoalMinutes: 480)
}

// MARK: - 时间区间（reportBuilder.test.mjs:50-61）

@Suite struct ReportRangeConversionTests {

    @Test func pastDayIsToday() {
        let r = ReportEngine.reportRange(preset: .day, now: NOW, calendar: cal)
        #expect(r != nil)
        #expect(r?.dayCount == 1)
        #expect(r?.span.startDay == key("2026-09-07"))
        #expect(r?.span.endDay == key("2026-09-07"))   // lifttime end = 次日 0 点（排他）= Swift 含首尾的末日
    }

    @Test func pastWeekIncludesToday() {
        let r = ReportEngine.reportRange(preset: .week, now: NOW, calendar: cal)
        #expect(r?.dayCount == 7)
        #expect(r?.span.startDay == key("2026-09-01"))
        #expect(r?.span.endDay == key("2026-09-07"))
        #expect(r?.label == "过去一周")
    }

    @Test func pastMonthIncludesToday() {
        let r = ReportEngine.reportRange(preset: .month, now: NOW, calendar: cal)
        #expect(r?.dayCount == 30)
        #expect(r?.span.startDay == key("2026-08-09"))
    }

    @Test func customRangeInclusiveBothEnds() {
        // lifttime: 自定义 9/1–9/7 → 7 天（含首尾两天）
        let r = ReportEngine.reportRange(custom: ReportCustomRange(startDay: key("2026-09-01"),
                                                                   endDay: key("2026-09-07")),
                                         calendar: cal)
        #expect(r != nil)
        #expect(r?.dayCount == 7)
        #expect(r?.span.startDay == key("2026-09-01"))
        #expect(r?.span.endDay == key("2026-09-07"))
        #expect(r?.label == "9/1 – 9/7")
    }

    @Test func customEndBeforeStartRejected() {
        let r = ReportEngine.reportRange(custom: ReportCustomRange(startDay: key("2026-09-07"),
                                                                   endDay: key("2026-09-01")),
                                         calendar: cal)
        #expect(r == nil)
    }

    @Test func customOver366DaysRejected() {
        let r = ReportEngine.reportRange(custom: ReportCustomRange(startDay: key("2024-09-01"),
                                                                   endDay: key("2026-09-07")),
                                         calendar: cal)
        #expect(r == nil)
    }

    @Test func customExactly366DaysAccepted() {
        // 2025-09-07 → 2026-09-07 含首尾恰 366 天（边界含）
        let r = ReportEngine.reportRange(custom: ReportCustomRange(startDay: key("2025-09-07"),
                                                                   endDay: key("2026-09-07")),
                                         calendar: cal)
        #expect(r?.dayCount == 366)
    }
}

// MARK: - 五域聚合数值锚点（reportBuilder.test.mjs:63-79）

@Suite struct PeriodReportAggregationTests {

    private func weekData() -> ReportData {
        let range = ReportEngine.reportRange(preset: .week, now: NOW, calendar: cal)!
        return ReportEngine.periodReport(range: range, inputs: fixture,
                                         calendar: cal, now: NOW)
    }

    @Test func rangeMetadata() {
        #expect(weekData().range.label == "过去一周")
        #expect(weekData().range.dayCount == 7)
    }

    @Test func timeAnchors() {
        let time = weekData().time
        #expect(time.totalMinutes == 130)                    // 90 + 40
        #expect(time.activeDays == 2)                        // 9/5 与 9/6
        #expect(time.top.first?.label == "力量训练")          // Top 分类
        #expect(time.top.first?.minutes == 90)
    }

    @Test func sleepAnchors() {
        let sleep = weekData().sleep
        #expect(sleep.nights == 2)                           // 归属 9/6 与 9/7 两晚
        #expect(sleep.avgNightMinutes == 435)                // (7.5h + 7h) / 2 = 7h15m
        #expect(sleep.debtMinutes == 90)                     // (480-450) + (480-420)
        #expect(sleep.napMinutes == 30)                      // 午睡计入
        #expect(sleep.avgScore != nil && sleep.avgScore! >= 80)
        #expect(sleep.goalMinutes == 480)
        // 日简报/区间层口径：不含任何单夜分数字段（A3）——结构上由类型保证
    }

    @Test func workoutAnchors() {
        let workout = weekData().workout
        #expect(workout.sessions == 1)
        #expect(workout.volumeKg > 1900)                     // 60×16 + 62×8 + 100×5 = 1956
        #expect(workout.volumeKg == 1956)
    }

    @Test func dietAnchors() {
        let diet = weekData().diet
        #expect(diet.daysTracked == 1)                       // 只有 9/6 有记录
        #expect(diet.avgProteinG == 70)                      // (46 + 24) / 1
        #expect(diet.avgKcal == 370)
        #expect(diet.proteinTargetLowG == 112)               // 70kg × 1.6
        #expect(diet.proteinTargetHighG == 154)              // 70kg × 2.2
        #expect(diet.topFoods.contains("鸡胸肉"))
    }

    @Test func budgetAnchors() {
        let budget = weekData().budget
        #expect(budget.totalYuan == 310)                     // 60 + 250（总账含计划外）
        #expect(budget.outOfPlanYuan == 250)                 // 计外体检 250
        #expect(budget.count == 2)
        #expect(budget.activeDays == 2)
        #expect(budget.dailyAvgYuan == 155)
        #expect(budget.topCategory?.label == "其他")
        #expect(budget.topCategory?.amountYuan == 250)
        // planOverlaps（自定义周期计划）随功能后置：第一版无此字段（§9-6）
    }

    @Test func reportDataRemainsUsableAsContractPayload() {
        // 骨架占位断言的保留扩充：ReportData 是渲染/AI 契约载体，值语义可比较
        #expect(ReportData() == ReportData())
        #expect(weekData() != ReportData())
    }

    @Test func reportDataRoundTripsThroughJSON() throws {
        // 报告 JSON 结构 = 未来 AI 输出契约 = 渲染契约（§9-7）：
        // ReportData / RuleReport 必须可无损编解码（Codable 即契约的形态学证明）
        let range = ReportEngine.reportRange(preset: .week, now: NOW, calendar: cal)!
        let data = ReportEngine.periodReport(range: range, inputs: fixture,
                                             calendar: cal, now: NOW)
        let rule = ReportEngine.renderRuleReport(data)

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        let dataJSON = try encoder.encode(data)
        #expect(try decoder.decode(ReportData.self, from: dataJSON) == data)

        let ruleJSON = try encoder.encode(rule)
        #expect(try decoder.decode(RuleReport.self, from: ruleJSON) == rule)

        // 契约字段名是 camelCase 稳定键（AI/渲染两侧按键取值）
        let text = String(data: dataJSON, encoding: .utf8) ?? ""
        for key in ["\"totalMinutes\"", "\"debtMinutes\"", "\"volumeKg\"",
                    "\"daysTracked\"", "\"totalYuan\"", "\"outOfPlanYuan\""] {
            #expect(text.contains(key))
        }
    }
}

// MARK: - 规则版报告文案锚点（reportBuilder.test.mjs:81-95）

@Suite struct RuleReportRenderingTests {

    private func ruleForFixture() -> RuleReport {
        let range = ReportEngine.reportRange(preset: .week, now: NOW, calendar: cal)!
        return ReportEngine.renderRuleReport(
            ReportEngine.periodReport(range: range, inputs: fixture, calendar: cal, now: NOW))
    }

    @Test func overallMentionsRangeLabel() {
        let rule = ruleForFixture()
        #expect(rule.overall.count >= 1)
        #expect(rule.overall.first?.contains("过去一周") == true)
    }

    @Test func timeSectionMentionsTotalDuration() {
        let rule = ruleForFixture()
        #expect(rule.time.count >= 2)
        #expect(rule.time.first?.contains("2 小时 10 分") == true)   // lifttime「2小时10分」的项目空格风格
    }

    @Test func sleepSectionHasNightsAndScore() {
        let rule = ruleForFixture()
        #expect(rule.sleep.contains { $0.contains("2 晚") && $0.contains("睡眠分") })
    }

    @Test func workoutSectionHasSessionCount() {
        let rule = ruleForFixture()
        #expect(rule.workout.contains { $0.contains("1 次训练") })
    }

    @Test func dietSectionHasProteinNumber() {
        let rule = ruleForFixture()
        #expect(rule.diet.contains { $0.contains("70g") })
    }

    @Test func budgetSectionMentionsTotalAndOutOfPlan() {
        let rule = ruleForFixture()
        #expect(rule.budget.contains { $0.contains("¥310") })
        #expect(rule.budget.contains { $0.contains("计划外开销 ¥250") })
    }

    @Test func adviceIsOneToFiveItems() {
        let count = ruleForFixture().advice.count
        #expect(count >= 1 && count <= 5)
    }

    @Test func emptyDataGetsGuidanceCopy() {
        let range = ReportEngine.reportRange(preset: .day, now: NOW, calendar: cal)!
        let data = ReportEngine.periodReport(range: range, inputs: ReportInputs(),
                                             calendar: cal, now: NOW)
        let rule = ReportEngine.renderRuleReport(data)
        #expect(rule.overall.count == 1)
        #expect(rule.overall.first?.contains("还没有任何记录") == true)
    }

    @Test func sleepDebtDrivesAdvice() {
        // 睡眠债 ≥120 → 「先把睡眠债还上」建议（reportBuilder.js:229）
        var data = ReportData()
        data.sleep = ReportSleepSection(nights: 6, dayCount: 7, avgNightMinutes: 400,
                                        avgScore: 80, madMinutes: 10, debtMinutes: 480,
                                        napMinutes: 0, goalMinutes: 480)
        let rule = ReportEngine.renderRuleReport(data)
        #expect(rule.advice.contains { $0.contains("先把睡眠债还上") })
    }

    @Test func irregularBedtimeDrivesAdvice() {
        // MAD > 45 → 固定锚点建议（reportBuilder.js:230）
        var data = ReportData()
        data.sleep = ReportSleepSection(nights: 5, dayCount: 7, avgNightMinutes: 470,
                                        avgScore: 85, madMinutes: 70, debtMinutes: 0,
                                        napMinutes: 0, goalMinutes: 480)
        let rule = ReportEngine.renderRuleReport(data)
        #expect(rule.advice.contains { $0.contains("就寝时间波动太大") })
    }

    @Test func regularLifeGetsDefaultAdvice() {
        var data = ReportData()
        data.time = ReportTimeSection(totalMinutes: 100, activeDays: 1, dayCount: 7,
                                      top: [ReportTimeSlice(label: "力量训练", minutes: 100)])
        let rule = ReportEngine.renderRuleReport(data)
        #expect(rule.advice == ["各板块节奏都在正轨上，按现在的节奏继续保持。"])
    }
}

// MARK: - 日简报（自建：五域合一 + 日期翻页；lifttime report.js:150-210 语义）

@Suite struct DayReportTests {

    private func inputsWithBudget() -> ReportInputs {
        var inputs = fixture
        inputs.weeklyBudgetYuan = 1000
        return inputs
    }

    @Test func sept6FiveDomains() {
        let day = key("2026-09-06")
        let report = ReportEngine.dayReport(day: day, inputs: inputsWithBudget(),
                                            calendar: cal, now: NOW)

        // 时间：当日 90 分力量
        #expect(report.time.totalMinutes == 90)
        #expect(report.time.topCategories.first?.label == "力量训练")
        #expect(report.timeSummary.contains("1 小时 30 分"))

        // 昨晚睡眠：s1 450 分；无午睡；近 7 晚（8/31–9/6 窗口）债务 30 = 480 − 450
        #expect(report.sleep != nil)
        #expect(report.sleep?.night.durationSeconds == 27_000.0)  // 450 分（显式 Double：#expect 宏下 Optional 链不宜对整数算式比较）
        #expect(report.sleep?.napMinutes == 0)
        #expect(report.sleep?.weekDebtMinutes == 30)
        #expect(report.sleep?.night.feel == 4)

        // 当日训练：1 次、容量 1956
        #expect(report.workout.sessions == 1)
        #expect(report.workout.volumeKg == 1956)

        // 当日饮食：训练日、练后餐已补（19:30 ≥ 训练开始 19:00）→ 不标缺口
        #expect(report.diet.postWorkoutMealEaten == true)
        #expect(report.diet.proteinGapOnTrainingDay == false)
        #expect(report.diet.summary.totals.totals.proteinG == 70)

        // 开销：当日 250（体检，总账口径）；本周（8/31–9/6）310 / 1000 = 31%
        #expect(report.budget.daySpentYuan == 250)
        #expect(report.budget.weekSpentYuan == 310)
        #expect(report.budget.weekUsedPercent == 31)
    }

    @Test func sept7TodayWithNapAndNoDiet() {
        let day = key("2026-09-07")
        let report = ReportEngine.dayReport(day: day, inputs: inputsWithBudget(),
                                            calendar: cal, now: NOW)

        // 昨晚 s2 420 分；当日午睡 30；近 7 晚（9/1–9/7）债务 90
        #expect(report.sleep?.night.durationSeconds == 25_200.0)  // 420 分
        #expect(report.sleep?.napMinutes == 30)
        #expect(report.sleep?.weekDebtMinutes == 90)

        // 今天没训练没饮食 → 不标缺口；无开销（本周 9/7–9/13 刚开始）
        #expect(report.diet.proteinGapOnTrainingDay == false)
        #expect(report.workout.sessions == 0)
        #expect(report.budget.daySpentYuan == 0)
        #expect(report.budget.weekSpentYuan == 0)
        #expect(report.budget.weekUsedPercent == 0)

        // 今天无时间记录 → 引导文案
        #expect(report.timeSummary.contains("今天还没有时间记录"))
    }

    @Test func dayWithoutNightHasNoSleepSection() {
        // 9/5：s1 归属 9/6（醒来 −4h 规则），9/5 的「昨晚」无记录
        let report = ReportEngine.dayReport(day: key("2026-09-05"),
                                            inputs: fixture, calendar: cal, now: NOW)
        #expect(report.sleep == nil)
    }

    @Test func trainingDayProteinGapIsFlagged() {
        // 训练日蛋白缺口标黄的正例：练了、没吃练后餐、蛋白 30g < 下限 112g
        let inputs = ReportInputs(
            categories: fixture.categories,
            workouts: [makeWorkout(ts(9, 4, 19), exercises: [("卧推", [(60, 8)])])],
            dietEntries: [makeDietEntry(ts(9, 4, 18), meal: .dinner, text: "轻食",
                                        kcal: 300, protein: 30, carbs: 20, fat: 10)],
            bodyweightKg: 70,
            sleepGoalMinutes: 480)
        let report = ReportEngine.dayReport(day: key("2026-09-04"), inputs: inputs,
                                            calendar: cal, now: NOW)
        #expect(report.diet.proteinGapOnTrainingDay == true)
        #expect(report.diet.postWorkoutMealEaten == false)
    }

    @Test func dayPagingShiftsAnchorDay() {
        // 日期翻页：以 9/7 为锚前一天 → 9/6 的日简报内容随锚点变化
        let today = key("2026-09-07")
        let yesterday = cal.addingDays(-1, to: today)!
        #expect(yesterday == key("2026-09-06"))

        let todayReport = ReportEngine.dayReport(day: today, inputs: fixture,
                                                 calendar: cal, now: NOW)
        let yesterdayReport = ReportEngine.dayReport(day: yesterday, inputs: fixture,
                                                     calendar: cal, now: NOW)
        #expect(todayReport.time.totalMinutes == 0)
        #expect(yesterdayReport.time.totalMinutes == 90)
        #expect(todayReport.sleep?.night.durationSeconds == 25_200.0)
        #expect(yesterdayReport.sleep?.night.durationSeconds == 27_000.0)
    }
}
