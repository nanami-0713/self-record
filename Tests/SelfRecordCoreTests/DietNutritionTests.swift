import Testing
import Foundation
@testable import SelfRecordCore

// MARK: - diet 模块测试（design.md §3.4 测试清单）
//
// 移植 lifttime nutrition.test.mjs 全部 74 项断言语义（文件行号注释标出处）：
// 中文数字/量词/尾部克数/市制两（二两白酒=100g、两碗米饭=400g、半块巧克力=10g、
// 米饭300g）；长名优先（无糖希腊酸奶杯→希腊酸奶）；unmatched；类别猜测
// （排骨汤/奶茶/柠檬茶/炒饭）；learnFood 归一 + 拒绝零值；自定义库按克缩放
// 不影响内置库；训练日达标率；mealOf('preworkout')='练前餐'、未知回退加餐、
// postworkout 构造记录的练后餐打勾/催促文案（nutrition.test.mjs:66-70/:165-168）。
// 另含骨架占位的冻结签名断言（不得删除）与本模块补充口径用例（B1 双达标率、
// tags 只算库命中项、建议上限 4 条、guessMeal 预选、dayIntake）。

// MARK: 占位契约（骨架产出，保留不得删除：冻结物 B 签名可调用且语义成立）

@Suite
struct DietModulePlaceholder {

    @Test func frozenSignaturesPresent() {
        // 冻结物 B 签名桩可调用（实现后签名不得偏离 §2.1）
        let cal = DayCalendar.utc8()
        let day = DayKey(rawValue: "2026-10-06")!
        let span = DateSpan(startDay: day, endDay: day)
        #expect(DietEngine.dailySummary([], day: day, workouts: [], bodyweightKg: nil,
                                        calendar: cal, now: Date(timeIntervalSince1970: 1_760_000_000))
                == DietDaySummary())
        #expect(DietEngine.periodDiet([], workouts: [], in: span,
                                      bodyweightKg: nil, calendar: cal) == DietPeriodSummary())
        #expect(DietEngine.dayIntake([], day: day, woStartedAt: nil, calendar: cal) == nil)
    }
}

// MARK: - 测试夹具（nutrition.test.mjs:10-15 的等价物；时区锚定 UTC+8，§8 约定 2）

/// NOW = 2026-08-21 20:00（+08），对应 JS new Date(2026, 7, 21, 20, 0, 0)
private let cal = DayCalendar.utc8()
private let base: Date = cal.calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 20))!
private let today = DayKey(base, calendar: cal)

/// day(n, h) = NOW 往前 n 天的那一天、h 点整（JS setHours(h,0,0,0) 等价）
private func day(_ n: Int, _ h: Int) -> Date {
    let target = base.addingTimeInterval(-Double(n) * 86400)
    return cal.calendar.startOfDay(for: target).addingTimeInterval(Double(h) * 3600)
}

/// entry(ts, meal, text)：解析文本并组装为已保存形状的 DietEntry
private func entry(_ ts: Date, _ meal: MealSlot, _ text: String) -> DietEntry {
    let p = DietEngine.parseMealText(text)
    return DietEntry(date: ts, meal: meal, rawText: text, items: p.items,
                     manualItems: [], unmatched: p.unmatched, totals: p.totals)
}

// MARK: - 食物库（nutrition.test.mjs:17-20）

@Suite
struct DietFoodLibraryTests {

    @Test func aliasMatch() {
        // 「鸡胸」别名 → 鸡胸肉
        let hit = DietEngine.findFood("鸡胸")
        #expect(hit != nil && hit!.name == "鸡胸肉")
    }

    @Test func longestNameFirst() {
        // 长名优先匹配：无糖希腊酸奶杯 → 希腊酸奶（防「酸奶」截胡）
        let hit = DietEngine.findFood("无糖希腊酸奶杯")
        #expect(hit != nil && hit!.name == "希腊酸奶")
    }

    @Test func unknownReturnsNil() {
        #expect(DietEngine.findFood("佛跳墙") == nil)
    }

    @Test func librarySize() {
        // §3.4：内置库 320+ 项（实际 326，脚本从 lifttime foods.js 无损转译）
        #expect(FoodLibrary.builtIn.count >= 320)
    }
}

// MARK: - 文本解析（nutrition.test.mjs:22-43）

