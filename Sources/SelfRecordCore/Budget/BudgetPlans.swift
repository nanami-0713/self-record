import Foundation

// MARK: - 自定义周期计划（design.md §9-6 后置项，本次实装）
//
// 口径锚点（lifttime finance.js，均已核对源码）：
// - planSpend :60-63（额度只算计划内条目）；
// - planDays :110-113（起止含首尾，同一天 = 1 天，end<start = 0 非法）；
// - planRange :115-120（起始归一到当天 0 点，起 N 天）；
// - planStatus :122-128（budgetStatus + notStarted/ended 三态）；
// - planAdvice :130-145（未开始/已结束/健康 → null，超节奏/临期两档文案）；
// - budgetStatus 数学 :148-165（projected = spent / (elapsed/total)、daysLeft ≥ 1）。
// 交互锚点（lifttime budget.js）：planCard :102-124（三态卡片 + 计外行 +
// 再来一期按钮）、planSheet :300-360（名称 ≤12 字可选、金额 > 0、起止实时
// 「共 N 天」提示、最长 365 天）、再来一期 :90-97。
//
// 形状差异（有意决策）：lifttime 存 {days, startTs}，本实现存显式起止日键
// （含首尾）——days 由 `planDays` 派生；起日天然「归一到当天 0 点」
// （DayKey 即 startOfDay 语义）。「再来一期」从 lifttime 的「原计划改起点、
// 今天重开」升级为「等长等额、紧接上一期结束日之后开新期、原计划保留」
// （任务规格：历史总结不漂移，多计划并存）。

/// 用户自建 N 天预算计划：起止日期与金额全自定义，可多个并存
/// （lifttime `settings.customBudgets`，budget.js:65/:93/:352）。
public struct CustomBudgetPlan: Codable, Sendable, Identifiable, Equatable {

    public var id: UUID
    /// 展示名。空串回退「N天计划」（budget.js:109/:133 `plan.name || plan.days + '天计划'`）。
    public var name: String
    /// 周期额度（¥）。必须 > 0 且在净化域内（同 Expense.amountYuan 的 0–1e7）。
    public var amountYuan: Double
    /// 首日（含）。同一天起止 = 1 天计划。
    public var startDay: DayKey
    /// 末日（含）。起止差 13 天 = 14 天计划；end < start 非法（isValid = false）。
    public var endDay: DayKey

    public init(id: UUID = UUID(), name: String = "", amountYuan: Double,
                startDay: DayKey, endDay: DayKey) {
        self.id = id
        self.name = name
        self.amountYuan = amountYuan
        self.startDay = startDay
        self.endDay = endDay
    }

    /// 结构合法性：金额 > 0 且在净化域、起止均为真实日键且 start ≤ end
    /// （§4 管线 3 的值上校验入口；非法计划不入库、不参与计算）。
    public var isValid: Bool {
        amountYuan.isFinite
            && amountYuan > 0
            && SanitizeLimits.amountRange.contains(amountYuan)
            && DayKey.isValid(startDay.rawValue)
            && DayKey.isValid(endDay.rawValue)
            && startDay.rawValue <= endDay.rawValue
    }

    enum CodingKeys: String, CodingKey {
        case id, name, amountYuan, startDay, endDay
    }

