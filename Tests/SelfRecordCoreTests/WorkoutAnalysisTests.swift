import Testing
import Foundation
@testable import SelfRecordCore

// MARK: - workout 模块测试（design.md §3.3 测试清单）
//
// 移植 lifttime tests/analysis.test.mjs 全部 55 项断言语义（逐条注明源行号）。
// 例外：analysis.test.mjs:141-146 的 dayBrief 2 项（时间块求和 4200000ms /
// '1小时10分'）属时间域——SelfRecord 的 dayBrief 是 TimeEngine 冻结签名
// （§2.1，收 TimeBlock/TimeCategory），归 time-tracking / report 模块测试基线，
// 不在 workout 模块移植（模块边界 §2：禁止横向）。
// 另按 design.md §3.3「恢复建议消费 RecoveryContext」补自建用例（hasPostMeal /
// fitnessTimeMinutes / dayIntake 三分支，lifttime 测试未覆盖）。
//
// 时间锚定：DayCalendar.utc8()，NOW = 2026-08-21 20:00 UTC+8
// （= lifttime analysis.test.mjs:14 的本地 2026-08-21 20:00 等价物）。

// MARK: - 测试夹具

private enum Fx {
    static let cal = DayCalendar.utc8()
    static let now = ts(2026, 8, 21, 20, 0)

    static func ts(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 20, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        c.timeZone = cal.timeZone
        return cal.calendar.date(from: c)!
    }

    /// (重量, 次数)；重量 0 = 自重（lifttime 的 w:null）。
    static func entry(_ exerciseID: String, _ pairs: [(Double, Int)]) -> WorkoutExerciseEntry {
        WorkoutExerciseEntry(exerciseID: exerciseID,
                             sets: pairs.map { WorkoutSet(weightKg: $0.0, reps: $0.1, timestamp: now) })
    }

    static func wo(_ start: Date, _ entries: [WorkoutExerciseEntry]) -> Workout {
        Workout(startedAt: start, endedAt: start.addingTimeInterval(3600), entries: entries, feeling: 3, notes: "")
    }

    /// 近 N 天窗口（含首尾，= lifttime [end-Nd, end) 的 DaySpan 口径）。
    static func span(days: Int) -> DateSpan {
        let endDay = cal.dayKey(for: now)
        return DateSpan(startDay: cal.addingDays(-(days - 1), to: endDay)!, endDay: endDay)
    }
}

// MARK: - Epley e1RM（analysis.test.mjs:19-22）

@Suite("Workout · Epley e1RM")
struct WorkoutEpleyTests {

    @Test func epleyBasics() {
        #expect(abs(WorkoutEngine.est1RM(weightKg: 100, reps: 5) - 116.667) <= 0.01)   // :19
        #expect(abs(WorkoutEngine.est1RM(weightKg: 60, reps: 1) - 62) <= 0.001)        // :20
    }

    @Test func epleyRepCapAndZero() {
        #expect(WorkoutEngine.est1RM(weightKg: 100, reps: 20)                          // :21 超 15 次封顶
                == WorkoutEngine.est1RM(weightKg: 100, reps: 15))
        #expect(WorkoutEngine.est1RM(weightKg: 0, reps: 10) == 0)                      // :22 空重量/空次数返回 0
        #expect(WorkoutEngine.est1RM(weightKg: 60, reps: 0) == 0)
    }
}

// MARK: - 动作库（analysis.test.mjs:25-29、扩充 :32-39）

@Suite("Workout · 动作库与匹配")
struct WorkoutLibraryTests {

    @Test func aliasAndUnknown() {
        #expect(ExerciseLibrary.find(name: "杠铃卧推", customExercises: [])?.name == "卧推")   // :25 别名→卧推
        #expect(ExerciseLibrary.find(name: "RDL", customExercises: [])?.name == "罗马尼亚硬拉") // :26 别名 RDL
        #expect(ExerciseLibrary.search("划船").count >= 3)                                    // :27 搜索「划船」≥3
        #expect(ExerciseLibrary.find(name: "神秘动作", customExercises: []) == nil)           // :28 未知动作 primary 为空
    }

