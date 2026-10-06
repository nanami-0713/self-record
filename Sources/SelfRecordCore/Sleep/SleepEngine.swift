import Foundation

// MARK: - sleep 模块（design.md §3.2）
//
// 两击上床/起床 + 可跳过问卷的睡眠分析引擎：-4h 归属 + dayOverride 手动调整、
// 午睡识别（09:00–18:00 开始且 <3h）、睡眠分 0–100（时长 40 + 规律 30 + 感受 20 +
// 连续 10，未填项中性分：感受 13、连续 10）、睡眠债（缺记夜不进均值不记债）。
//
// lifttime 对应：js/sleepMath.js（:12-18 归属、:26-31 午睡、:36-48 主睡眠/午睡列表、
// :70-81 就寝锚、:95-107 评分、:115-147 阶段统计）+ js/reportBuilder.js:83-90
// （区间 medAnchor → 逐夜 sleepScore）。日简报睡眠区不显示单夜分数
// （report.js:172-176 同——分数归区间层）。
//
// 手动补录/编辑（js/sleep.js:171-279 sessionSheet 的 Core 部分）：
// makeSession/entryError/entryPreview——补录会话与两击会话**同一模型、同一口径**
// （isNap/sessionDay/score/periodSummary 全部现算，无需也无法区分来源）。
//
// 口径注记（§3.2，照抄 lifttime 并锁定锚点）：
// - 规律分参照锚 medAnchor 无记录时默认 330（23:30，sleepMath.js:98/:125）；
// - 规律分偏差用 |anchor − med| 的**线性差而非圆刻度差**（sleepMath.js:99）——
//   17:5x 就寝者会被误判偏差巨大而规律分归零，是 lifttime 已知缺陷：照抄保锚点，
//   圆刻度修正为后置项（修正即改测试锚点，须显式决策，design.md §9-10）；
// - 分数层归属（A3 口径）：nightForDay 只取段不评分（sleepMath.js:36-41）；
//   单夜分数只经 score(session, goalMinutes:, medAnchorMinutes:)（nil→330）显式
//   计算，多夜分数一律出自 periodSummary（锚=区间中位或 330，reportBuilder.js:83-90
//   口径）——同一夜在任何页面分数相同，杜绝锚漂移。

/// 睡眠引擎（§3.2）。三个聚合 API 签名 = 骨架冻结物 B（§2.1），不得偏离。
public enum SleepEngine {

    /// 默认睡眠目标 8 小时（lifttime DEFAULT_GOAL_MIN，sleepMath.js:5）；
    /// goalMinutes ≤ 0 时回退到它。
    public static let defaultGoalMinutes = 480

    // MARK: 归属规则（sleepMath.js:12-23）

    /// 睡醒时刻往前推 4 小时所在的日期 = 这段睡眠归属的那天（显示为那天的「昨晚」）。
    /// 只回退 4 小时：05:00–06:00 醒来的早鸟也能把睡眠算进「今天早上醒来」的这一天；
    /// 跨零点的短段（22:00 睡 00:30 醒）仍会被拉回睡前那个晚上。
    public static func sleepDayKey(end: Date, calendar: DayCalendar) -> DayKey {
        DayKey(end.addingTimeInterval(-4 * 3600), calendar: calendar)
    }

    /// 会话归属日：手动调整过（dayOverride）以调整为准，否则 -4h 自动规则。
    public static func sessionDay(_ session: SleepSession, calendar: DayCalendar) -> DayKey {
        session.dayOverride ?? sleepDayKey(end: session.end, calendar: calendar)
    }

    // MARK: 午睡识别与时长（sleepMath.js:26-33）

    /// 午睡：09:00–18:00 之间开始且短于 3 小时（sleepMath.js:26-31）。
    /// 09:00 整开始算午睡、18:00 整开始不算（闭开区间）；恰 3h 不算（严格小于）。
    public static func isNap(start: Date, end: Date, calendar: DayCalendar) -> Bool {
        let c = calendar.calendar.dateComponents([.hour, .minute], from: start)
        let minuteOfDay = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        guard minuteOfDay >= 9 * 60, minuteOfDay < 18 * 60 else { return false }
        return end.timeIntervalSince(start) < 3 * 3600
    }

