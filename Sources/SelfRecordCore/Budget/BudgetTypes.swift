import Foundation

// MARK: - budget 模块值类型（design.md §3.5）
//
// 口径锚点（lifttime finance.js，均已核对源码）：
// - EXP_CATS 七档 :5-13；PROTEIN_PRICE_REF :18-23
// - allExpenses 合并开销流 :43-58；planSpend / outOfPlanSum 双口径 :60-70
// - summarizeSpend :77-92；proteinEconomy :95-108
// - budgetStatus 节奏预测 :148-165；budgetAdvice :174-218（诊断 :192-218）
// 自定义周期计划（CustomBudgetPlan / CustomPlanStatus / planRange / planStatus /
// planAdvice / 再来一期）已实装于 BudgetPlans.swift（§9-6 解除后置）；
// 计划外双口径第一版挂在周/月周期上（§3.5），自定义周期同口径。

/// 统一开销流里的单笔开销：手动 `Expense`，或记餐 `DietEntry.costYuan > 0`
/// 派生的 auto 项（finance.js:43-58 allExpenses——无花费不计入，
/// 派生项分类恒 `.meals`，note = 餐次 + 原文）。
public struct MergedExpense: Codable, Sendable, Identifiable, Equatable {
    /// 手动 = Expense 的 UUID 串；auto = "meal-" + DietEntry 的 UUID 串
    /// （lifttime `'meal-' + m.id`，finance.js:51）。
    public var id: String
    public var date: Date
    public var amountYuan: Double
    /// 已解析分类：手动条目 category 为 nil 时归 `.other`（catOfExp 兜底语义，
    /// finance.js:14——找不到归最后一档）；auto 条目恒 `.meals`。
    public var category: ExpenseCategory
    public var note: String
    /// 记餐派生项（UI「自动」徽标用；手动条目 false）。
    public var isAuto: Bool
    /// 计划外开销：计总账与统计、不占周期额度（finance.js:41-42 注释 / :60-70）。
    public var isOutOfPlan: Bool
    /// auto 项指向源头 `DietEntry`（UI 点按引导去 DietView 编辑源头用）。
    public var mealEntryID: UUID?

    public init(id: String, date: Date, amountYuan: Double, category: ExpenseCategory,
                note: String = "", isAuto: Bool = false, isOutOfPlan: Bool = false,
                mealEntryID: UUID? = nil) {
        self.id = id
        self.date = date
        self.amountYuan = amountYuan
        self.category = category
        self.note = note
        self.isAuto = isAuto
        self.isOutOfPlan = isOutOfPlan
        self.mealEntryID = mealEntryID
    }
}

/// 开销汇总（finance.js:77-92 summarizeSpend）：总额、按分类、笔数、
/// 最大单笔、有开销天数、活跃日均。**统计口径含计划外条目**（§3.5——
/// 计外条目照常进总账与统计，只是不占周期额度）。
public struct SpendSummary: Codable, Sendable, Equatable {
    public var totalYuan: Double                 // round2
    public var count: Int
    public var byCat: [ExpenseCategory: Double]  // 各档 round2（消除累加浮点噪差）
    public var maxExpense: MergedExpense?        // 最大单笔（同额取先出现者，:86）
    public var daysWithSpend: Int                // 有开销的日键数（:89）
    public var avgPerActiveDayYuan: Double       // 活跃日均（:90）

    public init(totalYuan: Double = 0, count: Int = 0, byCat: [ExpenseCategory: Double] = [:],
                maxExpense: MergedExpense? = nil, daysWithSpend: Int = 0,
                avgPerActiveDayYuan: Double = 0) {
        self.totalYuan = totalYuan
        self.count = count
        self.byCat = byCat
        self.maxExpense = maxExpense
        self.daysWithSpend = daysWithSpend
        self.avgPerActiveDayYuan = avgPerActiveDayYuan
    }
}

/// 计划外开销合计（finance.js:65-70 outOfPlanSum——「另有计划外 ¥X」展示）。
public struct OutOfPlanSummary: Codable, Sendable, Equatable {
    public var totalYuan: Double                // round2
    public var count: Int

