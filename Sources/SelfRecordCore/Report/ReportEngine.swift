import Foundation

// MARK: - report 模块（design.md §3.6）：报告（五域聚合）
//
// 聚合点：只调用五个域引擎的**只读聚合 API**（§2.1 冻结物 B——
// TimeEngine.dayBrief/dailyBreakdown、SleepEngine.nightForDay/periodSummary、
// WorkoutEngine.analyzePeriod、DietEngine.dailySummary/periodDiet、
// BudgetEngine.status/proteinEconomy），方向永远 report → 各域，反向禁止。
//
// lifttime 对应：js/reportBuilder.js（buildReportData :49-138 / renderRuleReport
// :141-236）+ js/analysis.js:402-423 dayBrief + js/report.js:150-210 日简报。
//
// 契约（§9-7）：报告 JSON 结构 = 未来 AI 输出契约 = 渲染契约——
// ReportData（数字）+ RuleReport（分板块文案）一份渲染两用；AI 后置。

// MARK: - 聚合输入

/// 五域聚合的原始输入（各域记录 + 跨域参数，均为纯值快照）。
/// report 不持有存储引用；「历史」显式收数组（§8 约定 7）。
public struct ReportInputs: Codable, Sendable, Equatable {
    public var categories: [TimeCategory] = []
    public var timeBlocks: [TimeBlock] = []
    public var sleepSessions: [SleepSession] = []
    public var workouts: [Workout] = []
    public var dietEntries: [DietEntry] = []
    public var expenses: [Expense] = []
    /// 自定义动作（训练阶段分析解析条目用；analyzePeriod 的注入契约）
    public var customExercises: [Exercise] = []
    public var bodyweightKg: Double?
    /// 睡眠目标（分钟）；≤0 时 sleep 模块回退 480
    public var sleepGoalMinutes: Int = SleepEngine.defaultGoalMinutes
    /// 周预算（元，日简报的周进度用；阶段报告的区间聚合不占预算额度，传 nil）
    public var weeklyBudgetYuan: Double?

    public init(categories: [TimeCategory] = [],
                timeBlocks: [TimeBlock] = [],
                sleepSessions: [SleepSession] = [],
                workouts: [Workout] = [],
                dietEntries: [DietEntry] = [],
                expenses: [Expense] = [],
                customExercises: [Exercise] = [],
                bodyweightKg: Double? = nil,
                sleepGoalMinutes: Int = SleepEngine.defaultGoalMinutes,
                weeklyBudgetYuan: Double? = nil) {
        self.categories = categories
        self.timeBlocks = timeBlocks
        self.sleepSessions = sleepSessions
        self.workouts = workouts
        self.dietEntries = dietEntries
        self.expenses = expenses
        self.customExercises = customExercises
        self.bodyweightKg = bodyweightKg
        self.sleepGoalMinutes = sleepGoalMinutes
        self.weeklyBudgetYuan = weeklyBudgetYuan
    }
}

// MARK: - 报告引擎

/// 报告引擎（§3.6）：日简报 + 阶段综合报告 + 规则版渲染。
public enum ReportEngine {

    // MARK: 阶段报告（五域聚合 → ReportData）

    /// 阶段综合报告：区间 → 五域聚合 ReportData（规则版立即出）。
    ///
    /// 五域取数路径（只经 §2.1 冻结 API，方向 report → 各域）：
    /// - 时间：TimeEngine.dailyBreakdown（归属 = start 所在日；report 只做
    ///   总量/活跃天/去向 Top 汇总，lifttime reportBuilder.js:56-71）；
    /// - 睡眠：SleepEngine.periodSummary（区间中位锚、缺夜不进均值不记债，
    ///   reportBuilder.js:73-96）；
    /// - 训练：WorkoutEngine.analyzePeriod（频率/容量环比/部位/PR/平衡）；
    /// - 饮食：DietEngine.periodDiet（日均宏量/达标天数/Top 食物）；
    /// - 预算：BudgetEngine.status（manual + diet auto 合并开销流汇总）。
    public static func periodReport(range: ReportRange,
                                    inputs: ReportInputs,
                                    calendar: DayCalendar,
                                    now: Date) -> ReportData {
        ReportData(
            range: ReportRangeInfo(label: range.label, dayCount: range.dayCount, span: range.span),
            time: timeSection(blocks: inputs.timeBlocks, categories: inputs.categories,
                              range: range, calendar: calendar),
            sleep: sleepSection(sessions: inputs.sleepSessions, range: range,
                                goalMinutes: inputs.sleepGoalMinutes, calendar: calendar),
            workout: workoutSection(workouts: inputs.workouts,
                                    customExercises: inputs.customExercises,
                                    range: range, calendar: calendar),
            diet: dietSection(entries: inputs.dietEntries, workouts: inputs.workouts,
                              range: range, bodyweightKg: inputs.bodyweightKg,
                              calendar: calendar),
            budget: budgetSection(expenses: inputs.expenses, dietEntries: inputs.dietEntries,
                                  range: range, calendar: calendar, now: now)
        )
    }