    /// 宽松解码（§4 管线 2）：name / amountYuan 缺 key 归默认（向后兼容——
    /// 未来新增字段同样以 optional 或默认值形态在此扩展）；id / 起止日键缺失
    /// 或非法 → 抛错丢整条（元素级容错由 `BackupSanitizer.lenientArray` 承担）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        amountYuan = (try? c.decodeIfPresent(Double.self, forKey: .amountYuan)) ?? 0
        guard let start = (try? c.decodeIfPresent(String.self, forKey: .startDay))
            .flatMap({ DayKey(rawValue: $0) }),
            let end = (try? c.decodeIfPresent(String.self, forKey: .endDay))
                .flatMap({ DayKey(rawValue: $0) })
        else { throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: c.codingPath,
                                  debugDescription: "计划起止日键缺失或非法")) }
        startDay = start
        endDay = end
    }

    /// 存储层净化（§4 管线 3）：结构性非法（金额 ≤ 0 / 越界、起止非法、
    /// end < start）整条剔除；金额 clamp 到净化域；名称截 12 字
    /// （budget.js:312 maxlength=12）。天数上限（365）由表单入口把关，
    /// 此处不做二次裁决——超长区间计算无害。
    public static func sanitized(_ plans: [CustomBudgetPlan]) -> [CustomBudgetPlan] {
        plans.map { plan in
            var plan = plan
            plan.amountYuan = min(max(plan.amountYuan, SanitizeLimits.amountRange.lowerBound),
                                  SanitizeLimits.amountRange.upperBound)
            plan.name = plan.name.count <= 12 ? plan.name : String(plan.name.prefix(12))
            return plan
        }
        .filter(\.isValid)
    }
}

/// 自定义计划状态 = budgetStatus（finance.js:148-165 的数学）+
/// 未开始/进行中/已结束三态（:122-128 planStatus）。lifttime 的 `invalid`
/// 形态（:126，budget ≤ 0 时返回）在 SelfRecord 映射为 `planStatus` 返回 nil。
public struct CustomPlanStatus: Codable, Sendable, Equatable {

    /// 三态（finance.js:126-127：notStarted = now < start、ended = now ≥ end）。
    public enum Phase: String, Codable, Sendable, CaseIterable {
        /// 未开始（now < 起日 0 点）。
        case upcoming
        /// 进行中。
        case active
        /// 已结束（now ≥ 止日 24 点）。
        case ended

        /// 徽标文案（budget.js:114「开始」/:121「已结束」的 SelfRecord 三态化）。
        public var title: String {
            switch self {
            case .upcoming: return "未开始"
            case .active: return "进行中"
            case .ended: return "已结束"
            }
        }
    }

    public var phase: Phase

    // MARK: 额度口径（planSpend：只算计划内条目，计划外不占额度）

    /// 周期内计划内花费（round2）。
    public var spentYuan: Double
    public var budgetYuan: Double
    /// 已用百分比（取整 round，finance.js:157）。
    public var pct: Int
    /// 剩余额度（round2，可为负——负数即已超支）。
    public var remainingYuan: Double
    /// 剩余天数（≥1；finance.js:153 的 ceil 口径）。
    public var daysLeft: Int
    /// 今天起日均还能花（round2）——「剩 N 天每天控制在 ¥X 内可拉回」的数值源。
    public var perDayLeftYuan: Double
    /// 节奏预测：`spent / (elapsed/total)` 线性外推（finance.js:152，round2）。
    public var projectedYuan: Double
    /// **未舍入** projected 是否超预算（finance.js:163）。
    public var overProjected: Bool

    // MARK: 时间进度（双进度条 UI：时间进度 vs 花销进度）

    /// 计划总天数（含首尾）。
    public var daysTotal: Int
    /// 时间进度 0…1（upcoming = 0、ended = 1、进行中 = 已过时长占比）。
    public var timeProgress: Double

    // MARK: 总账口径（含计划外——统计照常、额度不算）

    public var totalYuan: Double
    public var outOfPlanYuan: Double
    public var outOfPlanCount: Int
    /// 窗口内合并开销流汇总（统计口径，byCat 含计外条目）。
    public var summary: SpendSummary

    public init(phase: Phase, spentYuan: Double, budgetYuan: Double, pct: Int,
                remainingYuan: Double, daysLeft: Int, perDayLeftYuan: Double,
                projectedYuan: Double, overProjected: Bool, daysTotal: Int,
                timeProgress: Double, totalYuan: Double, outOfPlanYuan: Double,
                outOfPlanCount: Int, summary: SpendSummary) {
        self.phase = phase
        self.spentYuan = spentYuan
        self.budgetYuan = budgetYuan
        self.pct = pct
        self.remainingYuan = remainingYuan
        self.daysLeft = daysLeft
        self.perDayLeftYuan = perDayLeftYuan
        self.projectedYuan = projectedYuan
        self.overProjected = overProjected
        self.daysTotal = daysTotal
        self.timeProgress = timeProgress
        self.totalYuan = totalYuan
        self.outOfPlanYuan = outOfPlanYuan
        self.outOfPlanCount = outOfPlanCount
        self.summary = summary
    }
}