    @Test func customExerciseTakesPriority() {
        // :29 自定义动作映射生效（匹配顺序：自定义 → 精确名 → 精确别名 → 双向包含）
        let custom = Exercise(id: "uuid-mine", name: "我的独家动作",
                              primaryMuscles: [.chest], isCustom: true)
        let hit = ExerciseLibrary.find(name: "我的独家动作", customExercises: [custom])
        #expect(hit?.id == "uuid-mine")
        #expect(hit?.primaryMuscles.first == .chest)
        // 无自定义库时按内置解析；同名自定义优先于内置别名
        #expect(ExerciseLibrary.find(name: "杠铃卧推", customExercises: [custom])?.name == "卧推")
        let hijack = Exercise(id: "uuid-hijack", name: "杠铃卧推", primaryMuscles: [.back], isCustom: true)
        #expect(ExerciseLibrary.find(name: "杠铃卧推", customExercises: [hijack])?.id == "uuid-hijack")
    }

    @Test func extendedLibrary() {
        #expect(ExerciseLibrary.find(name: "史密斯深蹲", customExercises: [])?.primaryMuscles.contains(.quad) == true)       // :32 → 腿
        #expect(ExerciseLibrary.find(name: "坐姿髋外展", customExercises: [])?.primaryMuscles.contains(.glute) == true)      // :33 → 臀
        #expect(ExerciseLibrary.find(name: "山羊挺身", customExercises: [])?.primaryMuscles.contains(.back) == true)         // :34 → 背
        #expect(ExerciseLibrary.find(name: "壶铃摇摆", customExercises: [])?.primaryMuscles.contains(.hamstring) == true)    // :35 → 腘绳肌
        #expect(ExerciseLibrary.find(name: "战绳", customExercises: [])?.isCardio == true)                                   // :36 → 有氧
        #expect(ExerciseLibrary.find(name: "农夫行走", customExercises: [])?.primaryMuscles.contains(.forearm) == true)      // :37 → 前臂
        #expect(ExerciseLibrary.search("硬拉").count >= 3)                                                                   // :38 硬拉变式 ≥3
        #expect(ExerciseLibrary.search("飞鸟").count >= 2)                                                                   // :39 飞鸟变式 ≥2
    }

    @Test func librarySizeAndUniqueness() {
        // 自建：110+ 动作（design.md §3.3），id（= 规范名）唯一
        #expect(ExerciseLibrary.all.count >= 110)
        #expect(Set(ExerciseLibrary.all.map(\.id)).count == ExerciseLibrary.all.count)
    }

    @Test func searchScoring() {
        // 自建：打分序 = 精确 > 前缀 > 包含（lifttime exercises.js:191-205）
        let hits = ExerciseLibrary.search("卧推")
        #expect(hits.first?.name == "卧推")                    // 精确名第一
        #expect(hits.contains { $0.name == "上斜卧推" })        // 前缀/包含在内
        #expect(hits.contains { $0.name == "史密斯卧推" })
    }
}

// MARK: - sessionStats（analysis.test.mjs:41-49）

@Suite("Workout · sessionStats")
struct WorkoutSessionStatsTests {

    @Test func benchPressVolume() {
        let s1 = WorkoutEngine.sessionStats(
            Fx.wo(Fx.now, [Fx.entry("卧推", [(60, 12), (60, 12), (60, 12)])]))
        #expect(abs(s1.tonnage - 2160) <= 0.01)                       // :43 卧推 60×12×3 容量 2160
        #expect(s1.setCount == 3 && s1.repCount == 36)                // :44 组数/次数统计
        let chest = s1.muscles.first { $0.key == .chest }
        #expect(chest != nil && chest!.share > 0.6)                   // :46 胸为主导 (>60%)
        #expect(s1.muscles.contains { $0.key == .triceps })           // :47 三头作为次要肌群被计入
    }

    @Test func bodyweightZeroVolumeButSetsCounted() {
        let s2 = WorkoutEngine.sessionStats(
            Fx.wo(Fx.now, [Fx.entry("引体向上", [(0, 8), (0, 8)])]))
        #expect(s2.tonnage == 0 && s2.setCount == 2)                  // :49 自重动作容量为 0 但组数计入
        #expect(s2.bodyweightSetCount == 2)
    }