@Suite
struct DietParseTests {

    @Test func twoEggs() {
        let r = DietEngine.parseMealText("2个鸡蛋")
        #expect(r.items.count == 1 && r.items[0].grams == 110)          // → 110g
        #expect(r.totals.kcal == (143.0 * 1.1).rounded())               // 热量按克数换算 = 157
    }

    @Test func chineseNumeralCup() {
        let r = DietEngine.parseMealText("一杯牛奶")
        #expect(r.items[0].grams == 250)                                // 中文数字 → 250g
    }

    @Test func leadingGrams() {
        let r = DietEngine.parseMealText("200g鸡胸肉")
        #expect(r.items[0].grams == 200)
        #expect(abs(r.items[0].macros.proteinG - 62) < 0.5)             // 蛋白质 62g
    }

    @Test func plusSeparator() {
        let r = DietEngine.parseMealText("30g蛋白粉+一根香蕉")
        #expect(r.items.count == 2 && r.totals.proteinG > 20 && r.totals.carbsG > 20)
    }

    @Test func halfBlockChocolate() {
        let r = DietEngine.parseMealText("半块巧克力")
        #expect(r.items[0].grams == 10)                                 // 半块 → 10g
    }

    @Test func tailGrams() {
        let r = DietEngine.parseMealText("米饭300g")
        #expect(r.items[0].grams == 300 && r.items[0].name == "米饭")   // 尾部克数
    }

    @Test func liangBowlRice() {
        let r = DietEngine.parseMealText("两碗米饭")
        #expect(r.items[0].grams == 400)                                // 两碗 = 2×200g
    }

    @Test func mixedSeparators() {
        let r = DietEngine.parseMealText("一个鸡蛋，一份鸡胸肉、一把坚果")
        #expect(r.items.count == 3)                                     // 顿号/逗号分隔 → 3 项
    }

    @Test func unmatchedNotEstimated() {
        let r = DietEngine.parseMealText("2个鸡蛋+佛跳墙")
        #expect(r.items.count == 1 && r.unmatched.count == 1 && r.unmatched[0] == "佛跳墙")
    }

    @Test func emptyText() {
        let r = DietEngine.parseMealText("")
        #expect(r.items.count == 0 && r.totals.kcal == 0)               // 空文本不崩溃
    }
}

// MARK: - 扩充库与新单位（nutrition.test.mjs:130-149）

@Suite
struct DietExtendedLibraryTests {

    @Test func homeStyleDishes() {
        #expect(DietEngine.findFood("宫保鸡丁")!.per100g.kcal == 130)
        #expect(DietEngine.findFood("红烧肉")!.per100g.kcal == 400)
        #expect(DietEngine.findFood("鸡腿")!.per100g.proteinG == 16)
        #expect(DietEngine.findFood("火龙果")!.tags.contains(.fruit))
        #expect(DietEngine.findFood("手抓饼")!.per100g.portionUnit == "个")
        #expect(DietEngine.findFood("电解质水")!.per100g.kcal == 25)
        #expect(DietEngine.findFood("黄焖鸡米饭") != nil)
    }

    @Test func newUnits() {
        #expect(DietEngine.parseMealText("一袋鸡胸肉丸").items[0].grams == 100)   // 袋
        #expect(DietEngine.parseMealText("二两白酒").items[0].grams == 100)       // 市制两 = 50g
        #expect(DietEngine.parseMealText("两碗米饭").items[0].grams == 400)       // 两按数量 2 解析
        #expect(DietEngine.parseMealText("一套煎饼果子").items[0].grams == 250)   // 套
        #expect(DietEngine.parseMealText("三瓣柚子").items[0].grams == 300)       // 瓣
    }

    @Test func mixedNewLibraryItems() {
        let r = DietEngine.parseMealText("一串葡萄、一份宫保鸡丁、一杯冰红茶")
        #expect(r.items.count == 3 && r.unmatched.count == 0)
    }
}

// MARK: - 目标（nutrition.test.mjs:45-50）

@Suite
struct DietTargetsTests {

    @Test func withBodyweight() {
        let tg = DietEngine.targets(bodyweightKg: 70, trainedToday: false)
        #expect(tg.proteinLo == 112 && tg.proteinHi == 154)             // 70kg 蛋白 112–154
        #expect(tg.kcal == 2100)                                        // 70kg 热量 2100
    }

