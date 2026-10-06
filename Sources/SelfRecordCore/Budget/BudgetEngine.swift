import Foundation

// MARK: - budget 模块（design.md §3.5）
//
// 模块边界：只依赖基础层（Model/ Storage/ TimeKit/），禁止横向调用。
// 跨域数据走「共享模型」通道：直接读 Model/ 里的 DietEntry（costYuan 字段派生
// auto 开销），**不调 diet 引擎**（§2 依赖规则）。
//
// lifttime 对应：js/finance.js（:43-58 allExpenses、:148-165 预测、
// :174-218 蛋白性价比与建议）。自定义周期计划（planRange/planStatus/
// planDays/planAdvice/再来一期）已实装：BudgetPlans.swift（§9-6 解除后置）。
//
// 口径锁定：
// - 开销分类 7 档 = lifttime finance.js:5-13 EXP_CATS（.meals 仅 auto 派生专用，
//   手动记账 UI 不提供该档——manualCategories）；
// - 自然周（周一起）/自然月；节奏预测 projected = spent / (elapsed/total)；
// - 计划外开销双口径：isOutOfPlan 标记账照常计入总账与统计，但不占周期额度；
// - 参考成本表：鸡胸 ¥0.8/10g、鸡蛋 ¥1.6、蛋白粉 ¥2.2、牛肉 ¥2.5；
// - 诊断：外卖聚餐占比 = (takeout+social)/(meals+groceries+takeout+social) > 50%
//   且 proteinHitRate < 60% →「钱花出去了营养没跟上」（finance.js:196-198）；
//   supplement/total > 30% →「补剂是锦上添花」（:212-214）。
//
// ⚠ 跨域注入契约（§2，参数注入通道）：budgetAdvice 的 `proteinHitRate: Double?`
//   由 DietEngine.periodDiet 产物经 UI / report 注入——值 =
//   `proteinHitDays / daysTracked`（**全记录日**达标率，B1；lifttime
//   budget.js:423-424 动态计算，finance.test.mjs:79 的 0.4 是测试 fixture），
//   **不是**训练日达标率。本模块不自己算这个值。

/// 预算引擎（§3.5）。`status` / `proteinEconomy` 签名 = 骨架冻结物 B（§2.1），
/// **不得偏离**；其余函数与值类型为 budget 模块公开 API（UI / report 取数入口）。
public enum BudgetEngine {

    // MARK: - 口径常量与标签

    /// 常见蛋白来源参考成本（finance.js:18-23；建议文案与「吃的值不值」卡共用）。
    public static let proteinPriceRef: [ProteinPriceRef] = [
        ProteinPriceRef(name: "鸡胸肉", per10gYuan: 0.8),
        ProteinPriceRef(name: "鸡蛋", per10gYuan: 1.6),
        ProteinPriceRef(name: "蛋白粉", per10gYuan: 2.2),
        ProteinPriceRef(name: "牛肉", per10gYuan: 2.5),
    ]

    /// 手动记账可选分类（finance.js:15 MANUAL_CATS）：`.meals` 仅由记餐派生，
    /// 手动记账 UI 不提供该档（§3.5）。
    public static let manualCategories: [ExpenseCategory] =
        ExpenseCategory.allCases.filter { $0 != .meals }

    /// 开销分类显示名（finance.js:5-13 EXP_CATS 的 label）。用引擎静态函数而非
    /// extension，避免与基础层/其他模块将来对 ExpenseCategory 的扩展撞成员。
    public static func categoryLabel(_ category: ExpenseCategory) -> String {
        switch category {
        case .meals: return "记餐开销"
        case .groceries: return "食材采购"
        case .takeout: return "外卖外食"
        case .social: return "聚餐"
        case .supplement: return "补剂"
        case .fitness: return "健身相关"
        case .other: return "其他"
        }
    }