    /// 睡眠段时长（秒）；异常数据（end ≤ start）不为负（sleepMath.js:33）。
    public static func durationSeconds(_ session: SleepSession) -> Double {
        max(0, session.end.timeIntervalSince(session.start))
    }

    // MARK: - 手动补录 / 编辑（sleep.js:171-279 sessionSheet 的 Core 部分）

    /// 上床/起床时间对校验（补记/编辑 sheet 实时禁用保存与错误文案用；
    /// `makeSession` 内部同口径复用）。跨零点合法——只要求 end > start，不限同日。
    public static func entryError(start: Date, end: Date) -> SleepEntryError? {
        guard end > start else { return .endNotAfterStart }
        let seconds = end.timeIntervalSince(start)
        if seconds < 60 { return .tooShort }
        if seconds > 24 * 3600 { return .over24Hours }
        return nil
    }

    /// 构造手动补录/编辑的会话（补记与编辑的共用落点；两击路径之外唯一的
    /// 带校验构造口）。合法时顺手做三件收纳：
    /// - dayOverride 与 -4h 自动归属**相同** → 归 nil（sleep.js:276
    ///   `picked !== sleepDayKey(e2) ? picked : null` 同语义：手动档只在真正
    ///   偏离自动规则时保留，「手动归属」徽标不因等值而虚挂）；
    /// - note 去首尾空白、空串归 nil（TimeEngine.makeBlock 同款）；
    /// - feel/wakeCount 越界归 nil（模型域 1–5 / 0–3，§4；UI 单选不会越界，
    ///   防御兜底，与净化管线「越界归 nil」一致）。
    ///
    /// 午睡/归属日**不在此计算**：isNap/sessionDay 由 nightForDay / napsForDay /
    /// periodSummary 对补录与两击会话同一口径现算（同一 SleepSession 形状，
    /// 天然一视同仁）；UI 预览用 `entryPreview`。
    public static func makeSession(start: Date, end: Date,
                                   feel: Int?, wakeCount: Int?, latency: SleepLatency?,
                                   note: String? = nil, dayOverride: DayKey? = nil,
                                   calendar: DayCalendar) -> Result<SleepSession, SleepEntryError> {
        if let error = entryError(start: start, end: end) { return .failure(error) }
        let autoDay = sleepDayKey(end: end, calendar: calendar)
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(SleepSession(
            start: start,
            end: end,
            feel: feel.flatMap { (1...5).contains($0) ? $0 : nil },
            wakeCount: wakeCount.flatMap { (0...3).contains($0) ? $0 : nil },
            latency: latency,
            note: (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote,
            dayOverride: dayOverride == autoDay ? nil : dayOverride
        ))
    }

    /// 补录/编辑的归属预览（sheet「将记为 10月5日晚 · 夜睡」实时文案的数据源）：
    /// 归属日 = dayOverride ?? -4h 自动规则（sessionDay 同口径）；isNap 与
    /// napsForDay 同口径现算。时间对非法时仍返回（isNap 按实际间隔判定，
    /// 校验错误由 entryError 单独表达，UI 各自展示）。
    public static func entryPreview(start: Date, end: Date, dayOverride: DayKey?,
                                    calendar: DayCalendar) -> SleepEntryPreview {
        SleepEntryPreview(
            day: dayOverride ?? sleepDayKey(end: end, calendar: calendar),
            isNap: isNap(start: start, end: end, calendar: calendar)
        )
    }

    // MARK: 就寝锚（sleepMath.js:70-81）

    /// 就寝时刻换算到「自 18:00 起的分钟数」刻度（模 1440），
    /// 让 23:50 与 00:10 在同一根轴上相邻可比。
    public static func bedtimeAnchorMinutes(_ start: Date, calendar: DayCalendar) -> Int {
        let c = calendar.calendar.dateComponents([.hour, .minute], from: start)
        let minuteOfDay = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return ((minuteOfDay - 18 * 60) % 1440 + 1440) % 1440
    }

    /// 锚点刻度 → "HH:MM"（展示中位就寝用，sleepMath.js:76-81；
    /// 取整对非负锚与 JS Math.round 同为 half-up）。
    public static func anchorToBedtimeHM(_ anchor: Double) -> String {
        let rounded = Int(anchor.rounded())
        let m = ((rounded % 1440) + 1440) % 1440
        let t = (m + 18 * 60) % 1440
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    /// 中位数（输入须已升序；sleepMath.js:83-87——偶数个取中间两数均值，可为 .5）。
    static func median(ofSorted sorted: [Int]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return Double(sorted[mid]) }
        return (Double(sorted[mid - 1]) + Double(sorted[mid])) / 2
    }

    // MARK: 冻结物 B 聚合 API（design.md §2.1）

    /// 某夜主睡眠（分段夜取最长段）+ 简报字段（时长/起止/感受/连续/就寝锚）。
    /// ⚠ 不含睡眠分——lifttime 的 nightForDay 只取段不评分（sleepMath.js:36-41），
    /// 分数永远由 score/periodSummary 以显式锚计算（A3 口径）。
    public static func nightForDay(_ sessions: [SleepSession], day: DayKey, calendar: DayCalendar) -> SleepNight? {
        var best: SleepSession?
        for s in sessions {
            guard sessionDay(s, calendar: calendar) == day,
                  !isNap(start: s.start, end: s.end, calendar: calendar)
            else { continue }
            if let b = best, durationSeconds(s) <= durationSeconds(b) { continue }
            best = s
        }
        return best.map { night($0, calendar: calendar) }
    }

    /// 某天的午睡列表（sleepMath.js:46-48）——日简报「午睡 X 分钟」的数据源。
    public static func napsForDay(_ sessions: [SleepSession], day: DayKey, calendar: DayCalendar) -> [SleepSession] {
        sessions.filter {
            sessionDay($0, calendar: calendar) == day
                && isNap(start: $0.start, end: $0.end, calendar: calendar)
        }
    }

    /// 单夜睡眠分 0–100（时长 40/规律 30/感受 20/连续 10，未填项中性分）。
    /// medAnchorMinutes = 就寝规律参照锚（自 18:00 起的分钟数），nil → 330（23:30，sleepMath.js:98）。
    public static func score(_ session: SleepSession, goalMinutes: Int,
                             medAnchorMinutes: Double?, calendar: DayCalendar) -> Int {
        let goal = Double(goalMinutes > 0 ? goalMinutes : defaultGoalMinutes)

        // 时长达成 40：实际/目标，封顶 1（sleepMath.js:97）
        let durationPoints = 40 * min(1, durationSeconds(session) / 60 / goal)

        // 就寝规律 30：偏差 ≥90 分钟归零（sleepMath.js:98-100）。
        // ⚠ 偏差 = |anchor − med| 线性差而非圆刻度差（sleepMath.js:99，lifttime
        //   已知缺陷照抄保锚点）：17:5x 就寝者 anchor 取模后落在 14xx，被判偏差
        //   巨大而归零。圆刻度修正为 v1.x 后置项，修正即改测试锚点，须显式决策。
        let med = medAnchorMinutes ?? 330
        let deviation = abs(Double(bedtimeAnchorMinutes(session.start, calendar: calendar)) - med)
        let regularityPoints = 30 * max(0, 1 - deviation / 90)

        // 起床感受 20（sleepMath.js:101-102 的 FEEL 表）；未填给中性分 13
        // （不惩罚只点两下的用户）
        let feelPoints: Double
        switch session.feel {
        case 1: feelPoints = 3
        case 2: feelPoints = 8
        case 3: feelPoints = 14
        case 4: feelPoints = 18
        case 5: feelPoints = 20
        default: feelPoints = 13
        }

        // 夜间连续 10（sleepMath.js:103-105）；未填给中性分 10（wakes 未填不扣）。
        // 夜醒封顶 3 档（min(3, wakes)×2.5），入睡慢/中最多再扣 3/1，连续分下限 0。
        var continuityPoints = 10.0
        if let wakes = session.wakeCount, wakes > 0 {
            continuityPoints -= Double(min(3, wakes)) * 2.5
        }
        switch session.latency {
        case .slow: continuityPoints -= 3
        case .ok: continuityPoints -= 1
        case .fast, .none: break  // fast 扣 0；未填同 0
        }
        continuityPoints = max(0, continuityPoints)

        // 各项非负，Swift rounded()（half away from zero）与 JS Math.round（half up）一致
        return Int((durationPoints + regularityPoints + feelPoints + continuityPoints).rounded())
    }

    /// 区间睡眠统计：锚 = 区间内就寝锚中位数（无记录 → 330，reportBuilder.js:83-84 口径）；
    /// 产出逐夜分数序列 + avgScore + MAD + 睡眠债 + 缺记夜列表（缺夜不进均值不记债）。
    /// 所有「多夜分数」展示（SleepView 趋势、report avgScore）一律出自本函数——
    /// 同一夜在任何页面分数相同，杜绝锚漂移。
    public static func periodSummary(_ sessions: [SleepSession], in span: DateSpan, goalMinutes: Int, calendar: DayCalendar) -> SleepPeriodSummary {
        let goal = goalMinutes > 0 ? goalMinutes : defaultGoalMinutes

        // 区间逐日（含首尾；span 无效 → 空序列）。等价 lifttime 的
        // lastNDays / reportBuilder 的区间逐天枚举。
        var days: [DayKey] = []
        var cursor = span.startDay
        while span.contains(cursor) {
            days.append(cursor)
            guard let next = calendar.addingDays(1, to: cursor) else { break }
            cursor = next
        }

        // 一趟遍历完成归属日分组（sleepStats 逐日 nightForDay/napsForDay 的等价物）：
        // 夜段同日取最长，午睡段按日累计秒。
        var nightByDay: [DayKey: SleepSession] = [:]
        var napSecondsByDay: [DayKey: Double] = [:]
        for s in sessions {
            let day = sessionDay(s, calendar: calendar)
            if isNap(start: s.start, end: s.end, calendar: calendar) {
                napSecondsByDay[day, default: 0] += durationSeconds(s)
            } else if let current = nightByDay[day] {
                if durationSeconds(s) > durationSeconds(current) { nightByDay[day] = s }
            } else {
                nightByDay[day] = s
            }
        }

        // 已记录夜（只统计区间内）：缺记的夜不记债务也不计入均值，
        // 但以 nil 占位出现在 series 里（sleepMath.js:118-123/:129-134）。
        var rowByDay: [DayKey: (session: SleepSession, minutes: Int, anchor: Int)] = [:]
        var napSecondsTotal = 0.0
        for day in days {
            napSecondsTotal += napSecondsByDay[day] ?? 0
            guard let s = nightByDay[day] else { continue }
            rowByDay[day] = (s,
                             Int((durationSeconds(s) / 60).rounded()),
                             bedtimeAnchorMinutes(s.start, calendar: calendar))
        }

        let n = rowByDay.count
        let medAnchor = median(ofSorted: rowByDay.values.map(\.anchor).sorted()) ?? 330  // 无记录 → 330

        var series: [SleepPeriodNight] = []
        var missingDays: [DayKey] = []
        var scoreSum = 0
        var totalSeconds = 0.0
        var madSum = 0.0
        for row in rowByDay.values {
            totalSeconds += durationSeconds(row.session)
            madSum += abs(Double(row.anchor) - medAnchor)
        }
        for day in days {
            guard let row = rowByDay[day] else {
                series.append(SleepPeriodNight(day: day, durationMinutes: nil, score: nil, feel: nil))
                missingDays.append(day)
                continue
            }
            // 逐夜分数用区间中位锚显式计算（reportBuilder.js:83-90 口径）
            let s = score(row.session, goalMinutes: goal, medAnchorMinutes: medAnchor, calendar: calendar)
            scoreSum += s
            series.append(SleepPeriodNight(day: day, durationMinutes: row.minutes, score: s, feel: row.session.feel))
        }

        // 睡眠债 = 各晚 max(0, 目标 − 实际) 之和，只统计已记录的夜（sleepMath.js:128）
        let debtMinutes = rowByDay.values.reduce(0) { $0 + max(0, goal - $1.minutes) }

        return SleepPeriodSummary(
            nights: n,
            goalMinutes: goal,
            avgMinutes: n > 0 ? Int((totalSeconds / 60 / Double(n)).rounded()) : nil,
            medAnchorMinutes: medAnchor,
            medBedtimeHM: anchorToBedtimeHM(medAnchor),
            madMinutes: n > 0 ? Int((madSum / Double(n)).rounded()) : nil,
            debtMinutes: debtMinutes,
            napMinutes: Int((napSecondsTotal / 60).rounded()),
            avgScore: n > 0 ? Int((Double(scoreSum) / Double(n)).rounded()) : nil,
            series: series,
            missingDays: missingDays
        )
    }

    /// SleepSession → SleepNight 简报快照（私有组装）。
    static func night(_ session: SleepSession, calendar: DayCalendar) -> SleepNight {
        SleepNight(
            sessionID: session.id,
            start: session.start,
            end: session.end,
            durationSeconds: durationSeconds(session),
            feel: session.feel,
            wakeCount: session.wakeCount,
            latency: session.latency,
            bedtimeAnchorMinutes: bedtimeAnchorMinutes(session.start, calendar: calendar)
        )
    }
}

// MARK: - 手动补录/编辑的校验错误与预览类型（sleep.js:171-279）

/// 补录/编辑时间对校验错误（sheet 内联文案 + 测试锚点；lifttime 两条 toast 语义
/// + 净化管线结构性剔除口径的录入侧前移——超限会话导入时会被整条剔除，
/// 录入侧先拦，避免「存了又静默消失」）。
public enum SleepEntryError: Equatable, Sendable, Error {
    /// 起床不晚于上床（end ≤ start）——结构性非法，与 §4 净化管线剔除口径一致
    case endNotAfterStart
    /// 时长不足 1 分钟（sleep.js:255「这段睡眠太短了，检查一下时间」）
    case tooShort
    /// 单段超过 24 小时（sleep.js:256「睡眠不能超过 24 小时」+ §4 净化域 ≤24h）
    case over24Hours
}

/// 补录/编辑归属预览（`entryPreview` 产物；文案拼装归 UI，判定归引擎）。
public struct SleepEntryPreview: Equatable, Sendable {
    /// 归属日（dayOverride 优先，否则 -4h 自动规则——sessionDay 同口径）
    public var day: DayKey
    /// 是否按午睡判定（09:00–18:00 开始且 <3h——isNap 同口径）
    public var isNap: Bool