    @Test func withoutBodyweight() {
        let tg = DietEngine.targets(bodyweightKg: nil, trainedToday: false)
        #expect(tg.kcal == 2000 && tg.proteinLo == 80)                  // 无体重默认值
        #expect(tg == NutritionTargets())                               // 默认 init = 无体重默认
    }
}

// MARK: - 汇总（nutrition.test.mjs:52-62）

@Suite
struct DietSummarizeTests {

    private var entries: [DietEntry] {
        [
            entry(day(0, 8), .breakfast, "2个鸡蛋+一杯牛奶+一份燕麦"),
            entry(day(0, 12), .lunch, "一份鸡胸肉+一碗米饭+一份西兰花"),
            entry(day(0, 19), .dinner, "150g牛肉+半碗米饭"),
        ]
    }

    @Test func dayTotalsSane() {
        let s = DietEngine.summarize(entries)
        #expect(s.totals.kcal > 1200 && s.totals.kcal < 2000)           // 当日总热量合理
        #expect(s.totals.proteinG > 100)                                 // 当日蛋白质
    }

    @Test func byMealAggregation() {
        let s = DietEngine.summarize(entries)
        #expect(s.byMeal[.lunch]?.count == 1)
        #expect((s.byMeal[.breakfast]?.kcal ?? 0) > 0)
    }

    @Test func tagCounts() {
        let s = DietEngine.summarize(entries)
        #expect(s.tagCounts[.veg] == 1)
        #expect((s.tagCounts[.protein] ?? 0) >= 3)
    }

    @Test func tagsOnlyFromLibraryItems() {
        // §3.4 口径：tags 只聚合库命中项，手估项无标签不参与；宏量含手估
        let p = DietEngine.parseMealText("2个鸡蛋")
        let manual = ManualFoodItem(name: "神秘菜", grams: 100,
                                    per100g: Per100g(kcal: 400, proteinG: 20, carbsG: 10, fatG: 5))
        let e = DietEntry(date: day(0, 8), meal: .breakfast, rawText: "2个鸡蛋",
                          items: p.items, manualItems: [manual], unmatched: p.unmatched,
                          totals: DietEngine.entryTotals(parsed: p.totals, manualItems: [manual]))
        let s = DietEngine.summarize([e])
        #expect(s.tagCounts[.protein] == 1 && s.tagCounts[.veg] == nil)
        #expect(s.itemCount == 1 && s.unmatchedCount == 0)
        #expect(s.totals.kcal == 157 + 400)
    }
}

// MARK: - 当日建议 + 训练联动（nutrition.test.mjs:64-79）

@Suite
struct DietDailyAdviceTests {

    private var entries: [DietEntry] {
        [
            entry(day(0, 8), .breakfast, "2个鸡蛋+一杯牛奶+一份燕麦"),
            entry(day(0, 12), .lunch, "一份鸡胸肉+一碗米饭+一份西兰花"),
            entry(day(0, 19), .dinner, "150g牛肉+半碗米饭"),
        ]
    }

    /// 训练 18:00–19:30，主练胸肩（JS wo fixture）
    private var wo: Workout {
        Workout(startedAt: day(0, 18), endedAt: day(0, 19).addingTimeInterval(30 * 60))
    }

    private func advice(_ dayEntries: [DietEntry], workouts: [Workout]) -> [String] {
        DietEngine.dailySummary(dayEntries, day: today, workouts: workouts,
                                bodyweightKg: 70, calendar: cal, now: base).advice
    }

    @Test func postWorkoutPrompt() {
        // 有未吃练后餐提醒
        let a = advice(entries, workouts: [wo])
        #expect(a.contains { $0.contains("练后") })
    }

    @Test func postWorkoutEatenCheckmark() {
        // 练后餐已吃（19:30 记 postworkout）→ 打勾文案
        let withPost = entries + [entry(day(0, 20).addingTimeInterval(-30 * 60), .postworkout, "一勺蛋白粉+一根香蕉")]
        let a = advice(withPost, workouts: [wo])
        #expect(a.contains { $0.contains("练后餐已经吃上") })
    }

