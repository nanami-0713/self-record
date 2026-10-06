import Foundation

// MARK: - 五域聚合产物（design.md §3.6）
//
// ReportData = 五域只读聚合 API（§2.1 冻结物 B）产物的聚合快照：
// report 调 TimeEngine / SleepEngine / WorkoutEngine / DietEngine / BudgetEngine
// 取数（方向永远 report → 各域），把各域产物拍平成本结构——
// **报告 JSON 结构 = 未来 AI 输出契约 = 渲染契约**（design.md §9-7）：
// 规则版 `RuleReport` 与未来 AI 报告共用同一结构，一份渲染两用。
//
// lifttime 对应：js/reportBuilder.js:49-138 buildReportData 的
// { range, time, sleep, workout, diet, budget }。

/// 报告区间元信息（lifttime d.range：label / days / start / end）。
public struct ReportRangeInfo: Codable, Sendable, Equatable, Hashable {
    /// 展示名（「过去一周」/「9/1 – 9/7」…）
    public var label: String
    /// 区间天数（含首尾）
    public var dayCount: Int
    /// 区间（含首尾）
    public var span: DateSpan

    public init(label: String, dayCount: Int, span: DateSpan) {
        self.label = label
        self.dayCount = dayCount
        self.span = span
    }
}

// MARK: - 时间域

/// 时间域份额条目（lifttime time.top 元素 `{ label, ms }` → 分钟制）。
public struct ReportTimeSlice: Codable, Sendable, Equatable, Identifiable {
    public var id: String { label }
    /// 分类展示名
    public var label: String
    /// 该分类区间内合计分钟
    public var minutes: Double

    public init(label: String, minutes: Double) {
        self.label = label
        self.minutes = minutes
    }
}

/// 时间域（清醒投入）汇总（lifttime reportBuilder.js:56-71）。
/// 数据源 = `TimeEngine.dailyBreakdown`（归属 = start 所在日，report 只做汇总）。
public struct ReportTimeSection: Codable, Sendable, Equatable {
    /// 区间内时间块总分钟
    public var totalMinutes: Double
    /// 有记录的天数
    public var activeDays: Int
    /// 区间天数
    public var dayCount: Int
    /// 分类去向降序表（前 4）
    public var top: [ReportTimeSlice]

    public init(totalMinutes: Double = 0, activeDays: Int = 0, dayCount: Int = 0,
                top: [ReportTimeSlice] = []) {
        self.totalMinutes = totalMinutes
        self.activeDays = activeDays
        self.dayCount = dayCount
        self.top = top
    }
}

// MARK: - 睡眠域

/// 睡眠域汇总（lifttime reportBuilder.js:73-96）。
/// 数据源 = `SleepEngine.periodSummary`（区间中位锚口径，缺夜不进均值不记债）。
/// ⚠ 不含任何单夜分数字段——分数永远归区间层（A3，report.js:172-176 同）。
public struct ReportSleepSection: Codable, Sendable, Equatable {
    /// 已记录晚数（缺记夜不计）
    public var nights: Int
    /// 区间天数
    public var dayCount: Int
    /// 平均每晚分钟，nil = 无记录
    public var avgNightMinutes: Int?
    /// 区间平均睡眠分（中位锚），nil = 无记录
    public var avgScore: Int?
    /// 就寝规律 MAD（分钟），nil = 无记录
    public var madMinutes: Int?
    /// 睡眠债（分钟）= 各已记录晚 max(0, 目标 − 实际) 之和
    public var debtMinutes: Int
    /// 午睡合计分钟
    public var napMinutes: Int
    /// 睡眠目标（分钟）
    public var goalMinutes: Int

    public init(nights: Int = 0, dayCount: Int = 0, avgNightMinutes: Int? = nil,
                avgScore: Int? = nil, madMinutes: Int? = nil, debtMinutes: Int = 0,
                napMinutes: Int = 0, goalMinutes: Int = 480) {
        self.nights = nights
        self.dayCount = dayCount
        self.avgNightMinutes = avgNightMinutes
        self.avgScore = avgScore
        self.madMinutes = madMinutes
        self.debtMinutes = debtMinutes
        self.napMinutes = napMinutes
        self.goalMinutes = goalMinutes
    }
}