    public init(day: DayKey, isNap: Bool) {
        self.day = day
        self.isNap = isNap
    }
}

// MARK: - nightForDay 返回类型（design.md §2.1：字段按 §3.2 填充，不含睡眠分）

/// 某夜主睡眠的简报字段（时长/起止/感受/连续/就寝锚）。
/// ⚠ 不含睡眠分——A3 口径：单夜分数只经 `SleepEngine.score` 显式计算。
public struct SleepNight: Codable, Sendable, Equatable {
    public var sessionID: UUID
    /// 就床时刻
    public var start: Date
    /// 起床时刻
    public var end: Date
    /// 睡眠时长（秒）
    public var durationSeconds: Double
    /// 起床感受 1–5，nil = 问卷跳过未填
    public var feel: Int?
    /// 夜醒次数 0–3，nil = 未填
    public var wakeCount: Int?
    /// 入睡快慢，nil = 未填
    public var latency: SleepLatency?
    /// 就寝规律锚（自 18:00 起模 1440 分钟）——`score` 的输入之一
    public var bedtimeAnchorMinutes: Int

    public init(sessionID: UUID, start: Date, end: Date, durationSeconds: Double,
                feel: Int?, wakeCount: Int?, latency: SleepLatency?, bedtimeAnchorMinutes: Int) {
        self.sessionID = sessionID
        self.start = start
        self.end = end
        self.durationSeconds = durationSeconds
        self.feel = feel
        self.wakeCount = wakeCount
        self.latency = latency
        self.bedtimeAnchorMinutes = bedtimeAnchorMinutes
    }
}

// MARK: - periodSummary 返回类型（design.md §2.1）

/// periodSummary 的逐夜序列元素（sleepMath.js:129-134 的 series 项）：
/// 缺记夜 durationMinutes/score/feel 为 nil（lifttime 以 null 占位，键保留）。
public struct SleepPeriodNight: Codable, Sendable, Equatable {
    public var day: DayKey
    /// 主睡眠时长（分钟），nil = 缺记夜
    public var durationMinutes: Int?
    /// 单夜睡眠分（区间中位锚计算），nil = 缺记夜
    public var score: Int?
    public var feel: Int?