    @Test func proteinGapOnTrainedDay() {
        // 训练日蛋白缺口文案
        let lightDay = [entry(day(0, 8), .breakfast, "一碗白粥+一个包子")]
        let a = advice(lightDay, workouts: [wo])
        #expect(a.contains { $0.contains("蛋白质") && $0.contains("目标") })
    }

    @Test func emptyDayHint() {
        let a = advice([], workouts: [])
        #expect(a.first?.contains("还没记") == true)
    }

    @Test func lateSnackAdvice() {
        // 晚 9 点后加餐提醒
        let late = entries + [entry(day(0, 22), .snack, "一包饼干")]
        let a = advice(late, workouts: [])
        #expect(a.contains { $0.contains("9 点后") })
    }

    @Test func adviceCappedAtFour() {
        // 日建议上限 4 条（§3.4）：蛋白偏少 + 热量过低 + 无蔬果 + 晚加餐 + junk≥3 + 未识别 同时命中
        let heavy = [
            entry(day(0, 8), .breakfast, "一碗白粥"),
            entry(day(0, 22), .snack, "一块蛋糕+一包饼干+一罐可乐+佛跳墙"),
        ]
        let a = advice(heavy, workouts: [])
        #expect(a.count == 4)
    }
}

// MARK: - 阶段总结（nutrition.test.mjs:81-104）

@Suite
struct DietPeriodTests {

    private var dietEntries: [DietEntry] {
        var list: [DietEntry] = []
        for i in 0..<7 {
            list.append(entry(day(i, 8), .breakfast, "2个鸡蛋+一杯牛奶"))
            list.append(entry(day(i, 12), .lunch, "一份鸡胸肉+一碗米饭+一份炒青菜"))
            list.append(entry(day(i, 19), .dinner, "200g牛肉+一碗米饭"))
        }
        list.append(entry(day(1, 22), .snack, "一罐可乐"))
        list.append(entry(day(3, 22), .snack, "一块蛋糕"))
        return list
    }

    private var workouts: [Workout] {
        [
            Workout(startedAt: day(1, 19), endedAt: day(1, 20)),
            Workout(startedAt: day(3, 19), endedAt: day(3, 20)),
            Workout(startedAt: day(5, 19), endedAt: day(5, 20)),
        ]
    }

    /// 近 7 天区间（含今日）
    private var weekSpan: DateSpan {
        DateSpan(startDay: DayKey(day(6, 12), calendar: cal), endDay: today)
    }

    private func summarizePeriod() -> DietPeriodSummary {
        DietEngine.periodDiet(dietEntries, workouts: workouts, in: weekSpan,
                              bodyweightKg: 70, calendar: cal)
    }

    @Test func trackedDays() {
        let pd = summarizePeriod()
        #expect(pd.daysTracked == 7)                                     // 7 天都有记录
        #expect(pd.trackedDayKeys.count == 7 && pd.trackedDayKeys.last != nil)  // 按天序列长度 7
    }

    @Test func averageKcal() {
        let pd = summarizePeriod()
        #expect(pd.avg.kcal > 1200)                                      // 日均热量
    }

    @Test func topFoods() {
        let pd = summarizePeriod()
        #expect(!pd.topFoods.isEmpty && pd.topFoods[0].count >= 7)       // 高频食物 Top1（米饭×14）
    }

    @Test func lateDays() {
        let pd = summarizePeriod()
        #expect(pd.lateDays == 2)                                        // 晚加餐天数
    }

    @Test func trainingLink() {
        let pd = summarizePeriod()
        #expect(pd.trainingLink.trainedDays == 3)                        // 训练日 3 天
        #expect(pd.trainingLink.proteinHitOnTrainedDays == 3)            // 训练日蛋白质全达标
    }

    @Test func dualHitRateConventions() {
        // B1 双口径并存：trainingDayHitRate（训练日口径，报告用）= 3/3；
        // proteinHitDays/daysTracked（全记录日口径，budget 注入用）= 7/7
        let pd = summarizePeriod()
        #expect(pd.trainingLink.trainingDayHitRate == 1.0)
        #expect(pd.proteinHitDays == 7 && pd.daysTracked == 7)
    }

    @Test func emptyWindowAdvice() {
        let pdEmpty = DietEngine.periodDiet([], workouts: [], in: weekSpan,
                                            bodyweightKg: 70, calendar: cal)
        #expect(pdEmpty.advice.first?.contains("没有") == true)          // 空窗口建议
    }
}