    @Test func muscleShareSplit() {
        // 自建：分摊系数主 1/n、次 0.5/n（analysis.js:36-44——n = 该侧肌群个数）
        // 深蹲 p[quad,glute] s[hamstring,core] 100×10（组容量 1000）：
        // quad=glute=1000×(1/2)=500；hamstring=core=1000×(0.5/2)=250
        let s = WorkoutEngine.sessionStats(Fx.wo(Fx.now, [Fx.entry("深蹲", [(100, 10)])]))
        let vol = { (k: MuscleGroup) in s.muscles.first { $0.key == k }?.volume ?? -1 }
        #expect(abs(vol(.quad) - 500) <= 0.01)
        #expect(abs(vol(.glute) - 500) <= 0.01)
        #expect(abs(vol(.hamstring) - 250) <= 0.01)
        #expect(abs(vol(.core) - 250) <= 0.01)
    }
}

// MARK: - analyzeSession 基础（analysis.test.mjs:51-64）

@Suite("Workout · analyzeSession 基础")
struct WorkoutAnalyzeSessionBasicTests {

    static let chestDay = Fx.wo(Fx.now, [
        Fx.entry("卧推", [(60, 12), (60, 12), (65, 10), (65, 10)]),
        Fx.entry("上斜卧推", [(50, 10), (50, 10), (50, 10)]),
        Fx.entry("侧平举", [(7.5, 15), (7.5, 15), (7.5, 15)]),
    ])
    static let a1 = WorkoutEngine.analyzeSession(chestDay, history: [])

    @Test func primaryMuscleDetected() {
        #expect(Self.a1.primaryMuscles.first == .chest)               // :58 主练识别出「胸」
        #expect(Self.a1.secondaryMuscles.count == 2)                  // 次重点 = 肩、肱三头
    }

    @Test func briefDietRestPostFeelNextDay() {
        let a1 = Self.a1
        #expect(a1.brief.count >= 3 && a1.brief.allSatisfy { $0.count > 5 })   // :59 简评 ≥3 段且非空
        #expect(a1.diet.count >= 3 && a1.rest.count >= 3)                      // :60 饮食/休息建议各 ≥3 条
        #expect(["severe", "noticeable", "moderate", "mild"].contains(a1.domsLevel.rawValue)) // :61 DOMS 等级合法
        #expect(a1.postFeel.count >= 1)                                        // :62 练后感觉预测非空
        #expect(a1.nextDayText.count > 10)                                     // :63 次日感觉文本非空
    }

    @Test func snapshotHasNoNaNAndCodableRoundTrip() {
        // :64 输出无 NaN（快照是落盘/渲染/AI 契约，编码必须干净且可还原）
        do {
            let data = try JSONEncoder().encode(Self.a1)
            let json = String(decoding: data, as: UTF8.self)
            #expect(!json.contains("NaN"))
            let back = try JSONDecoder().decode(WorkoutAnalysisSnapshot.self, from: data)
            #expect(back == Self.a1)
        } catch {
            Issue.record("快照编码/解码失败: \(error)")
            #expect(Bool(false))
        }
    }
}

// MARK: - PR 与强度（analysis.test.mjs:66-76）

@Suite("Workout · PR 与强度")
struct WorkoutPRAndIntensityTests {

    static let hist = [
        Fx.wo(Fx.now.addingTimeInterval(-14 * 86400), [Fx.entry("卧推", [(60, 8)])]),                       // e1=76
        Fx.wo(Fx.now.addingTimeInterval(-7 * 86400),
              [Fx.entry("卧推", [(62, 8)]), Fx.entry("深蹲", [(100, 5)])]),
    ]

    @Test func heavierBenchDetectedAsPR() {
        let prRun = WorkoutEngine.analyzeSession(
            Fx.wo(Fx.now, [Fx.entry("卧推", [(65, 8)]), Fx.entry("深蹲", [(95, 5)])]),
            history: Self.hist)
        #expect(prRun.prs.count == 1 && prRun.prs[0].exerciseID == "卧推")     // :72 更重的卧推被识别为 PR
        #expect(prRun.prs[0].isNewBaseline == false)                          // 刷新纪录（非首次基准）
        // :73 PR 此前最好值正确（62×8 ⇒ ~78.5；PRRecord 不存 prev，经 bestE1History 锚定）
        let prev = WorkoutEngine.bestE1History(Self.hist, before: nil)["卧推"] ?? 0
        #expect(prev > 77 && prev < 80)
        // :74 强度比率 ≥90%（ratio=1.048 ≥ 0.95 → 高档；快照契约只留 intensityBand）
        #expect(prRun.intensityBand == .high)
    }