    /// 餐次显示名（nutrition.js:5-12 MEALS 的 label；auto 开销 note 用）。
    /// 同上理由用静态函数，不扩展 MealSlot（diet 模块的类型）。
    public static func mealLabel(_ meal: MealSlot) -> String {
        switch meal {
        case .breakfast: return "早餐"
        case .lunch: return "午餐"
        case .dinner: return "晚餐"
        case .snack: return "加餐"
        case .preworkout: return "练前餐"
        case .postworkout: return "练后餐"
        }
    }

    // MARK: - 自然周 / 自然月（finance.js:25-39）

    /// 自然周（周一起）：date 所在周的周一…周日（含首尾日键）。
    /// Monday 偏移用 `Calendar.date(byAdding:)` 而非时间戳减法——跨 DST 时区安全。
    public static func weekSpan(containing date: Date, calendar: DayCalendar) -> DateSpan {
        let cal = calendar.calendar
        let today = cal.startOfDay(for: date)
        // weekday 1=周日…7=周六 → 距周一的天数（周一=0…周日=6），等价 lifttime
        // `(d.getDay() + 6) % 7`（finance.js:28）
        let daysSinceMonday = (cal.component(.weekday, from: date) + 5) % 7
        let monday = cal.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
        let sunday = cal.date(byAdding: .day, value: 6, to: monday) ?? monday
        return DateSpan(startDay: calendar.dayKey(for: monday),
                        endDay: calendar.dayKey(for: sunday))
    }

    /// 自然月：date 所在月 1 日…月末（含首尾日键）。
    public static func monthSpan(containing date: Date, calendar: DayCalendar) -> DateSpan {
        let cal = calendar.calendar
        let first = cal.date(from: cal.dateComponents([.year, .month], from: date))
            ?? cal.startOfDay(for: date)
        let nextMonth = cal.date(byAdding: .month, value: 1, to: first) ?? first
        let last = cal.date(byAdding: .day, value: -1, to: nextMonth) ?? first
        return DateSpan(startDay: calendar.dayKey(for: first),
                        endDay: calendar.dayKey(for: last))
    }

    // MARK: - 合并开销流（finance.js:43-92）

    /// 合并手动开销与记餐花费：`costYuan > 0` 的 DietEntry 派生 auto 项
    /// （无花费不计入、分类恒 `.meals`、note = 餐次：原文），新→旧排序。
    public static func mergedExpenses(_ expenses: [Expense], dietEntries: [DietEntry]) -> [MergedExpense] {
        var out: [MergedExpense] = []
        out.reserveCapacity(expenses.count + dietEntries.count)
        for e in expenses {
            out.append(MergedExpense(id: e.id.uuidString,
                                     date: e.date,
                                     amountYuan: e.amountYuan,
                                     category: e.category ?? .other,   // catOfExp 兜底（:14）
                                     note: e.note ?? "",
                                     isAuto: false,
                                     isOutOfPlan: e.isOutOfPlan,
                                     mealEntryID: nil))
        }
        for m in dietEntries {
            guard let cost = m.costYuan, cost > 0 else { continue }    // :49 无花费不计入
            let label = mealLabel(m.meal)
            let note = m.rawText.isEmpty ? label : label + "：" + m.rawText
            out.append(MergedExpense(id: "meal-" + m.id.uuidString,
                                     date: m.date,
                                     amountYuan: cost,
                                     category: .meals,                // 派生项分类恒 .meals
                                     note: note,
                                     isAuto: true,
                                     isOutOfPlan: false,
                                     mealEntryID: m.id))
        }
        return out.sorted { $0.date > $1.date }                        // :57 新→旧
    }

    /// 窗口过滤（finance.js:72-74 inRange 的日键等价形态：含首尾日的 DateSpan，
    /// 按注入时区的 startOfDay 归日，等价于 [起 00:00, 止次日 00:00) 时间戳区间）。
    public static func inRange(_ items: [MergedExpense], in span: DateSpan,
                               calendar: DayCalendar) -> [MergedExpense] {
        guard span.isValid else { return [] }
        return items.filter { span.contains(calendar.dayKey(for: $0.date)) }
    }