// MARK: - 未识别食物估算助手（nutrition.test.mjs:106-128）

@Suite
struct DietEstimateHelperTests {

    @Test func categoryCount() {
        #expect(DietEngine.estimateCategories.count == 8)                // 8 个估算类别
    }

    @Test func extractGrams() {
        #expect(DietEngine.extractGrams("佛跳墙300g") == 300)            // 抠克数
        #expect(DietEngine.extractGrams("大杯奶茶500毫升") == 500)       // 抠毫升
        #expect(DietEngine.extractGrams("1.5kg西瓜") == 1500)            // 抠 kg
        #expect(DietEngine.extractGrams("一碗不知道什么东西") == nil)     // 无克数 → nil
    }

    @Test func guessCategory() {
        #expect(DietEngine.guessCategory("排骨汤") == "soup")
        #expect(DietEngine.guessCategory("大杯奶茶") == "drink")
        #expect(DietEngine.guessCategory("手打柠檬茶") == "drink")
        #expect(DietEngine.guessCategory("红烧肉") == "meat")
        #expect(DietEngine.guessCategory("扬州炒饭") == "staple")
        #expect(DietEngine.guessCategory("炒时蔬") == "veg")
        #expect(DietEngine.guessCategory("辣条两包") == "snack")
        #expect(DietEngine.guessCategory("神秘料理") == "other")
    }

    @Test func estimateFor() {
        let est = DietEngine.estimateFor(categoryKey: "meat", grams: 200)
        #expect(est.kcal == 380 && est.proteinG == 34)                   // 肉菜 200g → 380kcal/蛋白34
    }

    @Test func guessForCombined() {
        let g = DietEngine.guessFor("佛跳墙300g")
        #expect(g.guessCategory == "other" && g.grams == 300)
        #expect(g.macros.kcal == 600)                                    // guessFor 组合
    }

    @Test func guessForSoupDefault() {
        let g = DietEngine.guessFor("酸辣汤")
        #expect(g.guessCategory == "soup" && g.grams == 300)             // 酸辣汤默认 300g
    }

    @Test func entryTotalsMergesManual() {
        let parsed = DietEngine.parseMealText("2个鸡蛋")
        let manual = ManualFoodItem(name: "神秘菜", grams: 100,
                                    per100g: Per100g(kcal: 400, proteinG: 20, carbsG: 10, fatG: 5))
        let totals = DietEngine.entryTotals(parsed: parsed.totals, manualItems: [manual])
        #expect(totals.kcal == parsed.totals.kcal + 400)
        #expect(abs(totals.proteinG - (parsed.totals.proteinG + 20)) < 0.01)
    }

    @Test func excludedManualItemSkipped() {
        // 手估项可整项不计入（isExcluded）
        let parsed = DietEngine.parseMealText("2个鸡蛋")
        var manual = ManualFoodItem(name: "神秘菜", grams: 100,
                                    per100g: Per100g(kcal: 400, proteinG: 20, carbsG: 10, fatG: 5))
        manual.isExcluded = true
        let totals = DietEngine.entryTotals(parsed: parsed.totals, manualItems: [manual])
        #expect(totals == parsed.totals)
    }
}

// MARK: - 自定义食物库（自学习，nutrition.test.mjs:151-164）

@Suite
struct DietCustomFoodTests {

    @Test func cleanFoodName() {
        #expect(DietEngine.cleanFoodName("一份佛跳墙300g") == "佛跳墙")   // 去数量与克数
        #expect(DietEngine.cleanFoodName("两碗自制酸奶") == "自制酸奶")    // 中文数量
    }

    @Test func learnFoodNormalizes() {
        let learned = DietEngine.learnFood(ManualFoodItem(
            name: "一份佛跳墙300g", grams: 300,
            per100g: Per100g(kcal: 200, proteinG: 8, carbsG: 10, fatG: 13.3)))
        #expect(learned != nil)
        #expect(learned!.name == "佛跳墙")
        #expect(learned!.per100g.kcal == 200)                            // 归一每 100g
        #expect(learned!.per100g.portionGrams == 300)
        #expect(learned!.tags == [.custom])                              // 默认 custom 标签
    }

