import Foundation

// MARK: - 日简报（design.md §3.6；lifttime report.js:150-210 + analysis.js:402-423）

/// 昨晚睡眠简报：时长/起止/感受 + 午睡 + 近 7 晚睡眠债。
/// ⚠ **不含单夜分数**（A3 口径，lifttime report.js:172-176——分数归区间层，
/// 单夜分只经 SleepEngine.score 显式计算，日简报不展示）。
public struct DaySleepBrief: Codable, Sendable, Equatable {
    /// 主睡眠段（时长/起止/感受/就寝锚——SleepNight 本身无分数字段）
    public var night: SleepNight
    /// 当日午睡合计分钟
    public var napMinutes: Int
    /// 近 7 晚（以该日为末日）累计睡眠债（分钟）；lifttime sleepStats(…, 7, …)
    public var weekDebtMinutes: Int
    /// 睡眠目标（分钟）
    public var goalMinutes: Int

    public init(night: SleepNight, napMinutes: Int, weekDebtMinutes: Int, goalMinutes: Int) {
        self.night = night
        self.napMinutes = napMinutes
        self.weekDebtMinutes = weekDebtMinutes
        self.goalMinutes = goalMinutes
    }
}

/// 当日训练摘要（§6 TodayView：次数 + PR 与 DOMS 等级徽标）。
/// 次数/容量/PR 来自 WorkoutEngine.analyzePeriod（单日窗口）；
/// DOMS 与主练部位来自各次训练落盘的分析快照（Model 层数据，历史不漂移）。
public struct DayWorkoutBrief: Codable, Sendable, Equatable {
    /// 当日训练次数
    public var sessions: Int
    /// 当日总容量 kg
    public var volumeKg: Double
    /// 当日个人纪录数（窗口 PR）
    public var prCount: Int
    /// 当日最强烈的一次 DOMS 等级，nil = 无快照
    public var domsLevel: DOMSLevel?
    /// 当日主练部位展示名（快照 primaryMuscles 汇总去重）
    public var primaryLabels: [String]

    public init(sessions: Int, volumeKg: Double, prCount: Int,
                domsLevel: DOMSLevel?, primaryLabels: [String]) {
        self.sessions = sessions
        self.volumeKg = volumeKg
        self.prCount = prCount
        self.domsLevel = domsLevel
        self.primaryLabels = primaryLabels
    }
}

/// 当日饮食简报：dailySummary 透传（域类型即契约）+ 训练日蛋白缺口标志。
/// `proteinGapOnTrainingDay` 是 UI「标黄」的数据标志（lifttime report.js:199-201
/// 的规则版：训练日 && 练后餐未补 && 蛋白 < 下限 → 缺口提示）。
public struct DayDietBrief: Codable, Sendable, Equatable {
    /// 当日宏量汇总 + 目标 + 日建议（≤4 条）
    public var summary: DietDaySummary
    /// 训练日蛋白缺口（标黄标志）
    public var proteinGapOnTrainingDay: Bool
    /// 练后餐已补（当日有训练时的 ✓ 展示）
    public var postWorkoutMealEaten: Bool

    public init(summary: DietDaySummary,
                proteinGapOnTrainingDay: Bool, postWorkoutMealEaten: Bool) {
        self.summary = summary
        self.proteinGapOnTrainingDay = proteinGapOnTrainingDay
        self.postWorkoutMealEaten = postWorkoutMealEaten
    }
}

/// 当日/当周开销与预算进度（lifttime report.js:199-205）。
public struct DayBudgetBrief: Codable, Sendable, Equatable {
    /// 当日开销合计（元）
    public var daySpentYuan: Double
    /// 本周（自然周，周一起，含该日）已用（元），nil = 无数据
    public var weekSpentYuan: Double?
    /// 周预算（元），nil = 未设预算
    public var weekBudgetYuan: Double?
    /// 周预算已用百分比，nil = 未设预算或无数据
    public var weekUsedPercent: Int?

    public init(daySpentYuan: Double, weekSpentYuan: Double?,
                weekBudgetYuan: Double?, weekUsedPercent: Int?) {
        self.daySpentYuan = daySpentYuan
        self.weekSpentYuan = weekSpentYuan
        self.weekBudgetYuan = weekBudgetYuan
        self.weekUsedPercent = weekUsedPercent
    }
}