    /// 计划内开销（finance.js:60-63 planSpend）：周期额度只算这部分。
    public static func inPlan(_ items: [MergedExpense]) -> [MergedExpense] {
        items.filter { !$0.isOutOfPlan }
    }

    /// 计划外合计与笔数（finance.js:65-70 outOfPlanSum）。
    public static func outOfPlan(_ items: [MergedExpense]) -> OutOfPlanSummary {
        let selected = items.filter(\.isOutOfPlan)
        return OutOfPlanSummary(totalYuan: round2(selected.reduce(0) { $0 + $1.amountYuan }),
                                count: selected.count)
    }

    /// 汇总（finance.js:77-92 summarizeSpend）：总额（round2）、按分类、笔数、
    /// 最大单笔（同额取先出现者）、有开销天数、活跃日均。统计口径含计划外。
    public static func summarize(_ items: [MergedExpense], calendar: DayCalendar) -> SpendSummary {
        var total = 0.0
        var byCat: [ExpenseCategory: Double] = [:]
        var days = Set<DayKey>()
        var maxExpense: MergedExpense?
        for item in items {
            let amount = item.amountYuan
            total += amount
            byCat[item.category, default: 0] += amount
            days.insert(calendar.dayKey(for: item.date))
            if maxExpense == nil || amount > maxExpense!.amountYuan { maxExpense = item }
        }
        let roundedTotal = round2(total)
        let daysWithSpend = days.count
        return SpendSummary(totalYuan: roundedTotal,
                            count: items.count,
                            byCat: byCat.mapValues { round2($0) },
                            maxExpense: maxExpense,
                            daysWithSpend: daysWithSpend,
                            avgPerActiveDayYuan: daysWithSpend > 0
                                ? round2(roundedTotal / Double(daysWithSpend)) : 0)
    }

    // MARK: - 冻结签名（design.md §2.1，不得偏离）

    /// 周或月预算状态（spent/projected/剩余与拉回指引）+ 合并开销流汇总
    /// （manual + diet auto 派生）。预算未设/非正 → nil（finance.js:149）。
    ///
    /// 节奏预测（finance.js:148-165）：`projected = spent / (elapsed/total)`，
    /// elapsed = [rangeStart, min(now, rangeEnd)) 的实际时长（下限 1 秒防除零，
    /// lifttime 为 1ms 同意图）；daysLeft = ceil(剩余时长/1 天) 且 ≥1。
    /// 周期额度只算计划内条目（双口径见 BudgetStatus 注释）。
    public static func status(budgetYuan: Double?, span: DateSpan, expenses: [Expense], dietEntries: [DietEntry],
                              calendar: DayCalendar, now: Date) -> BudgetStatus? {
        guard let budget = budgetYuan, budget > 0, span.isValid,
              let rangeStart = calendar.date(of: span.startDay),
              let lastDayStart = calendar.date(of: span.endDay),
              let rangeEnd = calendar.calendar.date(byAdding: .day, value: 1, to: lastDayStart)
        else { return nil }

        let inWindow = inRange(mergedExpenses(expenses, dietEntries: dietEntries),
                               in: span, calendar: calendar)
        let summary = summarize(inWindow, calendar: calendar)
        let outOfPlanPart = outOfPlan(inWindow)
        let spent = round2(inPlan(inWindow).reduce(0) { $0 + $1.amountYuan })

        let total = rangeEnd.timeIntervalSince(rangeStart)
        let elapsed = max(1, min(now, rangeEnd).timeIntervalSince(rangeStart))
        let projected = spent / (elapsed / total)
        let daysLeft = max(1, Int((rangeEnd.timeIntervalSince(now) / 86_400).rounded(.up)))
        let remaining = budget - spent

        return BudgetStatus(spentYuan: spent,
                            budgetYuan: budget,
                            pct: Int((spent / budget * 100).rounded()),
                            remainingYuan: round2(remaining),
                            daysLeft: daysLeft,
                            perDayLeftYuan: round2(remaining / Double(daysLeft)),
                            projectedYuan: round2(projected),
                            overProjected: projected > budget,      // :163 未舍入值比较
                            totalYuan: summary.totalYuan,
                            outOfPlanYuan: outOfPlanPart.totalYuan,
                            outOfPlanCount: outOfPlanPart.count,
                            summary: summary)
    }