    /// 时间域汇总：dailyBreakdown → 总量 + 活跃天 + 去向 Top（前 4）。
    static func timeSection(blocks: [TimeBlock], categories: [TimeCategory],
                            range: ReportRange, calendar: DayCalendar) -> ReportTimeSection {
        let breakdown = TimeEngine.dailyBreakdown(blocks, in: range.span,
                                                  categories: categories, calendar: calendar)
        var perCategory: [String: Double] = [:]
        var activeDays = 0
        for (_, perDay) in breakdown {
            let dayTotal = perDay.values.reduce(0, +)
            if dayTotal > 0 { activeDays += 1 }
            for (categoryID, minutes) in perDay {
                perCategory[categoryID, default: 0] += minutes
            }
        }
        let top = perCategory
            .map { ReportTimeSlice(label: label(of: $0.key, in: categories), minutes: $0.value) }
            .sorted { lhs, rhs in
                lhs.minutes != rhs.minutes ? lhs.minutes > rhs.minutes : lhs.label < rhs.label
            }
            .prefix(4)
        return ReportTimeSection(totalMinutes: perCategory.values.reduce(0, +),
                                 activeDays: activeDays,
                                 dayCount: range.dayCount,
                                 top: Array(top))
    }

    /// 分类 id → 展示名（查不到回「其他」，lifttime reportBuilder.js:51-54 catLabel）。
    static func label(of categoryID: String, in categories: [TimeCategory]) -> String {
        categories.first { $0.id == categoryID }?.label ?? "其他"
    }

    /// 睡眠域汇总：periodSummary → 简报字段（不含任何单夜分数字段，A3 口径）。
    static func sleepSection(sessions: [SleepSession], range: ReportRange,
                             goalMinutes: Int, calendar: DayCalendar) -> ReportSleepSection {
        let summary = SleepEngine.periodSummary(sessions, in: range.span,
                                                goalMinutes: goalMinutes, calendar: calendar)
        return ReportSleepSection(nights: summary.nights,
                                  dayCount: range.dayCount,
                                  avgNightMinutes: summary.avgMinutes,
                                  avgScore: summary.avgScore,
                                  madMinutes: summary.madMinutes,
                                  debtMinutes: summary.debtMinutes,
                                  napMinutes: summary.napMinutes,
                                  goalMinutes: summary.goalMinutes)
    }

    /// 训练域汇总：analyzePeriod（自定义动作注入契约）→ 展示字段。
    static func workoutSection(workouts: [Workout], customExercises: [Exercise],
                               range: ReportRange, calendar: DayCalendar) -> ReportWorkoutSection {
        let analysis = WorkoutEngine.analyzePeriod(workouts, customExercises: customExercises,
                                                   in: range.span, calendar: calendar)
        return ReportWorkoutSection(sessions: analysis.sessions,
                                    freqPerWeek: analysis.freqPerWeek,
                                    volumeKg: analysis.volumeKg,
                                    trendPercent: analysis.trendPct,
                                    prCount: analysis.prs.count,
                                    groupLabels: analysis.groups.map(\.label),
                                    balanceNotes: analysis.balanceNotes,
                                    advice: analysis.advice)
    }