    @Test func lighterBenchNoPR() {
        let noPr = WorkoutEngine.analyzeSession(
            Fx.wo(Fx.now, [Fx.entry("卧推", [(50, 8)])]),
            history: Self.hist)
        #expect(noPr.prs.isEmpty)                                             // :76 重量下降不产生 PR
    }

    @Test func firstBaselineFlag() {
        // 自建：PR 区分「刷新纪录」与「首次基准」（prev=0 → isNewBaseline）
        let first = WorkoutEngine.analyzeSession(
            Fx.wo(Fx.now, [Fx.entry("卧推", [(60, 8)])]), history: [])
        #expect(first.prs.count == 1 && first.prs[0].isNewBaseline == true)
        #expect(first.brief.contains { $0.contains("首次记录") })
    }
}

// MARK: - 容量对比 & DOMS（analysis.test.mjs:78-91）

@Suite("Workout · 容量对比与 DOMS")
struct WorkoutVolumeAndDOMSTests {

    static let vols = (3...6).reversed().map {                                   // NOW-6d … NOW-3d 深蹲 80×10×3
        Fx.wo(Fx.now.addingTimeInterval(-Double($0) * 86400),
              [Fx.entry("深蹲", [(80, 10), (80, 10), (80, 10)])])
    }
    static let aBig = WorkoutEngine.analyzeSession(
        Fx.wo(Fx.now, [
            Fx.entry("深蹲", [(100, 12), (100, 12), (100, 12), (100, 12)]),
            Fx.entry("保加利亚分腿蹲", [(40, 10), (40, 10)]),
            Fx.entry("腿弯举", [(35, 12)]),
        ]),
        history: vols,
        recovery: RecoveryContext(bodyweightKg: 70))

    @Test func bigLegDayVolumeAndDOMS() {
        let aBig = Self.aBig
        #expect(aBig.volumeVsRecentAverage != nil && aBig.volumeVsRecentAverage! > 1.3)   // :84 容量显著高于均值 (>130%)
        let legMuscles: Set<MuscleGroup> = [.quad, .hamstring, .glute, .calf]
        #expect(!Set(aBig.primaryMuscles).isDisjoint(with: legMuscles))                   // :85 主练落在腿臀
        #expect(aBig.domsLevel == .noticeable || aBig.domsLevel == .severe)              // :86 大容量腿日 → 明显/强烈
        let first = aBig.diet.first ?? ""
        #expect(first.contains("112–154g")
                || first.range(of: #"\d+–\d+g"#, options: .regularExpression) != nil)     // :87 按体重给出蛋白质克数
    }

    @Test func lightFamiliarDayStaysMild() {
        let aLight = WorkoutEngine.analyzeSession(
            Fx.wo(Fx.now, [Fx.entry("弯举", [(10, 12)])]),
            history: Self.vols + [
                Fx.wo(Fx.now.addingTimeInterval(-86400), [Fx.entry("弯举", [(10, 12)])]),
            ])
        #expect(aLight.domsLevel == .mild || aLight.domsLevel == .moderate)               // :91 轻量熟悉动作 DOMS 偏轻
    }
}

// MARK: - 自重/有氧（analysis.test.mjs:93-96）

@Suite("Workout · 自重与有氧")
struct WorkoutBodyweightCardioTests {

    @Test func cardioDay() {
        let cardio = WorkoutEngine.analyzeSession(
            Fx.wo(Fx.now, [Fx.entry("跑步", [(0, 30)]), Fx.entry("平板支撑", [(0, 3)])]),
            history: [])
        #expect(cardio.totals.volumeKg == 0 && cardio.totals.setCount == 2)               // :95 有氧/自重容量计 0、组数正确
        #expect(cardio.primaryMuscles.contains(.full) || cardio.primaryMuscles.contains(.core)) // :96 主练识别 全身/核心
    }
}

// MARK: - 未知动作稳健性（analysis.test.mjs:98-100）

@Suite("Workout · 未知动作稳健性")
struct WorkoutUnknownExerciseTests {

    @Test func unknownExerciseDoesNotCrash() {
        let unknown = WorkoutEngine.analyzeSession(
            Fx.wo(Fx.now, [Fx.entry("自创推法", [(30, 10)])]), history: [])
        #expect(unknown.primaryMuscles.isEmpty)                 // :100 未知动作不崩溃（无主练、其余正常产出）
        #expect(unknown.totals.setCount == 1 && unknown.totals.volumeKg == 300)
        #expect(unknown.brief.isEmpty == false)
    }
}

// MARK: - 恢复建议消费 RecoveryContext（design.md §3.3 / §2 注入契约；自建）

@Suite("Workout · RecoveryContext 消费")
struct WorkoutRecoveryContextTests {