// MARK: - 训练域

/// 训练域汇总（lifttime reportBuilder.js:98-99，数据源 = WorkoutEngine.analyzePeriod）。
public struct ReportWorkoutSection: Codable, Sendable, Equatable {
    /// 训练次数
    public var sessions: Int
    /// 频率（次/周，1 位小数）
    public var freqPerWeek: Double
    /// 总容量 kg（自重动作贡献 0）
    public var volumeKg: Double
    /// 容量环比百分比，nil = 上一等长窗口无数据
    public var trendPercent: Int?
    /// 窗口内个人纪录数
    public var prCount: Int
    /// 部位分布标签（降序）
    public var groupLabels: [String]
    /// 平衡提醒（推多拉少等）
    public var balanceNotes: [String]
    /// 阶段建议（report 摘前 2 条进 advice 板块）
    public var advice: [String]

    public init(sessions: Int = 0, freqPerWeek: Double = 0, volumeKg: Double = 0,
                trendPercent: Int? = nil, prCount: Int = 0, groupLabels: [String] = [],
                balanceNotes: [String] = [], advice: [String] = []) {
        self.sessions = sessions
        self.freqPerWeek = freqPerWeek
        self.volumeKg = volumeKg
        self.trendPercent = trendPercent
        self.prCount = prCount
        self.groupLabels = groupLabels
        self.balanceNotes = balanceNotes
        self.advice = advice
    }
}

// MARK: - 饮食域

/// 饮食域汇总（lifttime reportBuilder.js:101-104，数据源 = DietEngine.periodDiet）。
/// 双达标率口径并存（B1）：proteinHitDays/daysTracked（全记录日）与
/// trainedHitDays/trainedTrackedDays（训练日）都进契约，调用方按用途取。
public struct ReportDietSection: Codable, Sendable, Equatable {
    /// 有饮食记录的天数
    public var daysTracked: Int
    /// 日均 kcal，nil = 无记录
    public var avgKcal: Double?
    /// 日均蛋白质 g，nil = 无记录
    public var avgProteinG: Double?
    /// 蛋白目标下限 g
    public var proteinTargetLowG: Double
    /// 蛋白目标上限 g
    public var proteinTargetHighG: Double
    /// 蛋白达标天数（全记录日口径）
    public var proteinHitDays: Int
    /// 训练日达标天数，nil = 无训练日记录
    public var trainedHitDays: Int?
    /// 训练日有记录天数
    public var trainedTrackedDays: Int?
    /// 最常吃 Top 食物名（降序）
    public var topFoods: [String]
    /// 阶段建议（report 摘前 2 条进 advice 板块）
    public var advice: [String]

    public init(daysTracked: Int = 0, avgKcal: Double? = nil, avgProteinG: Double? = nil,
                proteinTargetLowG: Double = 0, proteinTargetHighG: Double = 0,
                proteinHitDays: Int = 0, trainedHitDays: Int? = nil,
                trainedTrackedDays: Int? = nil, topFoods: [String] = [],
                advice: [String] = []) {
        self.daysTracked = daysTracked
        self.avgKcal = avgKcal
        self.avgProteinG = avgProteinG
        self.proteinTargetLowG = proteinTargetLowG
        self.proteinTargetHighG = proteinTargetHighG
        self.proteinHitDays = proteinHitDays
        self.trainedHitDays = trainedHitDays
        self.trainedTrackedDays = trainedTrackedDays
        self.topFoods = topFoods
        self.advice = advice
    }
}

// MARK: - 预算域

/// 开销大头分类（lifttime budget.topCat `{ label, amount }`）。
public struct ReportBudgetSlice: Codable, Sendable, Equatable, Identifiable {
    public var id: String { label }
    /// 分类展示名（「记餐开销」「食材采购」…）
    public var label: String
    /// 合计金额（元）
    public var amountYuan: Double

    public init(label: String, amountYuan: Double) {
        self.label = label
        self.amountYuan = amountYuan
    }
}