    /// 饮食域汇总：periodDiet → 展示字段（双达标率口径并存，B1）。
    static func dietSection(entries: [DietEntry], workouts: [Workout], range: ReportRange,
                            bodyweightKg: Double?, calendar: DayCalendar) -> ReportDietSection {
        let summary = DietEngine.periodDiet(entries, workouts: workouts, in: range.span,
                                            bodyweightKg: bodyweightKg, calendar: calendar)
        return ReportDietSection(daysTracked: summary.daysTracked,
                                 avgKcal: summary.daysTracked > 0 ? summary.avg.kcal : nil,
                                 avgProteinG: summary.daysTracked > 0 ? summary.avg.proteinG : nil,
                                 proteinTargetLowG: Double(summary.targets.proteinLo),
                                 proteinTargetHighG: Double(summary.targets.proteinHi),
                                 proteinHitDays: summary.proteinHitDays,
                                 trainedHitDays: summary.trainingLink.trackedTrainedDays > 0
                                    ? summary.trainingLink.proteinHitOnTrainedDays : nil,
                                 trainedTrackedDays: summary.trainingLink.trackedTrainedDays > 0
                                    ? summary.trainingLink.trackedTrainedDays : nil,
                                 topFoods: summary.topFoods.map(\.name),
                                 advice: summary.advice)
    }