// MARK: - 计划引擎纯函数（BudgetEngine 扩展；语义严格对齐 lifttime finance.js）

extension BudgetEngine {

    /// 计划内开销（finance.js:60-63 planSpend）：计划额度只算这部分，
    /// 计划外条目计总账与统计、不占额度（双口径 §3.5）。
    /// 与周/月的 `inPlan` 同实现、两个名字并存——`inPlan` 是周/月口径的
    /// 既有入口（status 冻结签名内用），`planSpend` 是 lifttime 的原名入口。
    public static func planSpend(_ items: [MergedExpense]) -> [MergedExpense] {
        inPlan(items)
    }

    /// 起止日键 → 计划天数（含首尾；finance.js:110-113 planDays）：
    /// 同一天 = 1 天、起止差 13 天 = 14 天、end < start = 0（非法）。
    /// 日差用 `dateComponents([.day])` 日历运算——跨 DST 时区安全
    /// （lifttime `Math.round(ms / 86400000)` 的等价物）。
    public static func planDays(from start: DayKey, to end: DayKey,
                                calendar: DayCalendar) -> Int {
        guard let first = calendar.date(of: start),
              let last = calendar.date(of: end),
              let diff = calendar.calendar.dateComponents([.day], from: first, to: last).day
        else { return 0 }
        return diff >= 0 ? diff + 1 : 0
    }

    /// 计划区间（finance.js:115-120 planRange）：起日 0 点起、含首尾 N 天
    /// （止日 24 点止）。lifttime 需把 startTs「归一到当天 0 点」——DayKey
    /// 形态天然归一；时间戳区间（[起 00:00, 止次日 00:00)）由 `planStatus`
    /// 内部按 `status` 同款方式构造。
    public static func planRange(_ plan: CustomBudgetPlan) -> DateSpan {
        DateSpan(startDay: plan.startDay, endDay: plan.endDay)
    }

    /// 计划展示名（budget.js:109/:133：`plan.name || plan.days + '天计划'`；
    /// 空白名视同未填）。
    public static func planDisplayName(_ plan: CustomBudgetPlan,
                                       calendar: DayCalendar) -> String {
        let trimmed = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let days = planDays(from: plan.startDay, to: plan.endDay, calendar: calendar)
        return "\(days)天计划"
    }