    private func analyze(_ recovery: RecoveryContext) -> WorkoutAnalysisSnapshot {
        WorkoutEngine.analyzeSession(Fx.wo(Fx.now, [Fx.entry("卧推", [(60, 8)])]),
                                     history: [],
                                     recovery: recovery)
    }

    @Test func dayIntakeRecordedWithDeficit() {
        // analysis.js:193-197 三分支①：itemCount>0 且未达下限 →「已记录 Xg…还差约 Yg」
        let snap = analyze(RecoveryContext(bodyweightKg: 70,
                                           dayIntake: DayIntake(proteinG: 60, kcal: 1800,
                                                                itemCount: 5, hasPostMeal: false)))
        let first = snap.diet.first ?? ""
        #expect(first.contains("已记录今天摄入约 60g"))
        #expect(first.contains("还差约 52g"))                       // 112(=70×1.6) − 60
    }

    @Test func dayIntakeRecordedGoalReached() {
        // 三分支①：已达下限 →「下限已达成」
        let snap = analyze(RecoveryContext(bodyweightKg: 70,
                                           dayIntake: DayIntake(proteinG: 120, kcal: 2200,
                                                                itemCount: 6, hasPostMeal: false)))
        #expect(snap.diet.first?.contains("下限已达成") == true)
    }

    @Test func bodyweightOnlyBranch() {
        // 三分支②：无 dayIntake 有体重 → 按体重给目标区间
        let snap = analyze(RecoveryContext(bodyweightKg: 70))
        #expect(snap.diet.first?.contains("112–154g") == true)
    }

    @Test func genericBranchWithoutBodyweight() {
        // 三分支③：两者皆无 → 引导去设置填体重
        let snap = analyze(RecoveryContext())
        #expect(snap.diet.first?.contains("「设置」") == true)
    }

    @Test func postMealCheckedIn() {
        // analysis.js:211：hasPostMeal → 「练后餐已经吃上了 ✓」
        let snap = analyze(RecoveryContext(dayIntake: DayIntake(proteinG: 60, kcal: 1800,
                                                                itemCount: 5, hasPostMeal: true)))
        #expect(snap.rest.first?.contains("练后餐已经吃上了 ✓") == true)
        let noMeal = analyze(RecoveryContext(dayIntake: DayIntake(proteinG: 60, kcal: 1800,
                                                                  itemCount: 5, hasPostMeal: false)))
        #expect(noMeal.rest.first?.contains("练后餐") == false)
    }

    @Test func fitnessTimeMentionedInBrief() {
        // analysis.js:263：fitnessTimeMinutes > 0 → 「今天为这次训练总共花掉 X」
        let snap = analyze(RecoveryContext(fitnessTimeMinutes: 95))
        #expect(snap.brief.contains { $0.contains("今天为这次训练总共花掉") && $0.contains("1 小时 35 分") })
        let none = analyze(RecoveryContext())
        #expect(none.brief.allSatisfy { !$0.contains("总共花掉") })
    }
}

// MARK: - analyzePeriod（analysis.test.mjs:102-135）

@Suite("Workout · analyzePeriod")
struct WorkoutPeriodTests {

    static let periodSeed = [
        Fx.wo(Fx.now.addingTimeInterval(-5 * 86400), [Fx.entry("卧推", [(60, 10), (60, 10), (60, 10)])]),
        Fx.wo(Fx.now.addingTimeInterval(-3 * 86400), [Fx.entry("引体向上", [(0, 8), (0, 8)])]),
        Fx.wo(Fx.now.addingTimeInterval(-1 * 86400), [Fx.entry("深蹲", [(80, 10), (80, 10)])]),
        Fx.wo(Fx.now, [Fx.entry("硬拉", [(100, 5), (100, 5)])]),
        // 上一窗口：一次小容量
        Fx.wo(Fx.now.addingTimeInterval(-12 * 86400), [Fx.entry("卧推", [(40, 8)])]),
    ]