    /// 预算域汇总：合并开销流（manual + diet auto 派生）的区间统计。
    /// 自定义周期计划（planOverlaps）后置（§9-6），第一版不含。
    ///
    /// ⚠ 取数通道说明（与 §2.1 冻结清单的偏差，显式记录）：冻结签名
    /// `BudgetEngine.status` 携带合并开销流汇总（SpendSummary），但其实现以
    /// `budgetYuan > 0` 为前置（无预算 → nil）——而阶段报告的预算域是**纯开销
    /// 聚合**（lifttime reportBuilder.js:106-135，测试 fixture 未设预算也有
    /// 总账 310 含计外 250）。故此处走同引擎公开的只读聚合原语
    /// （mergedExpenses/inRange/summarize/outOfPlan，BudgetEngine.swift:105-186），
    /// 方向仍是 report → budget、只读、无逻辑重复；status 的预算态
    /// （额度/预测/拉回）归 BudgetView 经 AppModel 取用。若后续 status 改为
    /// 无预算也返回汇总口径，此处应收敛回 status 单通道（修复工程师裁决项）。
    static func budgetSection(expenses: [Expense], dietEntries: [DietEntry], range: ReportRange,
                              calendar: DayCalendar, now: Date) -> ReportBudgetSection {
        let items = BudgetEngine.inRange(BudgetEngine.mergedExpenses(expenses, dietEntries: dietEntries),
                                         in: range.span, calendar: calendar)
        let summary = BudgetEngine.summarize(items, calendar: calendar)
        let out = BudgetEngine.outOfPlan(items)
        // 大头分类：金额降序；同额取 EXP_CATS 展示序（lifttime 稳定排序取首现者）
        let topEntry = summary.byCat.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value
                : (ExpenseCategory.allCases.firstIndex(of: lhs.key) ?? 0)
                    > (ExpenseCategory.allCases.firstIndex(of: rhs.key) ?? 0)
        }
        let top = topEntry.map {
            ReportBudgetSlice(label: BudgetEngine.categoryLabel($0.key), amountYuan: $0.value)
        }
        return ReportBudgetSection(totalYuan: summary.totalYuan,
                                   count: summary.count,
                                   activeDays: summary.daysWithSpend,
                                   dayCount: range.dayCount,
                                   dailyAvgYuan: summary.avgPerActiveDayYuan,
                                   topCategory: top,
                                   outOfPlanYuan: out.totalYuan,
                                   outOfPlanCount: out.count)
    }

    // MARK: 规则版报告（渲染契约，lifttime renderRuleReport :141-236）

    /// 规则版报告：数字 + 结论，按板块分组；与未来 AI 输出同一结构（§9-7）。
    public static func renderRuleReport(_ data: ReportData) -> RuleReport {
        var out = RuleReport()

        // 一处记录都没有 → 只给引导文案
        let trackedAny = data.time.totalMinutes > 0 || data.sleep.nights > 0
            || data.workout.sessions > 0 || data.diet.daysTracked > 0 || data.budget.count > 0
        guard trackedAny else {
            out.overall.append("这段时间还没有任何记录——先从「时间」页点一下开始，或去训练/饮食/预算各记一条，报告就会有内容。")
            return out
        }

        // 总评：挑最响的信号说（reportBuilder.js:149-162）
        var signals: [String] = []
        if data.workout.sessions > 0 {
            var s = "训练 \(data.workout.sessions) 次"
            if data.workout.volumeKg > 0 { s += "、总容量 \(Int(data.workout.volumeKg.rounded()))kg" }
            signals.append(s)
        }
        if data.sleep.nights > 0, let avg = data.sleep.avgNightMinutes {
            signals.append("睡眠平均 \(Text.compactMinutes(avg))/晚")
        }
        if data.time.totalMinutes > 0 {
            signals.append("记录投入时间 \(Text.duration(data.time.totalMinutes))")
        }
        if data.diet.daysTracked > 0 { signals.append("饮食记录 \(data.diet.daysTracked) 天") }
        if data.budget.count > 0 { signals.append("开销 \(Text.yuan(data.budget.totalYuan))") }
        out.overall.append("这份\(data.range.label)（\(data.range.dayCount) 天）的报告里：\(signals.joined(separator: "，"))。")
        if data.sleep.nights > 0, let avg = data.sleep.avgNightMinutes {
            if Double(avg) < Double(data.sleep.goalMinutes) * 0.85 {
                out.overall.append("睡眠是当前最明显的短板：比目标平均每晚少 \(data.sleep.goalMinutes - avg) 分钟，恢复跟不上，训练成果也会打折。")
            } else if data.workout.sessions == 0 {
                out.overall.append("睡得还行，但这段时间一次训练都没有——恢复攒着也是浪费，安排一次轻量课启动起来。")
            }
        }

        // 时间（reportBuilder.js:165-172）
        if data.time.totalMinutes > 0 {
            out.time.append("共记录投入 \(Text.duration(data.time.totalMinutes))，覆盖 \(data.time.activeDays)/\(data.time.dayCount) 天。")
            if !data.time.top.isEmpty {
                let slices = data.time.top.map { "\($0.label) \(Text.duration($0.minutes))" }
                    .joined(separator: "、")
                out.time.append("去向 top：\(slices)。")
            }
        } else {
            out.time.append("这段时间没有计时记录。")
        }

        // 睡眠（reportBuilder.js:175-184；日简报才隐去分数，阶段报告给区间均分）
        if data.sleep.nights > 0 {
            let goalH = Text.goalHours(data.sleep.goalMinutes)
            if let avg = data.sleep.avgNightMinutes {
                out.sleep.append("记录 \(data.sleep.nights) 晚，平均 \(Text.compactMinutes(avg))/晚（目标 \(goalH)），平均睡眠分 \(data.sleep.avgScore.map(String.init) ?? "–")。")
            }
            if let mad = data.sleep.madMinutes {
                out.sleep.append("就寝规律性：平均偏差 \(mad) 分钟\(mad <= 45 ? "（良好）" : "（超过 45 分钟，作息偏飘）")。")
            }
            if data.sleep.debtMinutes >= 60 {
                out.sleep.append("相对目标累计睡眠债 \(Text.duration(Double(data.sleep.debtMinutes)))。")
            }
            if data.sleep.napMinutes > 0 {
                out.sleep.append("另有午睡合计 \(Text.compactMinutes(data.sleep.napMinutes))。")
            }
        } else {
            out.sleep.append("这段时间没有睡眠记录——睡前在「时间」页点一下就能记。")
        }

        // 训练（reportBuilder.js:187-198）
        if data.workout.sessions > 0 {
            var line = "\(data.workout.sessions) 次训练（\(Text.oneDecimal(data.workout.freqPerWeek)) 次/周）"
            if data.workout.volumeKg > 0 { line += "，总容量 \(Int(data.workout.volumeKg.rounded()))kg" }
            if let trend = data.workout.trendPercent {
                line += "，容量环比 \(trend >= 0 ? "+" : "")\(trend)%"
            }
            if data.workout.prCount > 0 { line += "，\(data.workout.prCount) 个个人纪录" }
            out.workout.append(line + "。")
            if !data.workout.groupLabels.isEmpty {
                out.workout.append("部位分布：\(data.workout.groupLabels.prefix(3).joined(separator: "、"))。")
            }
            if let first = data.workout.balanceNotes.first { out.workout.append(first) }
        } else {
            out.workout.append("这段时间没有训练记录。")
        }

        // 饮食（reportBuilder.js:201-211）
        if data.diet.daysTracked > 0 {
            let kcal = data.diet.avgKcal.map { Int($0.rounded()).description } ?? "–"
            let protein = data.diet.avgProteinG.map { Int($0.rounded()).description } ?? "–"
            out.diet.append("记录 \(data.diet.daysTracked) 天，日均 \(kcal) kcal、蛋白质 \(protein)g（目标 \(Text.gramsRange(data.diet.proteinTargetLowG, data.diet.proteinTargetHighG))）。")
            var hit = "蛋白质达标 \(data.diet.proteinHitDays)/\(data.diet.daysTracked) 天"
            if let trainedHit = data.diet.trainedHitDays, let tracked = data.diet.trainedTrackedDays {
                hit += "；训练日达标 \(trainedHit)/\(tracked) 天"
            }
            out.diet.append(hit + "。")
            if !data.diet.topFoods.isEmpty {
                out.diet.append("最常吃：\(data.diet.topFoods.prefix(3).joined(separator: "、"))。")
            }
        } else {
            out.diet.append("这段时间没有饮食记录。")
        }

        // 预算（reportBuilder.js:214-226；planOverlaps 随自定义周期计划后置）
        if data.budget.count > 0 {
            var line = "共 \(data.budget.count) 笔、合计 \(Text.yuan(data.budget.totalYuan))，活跃 \(data.budget.activeDays) 天、日均 \(Text.yuan(data.budget.dailyAvgYuan))"
            if let top = data.budget.topCategory {
                line += "，大头是\(top.label)（\(Text.yuan(top.amountYuan))）"
            }
            out.budget.append(line + "。")
            if data.budget.outOfPlanYuan > 0 {
                out.budget.append("另有计划外开销 \(Text.yuan(data.budget.outOfPlanYuan))（不占周期计划额度）。")
            }
        } else {
            out.budget.append("这段时间没有开销记录。")
        }

        // 建议：各域最好的提醒取一口（reportBuilder.js:229-234）
        if data.sleep.nights > 0, data.sleep.debtMinutes >= 120 {
            let per = Int((Double(data.sleep.debtMinutes) / Double(max(1, data.sleep.nights))).rounded())
            out.advice.append("先把睡眠债还上：接下来几天把就寝提前 \(min(45, per)) 分钟，比任何补剂都管用。")
        }
        if data.sleep.nights > 0, let mad = data.sleep.madMinutes, mad > 45 {
            out.advice.append("就寝时间波动太大，试着固定一个锚点（比如 23:30 前上床），规律性比单晚时长更影响白天的状态。")
        }
        out.advice.append(contentsOf: data.workout.advice.prefix(2))
        out.advice.append(contentsOf: data.diet.advice.prefix(2))
        if out.advice.isEmpty {
            out.advice.append("各板块节奏都在正轨上，按现在的节奏继续保持。")
        }
        out.advice = Array(out.advice.prefix(5))
        return out
    }
}