/// 日简报：五域合一（时间 + 昨晚睡眠 + 当日训练 + 当日饮食 + 当日/当周开销）。
/// 按 `day` 取数——日期翻页 = 换 DayKey 再调一次（§6 TodayView toolbar 箭头）。
public struct DayReport: Codable, Sendable, Equatable {
    public var day: DayKey
    /// 时间投入（总分钟 + Top 分类；TimeEngine.dayBrief 透传）
    public var time: TimeDayBrief
    /// 昨晚睡眠（无单夜分数），nil = 该日无主睡眠记录
    public var sleep: DaySleepBrief?
    /// 当日训练摘要
    public var workout: DayWorkoutBrief
    /// 当日饮食（含训练日蛋白缺口标志）
    public var diet: DayDietBrief
    /// 当日/当周开销与预算进度
    public var budget: DayBudgetBrief
    /// 时间域一句话简评（analysis.js:419-423 dayBrief.summary 的报告侧移植）
    public var timeSummary: String

    public init(day: DayKey, time: TimeDayBrief, sleep: DaySleepBrief?,
                workout: DayWorkoutBrief, diet: DayDietBrief, budget: DayBudgetBrief,
                timeSummary: String) {
        self.day = day
        self.time = time
        self.sleep = sleep
        self.workout = workout
        self.diet = diet
        self.budget = budget
        self.timeSummary = timeSummary
    }
}

extension ReportEngine {

    /// 日简报（五域合一）。`day` 任意日期——翻页即换 day 再调（lifttime
    /// report.js:144-210 以 ts 定位某天的等价物；「今天」文案由 isToday 传入）。
    public static func dayReport(day: DayKey,
                                 inputs: ReportInputs,
                                 calendar: DayCalendar,
                                 now: Date) -> DayReport {
        let isToday = calendar.dayKey(for: now) == day

        // —— 时间：总分钟 + Top 分类（analysis.js dayBrief 时间部分）——
        let time = TimeEngine.dayBrief(inputs.timeBlocks, day: day,
                                       categories: inputs.categories, calendar: calendar)
        let timeSummary: String
        if time.totalMinutes > 0 {
            let heads = time.topCategories.prefix(2)
                .map { "\($0.label) \(Text.duration($0.minutes))" }
                .joined(separator: "、")
            timeSummary = "\(isToday ? "今天" : "这天")共记录投入 \(Text.duration(time.totalMinutes))"
                + (heads.isEmpty ? "" : "，其中 \(heads)")
        } else {
            timeSummary = isToday
                ? "今天还没有时间记录，点「时间」页开始记录第一段。"
                : "这天没有时间记录。"
        }

        // —— 昨晚睡眠：主睡眠 + 午睡 + 近 7 晚睡眠债（无单夜分数）——
        let sleepBrief: DaySleepBrief?
        if let night = SleepEngine.nightForDay(inputs.sleepSessions, day: day, calendar: calendar) {
            // 午睡合计：单日区间的 periodSummary.napMinutes（同引擎口径）
            let singleDay = SleepEngine.periodSummary(inputs.sleepSessions,
                                                      in: DateSpan(startDay: day, endDay: day),
                                                      goalMinutes: inputs.sleepGoalMinutes,
                                                      calendar: calendar)
            // 近 7 晚睡眠债：以该日为末日的 7 天窗口（lifttime sleepStats(…, 7, …)）
            let weekDebt: Int
            if let weekStart = calendar.addingDays(-6, to: day) {
                let week = SleepEngine.periodSummary(inputs.sleepSessions,
                                                     in: DateSpan(startDay: weekStart, endDay: day),
                                                     goalMinutes: inputs.sleepGoalMinutes,
                                                     calendar: calendar)
                weekDebt = week.debtMinutes
            } else {
                weekDebt = singleDay.debtMinutes
            }
            sleepBrief = DaySleepBrief(night: night,
                                       napMinutes: singleDay.napMinutes,
                                       weekDebtMinutes: weekDebt,
                                       goalMinutes: singleDay.goalMinutes)
        } else {
            sleepBrief = nil
        }

        // —— 当日训练：analyzePeriod 单日窗口 + 分析快照徽标 ——
        let span = DateSpan(startDay: day, endDay: day)
        let workoutAnalysis = WorkoutEngine.analyzePeriod(inputs.workouts,
                                                          customExercises: inputs.customExercises,
                                                          in: span, calendar: calendar)
        let dayWorkouts = inputs.workouts.filter { calendar.dayKey(for: $0.startedAt) == day }
        // DOMS 取当日最强烈的一次（severe → mild 顺序首中）
        let domsOrder: [DOMSLevel] = [.severe, .noticeable, .moderate, .mild]
        let doms = domsOrder.first { level in
            dayWorkouts.contains { $0.analysis?.domsLevel == level }
        }
        var primaryLabels: [String] = []
        for workout in dayWorkouts {
            guard let muscles = workout.analysis?.primaryMuscles else { continue }
            for muscle in muscles where !primaryLabels.contains(ExerciseLibrary.muscleLabel(muscle)) {
                primaryLabels.append(ExerciseLibrary.muscleLabel(muscle))
            }
        }
        let workoutBrief = DayWorkoutBrief(sessions: workoutAnalysis.sessions,
                                           volumeKg: workoutAnalysis.volumeKg,
                                           prCount: workoutAnalysis.prs.count,
                                           domsLevel: doms,
                                           primaryLabels: primaryLabels)

        // —— 当日饮食：dailySummary 透传 + 缺口标志（report.js:199-201 规则）——
        let dietSummary = DietEngine.dailySummary(inputs.dietEntries, day: day,
                                                  workouts: inputs.workouts,
                                                  bodyweightKg: inputs.bodyweightKg,
                                                  calendar: calendar, now: now)
        let intake = DietEngine.dayIntake(inputs.dietEntries, day: day,
                                          woStartedAt: dayWorkouts.last?.startedAt,
                                          calendar: calendar)
        let protein = dietSummary.totals.totals.proteinG
        let trained = dietSummary.targets.trainedToday   // 引擎侧判定（同日有训练）
        let gap = trained && !(intake?.hasPostMeal ?? false)
            && protein < Double(dietSummary.targets.proteinLo)
        let dietBrief = DayDietBrief(summary: dietSummary,
                                     proteinGapOnTrainingDay: gap,
                                     postWorkoutMealEaten: trained && (intake?.hasPostMeal ?? false))

        // —— 当日/当周开销与预算进度 ——
        let budgetBrief = dayBudgetBrief(day: day, inputs: inputs,
                                         calendar: calendar, now: now)

        return DayReport(day: day, time: time, sleep: sleepBrief,
                         workout: workoutBrief, diet: dietBrief, budget: budgetBrief,
                         timeSummary: timeSummary)
    }