    public init(day: DayKey, durationMinutes: Int?, score: Int?, feel: Int?) {
        self.day = day
        self.durationMinutes = durationMinutes
        self.score = score
        self.feel = feel
    }
}

/// 区间睡眠统计（sleepMath.js:115-147 sleepStats + reportBuilder.js:71-95 区间口径）。
/// 所有「多夜分数」展示一律出自本结构——同一夜在任何页面分数相同。
public struct SleepPeriodSummary: Codable, Sendable, Equatable {
    /// 已记录晚数（缺记夜不计）
    public var nights: Int
    /// 实际生效目标（goalMinutes ≤ 0 时已回退 480）
    public var goalMinutes: Int
    /// 平均夜间时长（分钟），nil = 无记录
    public var avgMinutes: Int?
    /// 区间就寝锚中位数（分钟，可为 .5），无记录 = 330（23:30）
    public var medAnchorMinutes: Double
    /// 中位就寝 "HH:MM"（无记录回退 "23:30"）
    public var medBedtimeHM: String
    /// 就寝规律 MAD（分钟），nil = 无记录
    public var madMinutes: Int?
    /// 睡眠债（分钟）= 各已记录晚 max(0, 目标 − 实际) 之和；缺记夜不记债
    public var debtMinutes: Int
    /// 区间内午睡总分钟（reportBuilder napMin 口径）
    public var napMinutes: Int
    /// 逐夜平均分，nil = 无记录
    public var avgScore: Int?
    /// 逐夜序列（区间日序，旧 → 新；缺记夜以 nil 占位）
    public var series: [SleepPeriodNight]
    /// 缺记夜列表（series 中 durationMinutes == nil 的日子，旧 → 新）
    public var missingDays: [DayKey]

    public init(nights: Int, goalMinutes: Int, avgMinutes: Int?, medAnchorMinutes: Double,
                medBedtimeHM: String, madMinutes: Int?, debtMinutes: Int, napMinutes: Int,
                avgScore: Int?, series: [SleepPeriodNight], missingDays: [DayKey]) {
        self.nights = nights
        self.goalMinutes = goalMinutes
        self.avgMinutes = avgMinutes
        self.medAnchorMinutes = medAnchorMinutes
        self.medBedtimeHM = medBedtimeHM
        self.madMinutes = madMinutes
        self.debtMinutes = debtMinutes
        self.napMinutes = napMinutes
        self.avgScore = avgScore
        self.series = series
        self.missingDays = missingDays
    }
}