// MARK: - 报告文案格式化（lifttime util.js fmtDur/fmtMin + finance.js fmtMoney 的报告侧取用）

/// 报告板块文案的数值格式化（报告契约的一部分——文案锚点以此为准）。
enum Text {
    /// 分钟 → 中文人读时长（Formatting.duration：`130` → "2 小时 10 分"；
    /// lifttime fmtDur 无空格「2小时10分」，Swift 侧统一项目空格风格）。
    static func duration(_ minutes: Double) -> String {
        Formatting.duration(minutes: minutes)
    }

    /// 分钟 → 紧凑时长 `435` → "7h15m"（lifttime util.js fmtMin，图表/统计口吻）。
    static func compactMinutes(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h\(m % 60 > 0 ? "\(m % 60)m" : "")"
    }

    /// 睡眠目标分钟 → 小时标签 `480` → "8h"、`450` → "7.5h"
    /// （lifttime `Math.round(goalMin / 30) / 2 + 'h'`）。
    static func goalHours(_ minutes: Int) -> String {
        let halves = Int((Double(minutes) / 30).rounded()) // 半小时刻度
        return halves % 2 == 0 ? "\(halves / 2)h" : "\(halves / 2).5h"
    }

    /// 金额（元）→ `¥310`（Formatting.yuan）。
    static func yuan(_ value: Double) -> String {
        Formatting.yuan(value)
    }

    /// 1 位小数（频率 `1.0` 次/周，lifttime toFixed(1)）。
    static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// 蛋白目标区间 `112–154g`（lifttime `proteinLo + '–' + proteinHi + 'g'`）。
    static func gramsRange(_ low: Double, _ high: Double) -> String {
        "\(Int(low.rounded()))–\(Int(high.rounded()))g"
    }
}