    /// 当日开销 + 本周预算进度（lifttime report.js:199-205）。
    ///
    /// 口径：日/周开销用**总账口径** totalYuan（含计划外，lifttime dayExp/weekExp
    /// 同为 summarizeSpend().total）；周进度百分比 = 周总账 / 周预算
    /// （report.js:204）。周窗口用 BudgetEngine.weekSpan（自然周周一起，
    /// budget 域自己的语义，report 不重复实现）。
    static func dayBudgetBrief(day: DayKey, inputs: ReportInputs,
                               calendar: DayCalendar, now: Date) -> DayBudgetBrief {
        // 当日（总账口径）
        let dayItems = BudgetEngine.inRange(
            BudgetEngine.mergedExpenses(inputs.expenses, dietEntries: inputs.dietEntries),
            in: DateSpan(startDay: day, endDay: day), calendar: calendar)
        let daySpent = BudgetEngine.summarize(dayItems, calendar: calendar).totalYuan

        // 本周（自然周周一起，含该日）
        var weekSpan = DateSpan(startDay: day, endDay: day)
        if let dayDate = calendar.date(of: day) {
            weekSpan = BudgetEngine.weekSpan(containing: dayDate, calendar: calendar)
        }
        let weekItems = BudgetEngine.inRange(
            BudgetEngine.mergedExpenses(inputs.expenses, dietEntries: inputs.dietEntries),
            in: weekSpan, calendar: calendar)
        let weekSpent = BudgetEngine.summarize(weekItems, calendar: calendar).totalYuan

        let percent: Int?
        if let budget = inputs.weeklyBudgetYuan, budget > 0 {
            percent = Int((weekSpent / budget * 100).rounded())
        } else {
            percent = nil
        }
        return DayBudgetBrief(daySpentYuan: daySpent,
                              weekSpentYuan: weekSpent,
                              weekBudgetYuan: inputs.weeklyBudgetYuan,
                              weekUsedPercent: percent)
    }
}