    @Test func learnFoodRejectsZeroValues() {
        #expect(DietEngine.learnFood(ManualFoodItem(
            name: "x", grams: 0,
            per100g: Per100g(kcal: 100, proteinG: 1, carbsG: 1, fatG: 1))) == nil)   // 拒绝无克数
        #expect(DietEngine.learnFood(ManualFoodItem(
            name: "x", grams: 100,
            per100g: Per100g(kcal: 0, proteinG: 1, carbsG: 1, fatG: 1))) == nil)    // 拒绝无热量
    }

    private var customLibrary: [CustomFood] {
        [CustomFood(name: "佛跳墙",
                    per100g: Per100g(kcal: 200, proteinG: 8, carbsG: 10, fatG: 13.3,
                                     portionGrams: 300, portionUnit: "份"))]
    }

    @Test func customLibraryExactMatch() {
        let r = DietEngine.parseMealText("一份佛跳墙", customFoods: customLibrary)
        #expect(r.items.count == 1 && r.items[0].grams == 300 && r.items[0].macros.kcal == 600)
    }

    @Test func customLibraryScalesByGrams() {
        let r = DietEngine.parseMealText("佛跳墙150g", customFoods: customLibrary)
        #expect(r.items[0].macros.kcal == 300)                           // 按克缩放：150g=300kcal
    }

    @Test func builtinUnaffectedByCustom() {
        let r = DietEngine.parseMealText("一个鸡蛋", customFoods: customLibrary)
        #expect(r.items[0].name == "鸡蛋")                               // 内置库不受自定义影响
    }
}

// MARK: - mealOf（nutrition.test.mjs:166-168）

@Suite
struct DietMealLabelTests {

    @Test func mealLabelMapping() {
        #expect(DietEngine.mealLabel(forRawKey: "preworkout") == "练前餐")
        #expect(DietEngine.mealLabel(forRawKey: "???") == "加餐")        // 未知餐次回退
        #expect(MealSlot.postworkout.label == "练后餐")
    }
}

// MARK: - 补充口径：dayIntake / guessMeal（§2.1 冻结 API + §3.4 餐次预选）

@Suite
struct DietCrossDomainTests {

    private var wo: Workout {
        Workout(startedAt: day(0, 18), endedAt: day(0, 19).addingTimeInterval(30 * 60))
    }

    @Test func dayIntakeSnapshot() {
        let withPost = [
            entry(day(0, 8), .breakfast, "2个鸡蛋+一杯牛奶"),
            entry(day(0, 20).addingTimeInterval(-30 * 60), .postworkout, "一勺蛋白粉+一根香蕉"),
        ]
        let intake = DietEngine.dayIntake(withPost, day: today, woStartedAt: day(0, 18), calendar: cal)
        #expect(intake != nil)
        #expect(intake!.hasPostMeal)                                     // meal==postworkout 且 ts≥训练开始
        #expect(intake!.itemCount == 4)
        #expect(intake!.proteinG > 40 && intake!.kcal > 400)
    }

    @Test func dayIntakeNilWhenEmpty() {
        #expect(DietEngine.dayIntake([], day: today, woStartedAt: nil, calendar: cal) == nil)
    }

    @Test func guessMealPrefersPostWorkout() {
        // 练后 2.5h 窗口内且未记练后餐 → 预选练后餐
        #expect(DietEngine.guessMeal(now: day(0, 20), calendar: cal,
                                     workouts: [wo], entries: []) == .postworkout)
        // 已记过练后餐 → 回退时段推断（20 点 → 加餐）
        let postEaten = [entry(day(0, 19).addingTimeInterval(30 * 60), .postworkout, "一勺蛋白粉")]
        #expect(DietEngine.guessMeal(now: day(0, 20), calendar: cal,
                                     workouts: [wo], entries: postEaten) == .snack)
    }

    @Test func guessMealByTimeOfDay() {
        #expect(DietEngine.guessMeal(now: day(0, 9), calendar: cal, workouts: [], entries: []) == .breakfast)
        #expect(DietEngine.guessMeal(now: day(0, 12), calendar: cal, workouts: [], entries: []) == .lunch)
        #expect(DietEngine.guessMeal(now: day(0, 18), calendar: cal, workouts: [], entries: []) == .dinner)
        #expect(DietEngine.guessMeal(now: day(0, 22), calendar: cal, workouts: [], entries: []) == .snack)
    }
}