    @Test func sevenDayWindowBasics() {
        let p7 = WorkoutEngine.analyzePeriod(Self.periodSeed, in: Fx.span(days: 7), calendar: Fx.cal)
        #expect(p7.sessions == 4)                                                // :112 7 天内 4 次训练
        #expect(abs(p7.freqPerWeek - 4.0) <= 0.01)                               // :113 频率 4 次/周
        #expect(p7.trendPct != nil && p7.trendPct! > 100)                        // :114 容量较上一窗口大增
        #expect(p7.groups.count >= 3)                                            // :115 部位分组 ≥3
        #expect(p7.prs.count >= 1)                                               // :116 窗口内识别到 PR
        #expect(p7.tone.count > 10)                                              // :117 状态评语非空
        #expect(p7.dailyVolume.count == 7)                                       // :118 dailyVolume 返回 7 天
        #expect(p7.restDays == 3)                                                // 7 天 − 4 个训练日
    }

    @Test func pushHeavyBalanceNote() {
        // :120-124 推多拉少 → 平衡提醒
        let pushHeavy = (0..<3).map {
            Fx.wo(Fx.now.addingTimeInterval(-Double($0) * 2 * 86400), [
                Fx.entry("卧推", [(80, 10), (80, 10)]),
                Fx.entry("推举", [(40, 10), (40, 10)]),
            ])
        }
        let pPush = WorkoutEngine.analyzePeriod(pushHeavy, in: Fx.span(days: 7), calendar: Fx.cal)
        #expect(pPush.balanceNotes.contains { $0.contains("拉类") })
    }

    @Test func streakSixDaysSuggestsRest() {
        // :127-131 连续 6 天训练 → streak=6 + 休息提醒
        let daily = (0..<6).map {
            Fx.wo(Fx.now.addingTimeInterval(-Double($0) * 86400), [Fx.entry("卧推", [(60, 10)])])
        }
        let pStreak = WorkoutEngine.analyzePeriod(daily, in: Fx.span(days: 7), calendar: Fx.cal)
        #expect(pStreak.streak == 6)
        #expect(pStreak.tone.contains("休息") || pStreak.advice.contains { $0.contains("休息") })
    }

    @Test func emptyWindowDoesNotCrash() {
        // :134-135 空窗口不崩溃且给出重启建议
        let pEmpty = WorkoutEngine.analyzePeriod([], in: Fx.span(days: 7), calendar: Fx.cal)
        #expect(pEmpty.sessions == 0 && pEmpty.tone.count > 10)
        #expect(pEmpty.groups.isEmpty && pEmpty.dailyVolume.count == 7)
    }

    @Test func frozenSignatureCallable() {
        // §12.2 签名断言（占位用例的实装版）：冻结物 B 的 3 参签名可调用且真实产出。
        // 桩时代用 `== WorkoutPeriodAnalysis()` 断言相等；实装后空窗口产出真实
        // 分析（tone 非空），改为语义断言。
        let cal = DayCalendar.utc8()
        let span = DateSpan(startDay: DayKey(rawValue: "2026-10-01")!,
                            endDay: DayKey(rawValue: "2026-10-07")!)
        let result = WorkoutEngine.analyzePeriod([], in: span, calendar: cal)
        #expect(result.sessions == 0 && result.days == 7)
        // 自定义动作版重载与委托口径一致
        let withCustom = WorkoutEngine.analyzePeriod([], customExercises: [], in: span, calendar: cal)
        #expect(withCustom == result)
    }

    @Test func invalidSpanYieldsEmptyAnalysis() {
        // 自建：start > end 的非法区间 → 空分析不崩溃
        let bad = DateSpan(startDay: DayKey(rawValue: "2026-10-07")!,
                           endDay: DayKey(rawValue: "2026-10-01")!)
        let r = WorkoutEngine.analyzePeriod(Self.periodSeed, in: bad, calendar: Fx.cal)
        #expect(r == WorkoutPeriodAnalysis())
    }
}

// MARK: - bestE1History（analysis.test.mjs:137-139）

@Suite("Workout · bestE1History")
struct WorkoutBestE1HistoryTests {

    @Test func cutoffFilter() {
        let hist = WorkoutPRAndIntensityTests.hist + [
            Fx.wo(Fx.now.addingTimeInterval(86400), [Fx.entry("卧推", [(200, 1)])]),   // 未来，应被 before 过滤
        ]
        let bh = WorkoutEngine.bestE1History(hist, before: Fx.now)
        #expect(abs((bh["卧推"] ?? 0) - 78.533) <= 0.01)     // :139 截止时间过滤正确(62×8=78.5)
    }
}