    public init(totalYuan: Double = 0, count: Int = 0) {
        self.totalYuan = totalYuan
        self.count = count
    }
}

/// 周或月预算状态（design.md §2.1 冻结签名 `status` 的返回类型；
/// finance.js:148-165 budgetStatus + §3.5 双口径扩展）。
///
/// **双口径**：`spentYuan / pct / remainingYuan / perDayLeftYuan / projectedYuan`
/// 走**周期额度口径**（只算计划内条目，planSpend，finance.js:61-63）；
/// `totalYuan / outOfPlanYuan / outOfPlanCount / summary` 走**总账/统计口径**
/// （计划外条目照常计入，§3.5）。
public struct BudgetStatus: Codable, Sendable, Equatable {
    /// 周期内计划内花费（round2）。
    public var spentYuan: Double
    public var budgetYuan: Double
    /// 已用百分比（取整 round，finance.js:157）。
    public var pct: Int
    /// 剩余额度（round2，可为负——负数即已超支）。
    public var remainingYuan: Double
    /// 剩余天数（≥1；finance.js:153 的 ceil 口径）。
    public var daysLeft: Int
    /// 剩余天数日均可用（round2）——「剩 N 天每天控制在 ¥X 内可拉回」的数值源。
    public var perDayLeftYuan: Double
    /// 节奏预测：`spent / (elapsed/total)` 线性外推（finance.js:152，round2）。
    public var projectedYuan: Double
    /// **未舍入** projected 是否超预算（finance.js:163）。
    public var overProjected: Bool

    // MARK: 总账口径（含计划外）

    public var totalYuan: Double
    public var outOfPlanYuan: Double
    public var outOfPlanCount: Int
    /// 窗口内合并开销流汇总（统计口径，byCat 含计外条目）。
    public var summary: SpendSummary

    public init(spentYuan: Double, budgetYuan: Double, pct: Int, remainingYuan: Double,
                daysLeft: Int, perDayLeftYuan: Double, projectedYuan: Double, overProjected: Bool,
                totalYuan: Double, outOfPlanYuan: Double, outOfPlanCount: Int,
                summary: SpendSummary) {
        self.spentYuan = spentYuan
        self.budgetYuan = budgetYuan
        self.pct = pct
        self.remainingYuan = remainingYuan
        self.daysLeft = daysLeft
        self.perDayLeftYuan = perDayLeftYuan
        self.projectedYuan = projectedYuan
        self.overProjected = overProjected
        self.totalYuan = totalYuan
        self.outOfPlanYuan = outOfPlanYuan
        self.outOfPlanCount = outOfPlanCount
        self.summary = summary
    }
}

/// 记餐蛋白质性价比（design.md §2.1 冻结签名 `proteinEconomy` 的返回类型；
/// finance.js:95-108——仅统计带花费的饮食记录，蛋白取 `totals.proteinG`）。
public struct ProteinEconomy: Codable, Sendable, Equatable {
    public var costYuan: Double     // round2
    public var proteinG: Double     // round1
    public var meals: Int           // 带花费记餐笔数（建议触发阈值 ≥3，finance.js:202）
    /// ¥/10g 蛋白质（round2）；蛋白为 0 时 nil（finance.js:106 的 null）。
    public var per10gYuan: Double?

    public init(costYuan: Double, proteinG: Double, meals: Int, per10gYuan: Double?) {
        self.costYuan = costYuan
        self.proteinG = proteinG
        self.meals = meals
        self.per10gYuan = per10gYuan
    }
}

/// 常见蛋白来源参考成本条目（finance.js:18-23 PROTEIN_PRICE_REF，估算值）。
public struct ProteinPriceRef: Codable, Sendable, Equatable {
    public var name: String
    public var per10gYuan: Double

    public init(name: String, per10gYuan: Double) {
        self.name = name
        self.per10gYuan = per10gYuan
    }
}