/// 预算域汇总（lifttime reportBuilder.js:106-135）。
/// 数据源 = `BudgetEngine.status`（manual + diet auto 派生的合并开销流）。
/// 自定义周期计划（planOverlaps）后置（design.md §9-6），第一版不含。
public struct ReportBudgetSection: Codable, Sendable, Equatable {
    /// 总开销（元，含计划外——计外照常计入总账）
    public var totalYuan: Double
    /// 笔数
    public var count: Int
    /// 有开销的天数
    public var activeDays: Int
    /// 区间天数
    public var dayCount: Int
    /// 活跃日均（元；无开销 0）
    public var dailyAvgYuan: Double
    /// 开销大头分类，nil = 无开销
    public var topCategory: ReportBudgetSlice?
    /// 计划外开销合计（元；不占周期计划额度）
    public var outOfPlanYuan: Double
    /// 计划外开销笔数
    public var outOfPlanCount: Int

    public init(totalYuan: Double = 0, count: Int = 0, activeDays: Int = 0,
                dayCount: Int = 0, dailyAvgYuan: Double = 0,
                topCategory: ReportBudgetSlice? = nil,
                outOfPlanYuan: Double = 0, outOfPlanCount: Int = 0) {
        self.totalYuan = totalYuan
        self.count = count
        self.activeDays = activeDays
        self.dayCount = dayCount
        self.dailyAvgYuan = dailyAvgYuan
        self.topCategory = topCategory
        self.outOfPlanYuan = outOfPlanYuan
        self.outOfPlanCount = outOfPlanCount
    }
}

// MARK: - 五域聚合

/// 五域聚合产物：规则版结构 = 未来 AI 输出契约 = 渲染契约（§3.6/§9-7）。
public struct ReportData: Codable, Sendable, Equatable {
    public var range: ReportRangeInfo
    public var time: ReportTimeSection
    public var sleep: ReportSleepSection
    public var workout: ReportWorkoutSection
    public var diet: ReportDietSection
    public var budget: ReportBudgetSection

    /// 空数据的区间占位（1970-01-01 单日；字面量恒合法）。
    public static let placeholderRange = ReportRangeInfo(
        label: "", dayCount: 0,
        span: DateSpan(startDay: DayKey(rawValue: "1970-01-01")!,
                       endDay: DayKey(rawValue: "1970-01-01")!))

    public init(range: ReportRangeInfo = ReportData.placeholderRange,
                time: ReportTimeSection = ReportTimeSection(),
                sleep: ReportSleepSection = ReportSleepSection(),
                workout: ReportWorkoutSection = ReportWorkoutSection(),
                diet: ReportDietSection = ReportDietSection(),
                budget: ReportBudgetSection = ReportBudgetSection()) {
        self.range = range
        self.time = time
        self.sleep = sleep
        self.workout = workout
        self.diet = diet
        self.budget = budget
    }
}

// MARK: - 规则版报告（渲染契约）

/// 规则版报告：数字 + 结论，按板块分组（lifttime renderRuleReport 的 out 结构）。
/// 七个板块均为字符串数组——与未来 AI 输出结构相同，可直接互换渲染（§9-7）。
public struct RuleReport: Codable, Sendable, Equatable {
    /// 总评（2-3 段）
    public var overall: [String]
    /// 时间投入点评
    public var time: [String]
    /// 睡眠点评（时长/规律性/睡眠债）
    public var sleep: [String]
    /// 训练点评（频率/容量/部位结构）
    public var workout: [String]
    /// 饮食点评（热量与蛋白质按数字说话）
    public var diet: [String]
    /// 开销点评
    public var budget: [String]
    /// 下阶段建议（≤5 条，按优先级）
    public var advice: [String]

    public init(overall: [String] = [], time: [String] = [], sleep: [String] = [],
                workout: [String] = [], diet: [String] = [], budget: [String] = [],
                advice: [String] = []) {
        self.overall = overall
        self.time = time
        self.sleep = sleep
        self.workout = workout
        self.diet = diet
        self.budget = budget
        self.advice = advice
    }
}