    /// 自定义计划状态（finance.js:122-128 planStatus：budgetStatus 数学 +
    /// 三态标记）。开销流 = `mergedExpenses` 在计划窗口内的部分（复用
    /// `inRange`），额度口径 = `planSpend`（计划外不计入额度），总账/统计
    /// 口径含计划外——与周/月 `status` 完全同构。
    ///
    /// 计划结构非法（金额 ≤ 0、起止非法、end < start）→ nil
    /// （lifttime 的 `{ invalid: true }` 形态，:126）。
    public static func planStatus(_ plan: CustomBudgetPlan, expenses: [Expense],
                                  dietEntries: [DietEntry], calendar: DayCalendar,
                                  now: Date) -> CustomPlanStatus? {
        guard plan.isValid,
              let rangeStart = calendar.date(of: plan.startDay),
              let lastDayStart = calendar.date(of: plan.endDay),
              let rangeEnd = calendar.calendar.date(byAdding: .day, value: 1, to: lastDayStart)
        else { return nil }

        let span = planRange(plan)
        let inWindow = inRange(mergedExpenses(expenses, dietEntries: dietEntries),
                               in: span, calendar: calendar)
        let summary = summarize(inWindow, calendar: calendar)
        let outPart = outOfPlan(inWindow)
        let spent = round2(planSpend(inWindow).reduce(0) { $0 + $1.amountYuan })

        // —— budgetStatus 数学（finance.js:150-163；elapsed 下限 1 秒防除零）——
        let total = rangeEnd.timeIntervalSince(rangeStart)
        let elapsed = max(1, min(now, rangeEnd).timeIntervalSince(rangeStart))
        let projected = spent / (elapsed / total)
        let daysLeft = max(1, Int((rangeEnd.timeIntervalSince(now) / 86_400).rounded(.up)))
        let remaining = plan.amountYuan - spent

        // —— 三态 + 时间进度（finance.js:126-127；upcoming = 0、ended = 1）——
        let phase: CustomPlanStatus.Phase
        if now < rangeStart { phase = .upcoming }
        else if now >= rangeEnd { phase = .ended }
        else { phase = .active }
        let timeProgress: Double
        if now <= rangeStart {
            timeProgress = 0
        } else if now >= rangeEnd {
            timeProgress = 1
        } else {
            timeProgress = min(1, max(0, now.timeIntervalSince(rangeStart) / total))
        }

        return CustomPlanStatus(
            phase: phase,
            spentYuan: spent,
            budgetYuan: plan.amountYuan,
            pct: Int((spent / plan.amountYuan * 100).rounded()),
            remainingYuan: round2(remaining),
            daysLeft: daysLeft,
            perDayLeftYuan: round2(remaining / Double(daysLeft)),
            projectedYuan: round2(projected),
            overProjected: projected > plan.amountYuan,      // :163 未舍入值比较
            daysTotal: planDays(from: plan.startDay, to: plan.endDay, calendar: calendar),
            timeProgress: timeProgress,
            totalYuan: summary.totalYuan,
            outOfPlanYuan: outPart.totalYuan,
            outOfPlanCount: outPart.count,
            summary: summary)
    }

    /// 自定义计划建议（finance.js:130-145 planAdvice，文案逐字对齐）：
    /// 未开始 / 已结束 / 健康节奏 → nil（不打扰）；超节奏给拉回指引
    /// （「剩 N 天每天控制在 ¥X 内可以拉回」）；临期高占比（≥85% 且
    /// 剩 > 1 天）给提醒。
    public static func planAdvice(_ plan: CustomBudgetPlan, status: CustomPlanStatus?,
                                  calendar: DayCalendar) -> String? {
        guard let status, plan.isValid else { return nil }
        if status.phase == .upcoming || status.phase == .ended { return nil }   // :132
        let name = planDisplayName(plan, calendar: calendar)
        if status.overProjected {
            if status.remainingYuan < 0 {
                return "「\(name)」已超预算 ¥\(fmtMoney(-status.remainingYuan))，剩余 \(status.daysLeft) 天尽量零额外开销。"
            }
            return "「\(name)」按目前节奏预计花 ¥\(fmtMoney(status.projectedYuan))，会超预算 ¥\(fmtMoney(status.projectedYuan - status.budgetYuan))；剩 \(status.daysLeft) 天每天控制在 ¥\(fmtMoney(max(0, status.perDayLeftYuan))) 内可以拉回。"
        }
        if status.pct >= 85 && status.daysLeft > 1 {
            return "「\(name)」预算已用 \(status.pct)%，还剩 \(status.daysLeft) 天，后面留意节奏。"
        }
        return nil
    }

    /// 再来一期（budget.js:90-97 的交互入口）：**等长等额、紧接着上一期
    /// 结束日之后开新期**（新起日 = 上期止日 + 1 天，新止日 = 新起日 +
    /// (天数-1)），新 id、原计划保留——历史总结不漂移（lifttime 是原计划
    /// 改起点从今天重开，此处按任务规格升级）。上期结构非法 → nil。
    public static func renewedPlan(from plan: CustomBudgetPlan,
                                   calendar: DayCalendar) -> CustomBudgetPlan? {
        let days = planDays(from: plan.startDay, to: plan.endDay, calendar: calendar)
        guard days >= 1,
              let newStart = calendar.addingDays(1, to: plan.endDay),
              let newEnd = calendar.addingDays(days - 1, to: newStart)
        else { return nil }
        return CustomBudgetPlan(id: UUID(), name: plan.name, amountYuan: plan.amountYuan,
                                startDay: newStart, endDay: newEnd)
    }
}