    /// 记餐的蛋白质性价比（finance.js:95-108）：仅统计 span 内带花费
    /// （`costYuan > 0`）的饮食记录，蛋白取 `totals.proteinG`。
    /// 无带花费记录 → nil；有花费但蛋白为 0 → `per10gYuan` 为 nil。
    public static func proteinEconomy(dietEntries: [DietEntry], in span: DateSpan,
                                      calendar: DayCalendar) -> ProteinEconomy? {
        guard span.isValid else { return nil }
        var cost = 0.0
        var protein = 0.0
        var meals = 0
        for entry in dietEntries where span.contains(calendar.dayKey(for: entry.date)) {
            guard let mealCost = entry.costYuan, mealCost > 0 else { continue }
            cost += mealCost
            protein += entry.totals.proteinG
            meals += 1
        }
        guard meals > 0 else { return nil }
        return ProteinEconomy(costYuan: round2(cost),
                              proteinG: (protein * 10).rounded() / 10,
                              meals: meals,
                              per10gYuan: protein > 0 ? round2(cost / protein * 10) : nil)
    }

    // MARK: - 三档建议（finance.js:174-218）

    /// 预算建议（超支预警 / 临期提醒 / 健康节奏 + 饮食联动诊断），上限 4 条。
    ///
    /// - Parameters:
    ///   - week / month: `status` 产物（nil = 未设预算）；
    ///   - sumWeek: 本周开销汇总（统计口径；与 week 独立——未设预算也能出
    ///     外卖聚餐/补剂占比诊断，lifttime ctx 同形）；
    ///   - proteinEconomy: `proteinEconomy` 产物；
    ///   - proteinHitRate: **注入参数**（§2 契约）——DietEngine.periodDiet 的
    ///     `proteinHitDays / daysTracked`（全记录日达标率），由 UI / report 组装；
    ///     nil = 无饮食记录，不出「钱花出去了营养没跟上」。
    public static func budgetAdvice(week: BudgetStatus?, month: BudgetStatus?,
                                    sumWeek: SpendSummary?, proteinEconomy: ProteinEconomy?,
                                    proteinHitRate: Double?) -> [String] {
        var advice: [String] = []

        if week == nil && month == nil {
            advice.append("还没有设置预算，点「编辑预算」填一个周预算或月预算，这里就能帮你盯节奏了。")
        }
        if let week {
            if week.overProjected {
                if week.remainingYuan < 0 {
                    advice.append("本周已经超预算 ¥\(fmtMoney(-week.remainingYuan))，剩下的日子尽量零额外开销，下周重新回到节奏里就好。")
                } else {
                    advice.append("按目前节奏，本周预计花 ¥\(fmtMoney(week.projectedYuan))，会超预算 ¥\(fmtMoney(week.projectedYuan - week.budgetYuan))。剩下 \(week.daysLeft) 天每天控制在 ¥\(fmtMoney(max(0, week.perDayLeftYuan))) 内可以拉回来。")
                }
            } else if week.pct >= 85 && week.daysLeft > 1 {
                advice.append("本周预算已用 \(week.pct)%，还剩 \(week.daysLeft) 天——后面几天悠着点。")
            }
        }
        if let month, month.overProjected {
            advice.append("本月按节奏预计花 ¥\(fmtMoney(month.projectedYuan))（预算 ¥\(fmtMoney(month.budgetYuan))），建议在月底前把大额开销缓一缓。")
        }

        // —— 饮食联动（finance.js:195-215）——
        let byCat = sumWeek?.byCat ?? [:]
        let foodSpend = byCat[.meals, default: 0] + byCat[.groceries, default: 0]
            + byCat[.takeout, default: 0] + byCat[.social, default: 0]
        let takeoutShare = foodSpend > 0
            ? (byCat[.takeout, default: 0] + byCat[.social, default: 0]) / foodSpend : 0
        if sumWeek != nil, foodSpend > 0, takeoutShare > 0.5,
           let hitRate = proteinHitRate, hitRate < 0.6 {
            let chest = proteinPriceRef[0], egg = proteinPriceRef[1], powder = proteinPriceRef[2]
            advice.append("本周餐饮花费里外卖/聚餐占 \(Int((takeoutShare * 100).rounded()))%，但蛋白质达标率只有 \(Int((hitRate * 100).rounded()))%——钱花出去了营养没跟上。同样的预算，鸡胸(约¥\(chest.per10gYuan)/10g蛋白)、鸡蛋(约¥\(egg.per10gYuan))、蛋白粉(约¥\(powder.per10gYuan))的效率高得多。")
        }
        if let eco = proteinEconomy, let per10g = eco.per10gYuan, eco.meals >= 3 {
            let ref = proteinPriceRef[0]
            var text = "本周记餐花费 ¥\(fmtMoney(eco.costYuan))，换来蛋白质约 \(Int(eco.proteinG.rounded()))g（折合 ¥\(fmtMoney(per10g))/10g）。"
            if per10g > ref.per10gYuan * 3 {
                text += "这个成本偏高，如果一部分换成\(ref.name)（约¥\(ref.per10gYuan)/10g），同样的钱能吃到两倍以上的蛋白质。"
            } else {
                text += "性价比不错，继续保持。"
            }
            advice.append(text)
        }
        let weekTotal = sumWeek?.totalYuan ?? 0
        let supplementShare = weekTotal > 0 ? byCat[.supplement, default: 0] / weekTotal : 0
        if supplementShare > 0.3 {
            advice.append("补剂占了本周开销的 \(Int((supplementShare * 100).rounded()))%，补剂是锦上添花——先把基础饮食的钱花到位再考虑它。")
        }

        if advice.isEmpty { advice.append("花销节奏健康，继续保持。") }
        return Array(advice.prefix(4))    // finance.js:218 上限 4 条
    }

    // MARK: - 金额格式化（finance.js:221-225）

    /// 金额 → 无前缀串：`500` → "500"；`1234.5` → "1,234.50"（round2、
    /// 整数不带小数、千分位逗号；非有限值 → "0"）。
    public static func fmtMoney(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = round2(value)
        if rounded == 0 { return "0" }
        let body = rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.2f", rounded)
        return groupThousands(body)
    }

    /// 千分位分组（:224 正则的等价实现：整数部分自右每三位一逗号，符号与小数不动）。
    private static func groupThousands(_ text: String) -> String {
        let sign = text.hasPrefix("-") ? "-" : ""
        let unsigned = sign.isEmpty ? text : String(text.dropFirst())
        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let digits = parts[0]
        var grouped = ""
        for (offset, character) in digits.enumerated() {
            grouped.append(character)
            let remaining = digits.count - offset
            if remaining % 3 == 1, remaining > 1 { grouped.append(",") }
        }
        return sign + grouped + (parts.count > 1 ? "." + parts[1] : "")
    }

    /// 分位四舍五入（lifttime `Math.round(v * 100) / 100`）。
    /// internal：BudgetPlans.swift 的计划引擎扩展（同模块跨文件）复用。
    static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
