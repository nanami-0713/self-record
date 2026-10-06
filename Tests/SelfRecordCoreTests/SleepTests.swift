import Testing
import Foundation
@testable import SelfRecordCore

// MARK: - sleep 模块测试（design.md §3.2 测试清单）
//
// 移植 lifttime tests/sleep.test.mjs 全部 48 项断言语义（1:1，逐项对应）：
// 归属 8 边界（03:59 归前夜 / 04:00 归当天）+ dayOverride 优先；
// 分段夜取最长；午睡 8:59 与 18:00 整不算；睡眠分数值锚点 93/100/73/63/85/86
// （medAnchor=330 显式传入）；缺记夜语义（不进均值不记债）；夜醒封顶 3 档。
// 时间锚定 UTC+8（§8 约定 2），固定基准 2026-09-07（周一）20:00。
//
// lifttime 的 daySleepSummary 断言按 A3 口径拆为 nightForDay + napsForDay
// 组合断言（nightForDay 只取段不评分）；anchorToHM 的还原断言直接测公开函数。

@Suite("SleepEngine · 睡眠")
struct SleepEngineTests {

    let cal = DayCalendar.utc8()

    /// lifttime NOW = 2026-09-07 20:00 本地时间（sleep.test.mjs:14）
    var now: Date { ts(9, 7, 20, 0) }

    /// 本地时区（UTC+8）时刻构造（sleep.test.mjs:15 的 ts()）
    func ts(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return cal.calendar.date(from: c)!
    }

    /// 会话构造（sleep.test.mjs:16 的 ses()；问卷字段全空 = 两击跳过）
    func ses(_ start: Date, _ end: Date,
             feel: Int? = nil, wakes: Int? = nil, latency: SleepLatency? = nil,
             dayOverride: String? = nil) -> SleepSession {
        SleepSession(start: start, end: end, feel: feel, wakeCount: wakes,
                     latency: latency,
                     dayOverride: dayOverride.flatMap { DayKey(rawValue: $0) })
    }

    func key(_ raw: String) -> DayKey { DayKey(rawValue: raw)! }

    // MARK: — 归属规则（sleep.test.mjs:19-29，10 项）—

    @Test func ownershipMinus4Hours() {
        #expect(SleepEngine.sleepDayKey(end: ts(9, 7, 6, 52), calendar: cal) == key("2026-09-07"),
                "23:40–06:52 → 归属醒来当天 9/7")
        #expect(SleepEngine.sleepDayKey(end: ts(9, 7, 8, 0), calendar: cal) == key("2026-09-07"),
                "00:30 才睡 08:00 醒 → 同样归属 9/7（昨夜）")
        #expect(SleepEngine.sleepDayKey(end: ts(9, 7, 5, 30), calendar: cal) == key("2026-09-07"),
                "05:30 醒来的早鸟也归属醒来当天 9/7")
        #expect(SleepEngine.sleepDayKey(end: ts(9, 7, 4, 0), calendar: cal) == key("2026-09-07"),
                "04:00 整醒来（−4h=00:00）仍归属当天")
        #expect(SleepEngine.sleepDayKey(end: ts(9, 7, 3, 59), calendar: cal) == key("2026-09-06"),
                "03:59 醒来（−4h=23:59）归属前一晚")
        #expect(SleepEngine.sleepDayKey(end: ts(9, 7, 12, 0), calendar: cal) == key("2026-09-07"),
                "中午 12:00 醒来仍归属当天")
        #expect(SleepEngine.sleepDayKey(end: ts(9, 7, 18, 30), calendar: cal) == key("2026-09-07"),
                "18:30 醒（−4h=14:30）仍归属当天")
        #expect(SleepEngine.sleepDayKey(end: ts(9, 8, 0, 30), calendar: cal) == key("2026-09-07"),
                "凌晨 00:30 结束的短睡 → 归属前一天（−4h 落在 9/7）")
        #expect(SleepEngine.sessionDay(
            ses(ts(9, 6, 23, 40), ts(9, 7, 6, 52), dayOverride: "2026-09-05"),
            calendar: cal) == key("2026-09-05"),
                "手动调整归属优先于自动规则")
        #expect(SleepEngine.sessionDay(
            ses(ts(9, 6, 23, 40), ts(9, 7, 6, 52)), calendar: cal) == key("2026-09-07"),
                "未调整时用自动规则")
    }

    // MARK: — 分段夜取最长（sleep.test.mjs:31-38，2 项）—

    @Test func splitNightPicksLongest() {
        let splitNight = [
            ses(ts(9, 6, 23, 0), ts(9, 7, 1, 0), dayOverride: "2026-09-07"),  // 2h 前半段，手动归到 9/7
            ses(ts(9, 7, 2, 0), ts(9, 7, 8, 0)),                                // 6h 后半段，自动归 9/7
        ]
        let main = SleepEngine.nightForDay(splitNight, day: key("2026-09-07"), calendar: cal)
        #expect(main?.start == ts(9, 7, 2, 0) && main?.durationSeconds == 6 * 3600,
                "同一天两段夜取最长（6h）作为主睡眠")
        #expect(SleepEngine.nightForDay([], day: key("2026-09-07"), calendar: cal) == nil,
                "空列表返回 nil")
    }

    // MARK: — 午睡识别（sleep.test.mjs:40-47，7 项）—

    @Test func napDetection() {
        #expect(SleepEngine.isNap(start: ts(9, 7, 14, 0), end: ts(9, 7, 14, 40), calendar: cal),
                "14:00 睡 40 分钟 → 午睡")
        #expect(SleepEngine.isNap(start: ts(9, 7, 9, 0), end: ts(9, 7, 11, 0), calendar: cal),
                "09:00 睡 2 小时 → 午睡")
        #expect(!SleepEngine.isNap(start: ts(9, 7, 9, 0), end: ts(9, 7, 12, 30), calendar: cal),
                "09:00 睡 3.5 小时 → 不算午睡（≥3h）")
        #expect(!SleepEngine.isNap(start: ts(9, 7, 8, 59), end: ts(9, 7, 9, 29), calendar: cal),
                "09:00 前开始 → 不算午睡")
        #expect(!SleepEngine.isNap(start: ts(9, 7, 18, 0), end: ts(9, 7, 18, 30), calendar: cal),
                "18:00 整开始 → 不算午睡")
        #expect(SleepEngine.isNap(start: ts(9, 7, 17, 30), end: ts(9, 7, 19, 0), calendar: cal),
                "17:30 睡 1.5 小时 → 午睡")
        #expect(!SleepEngine.isNap(start: ts(9, 6, 23, 40), end: ts(9, 7, 6, 52), calendar: cal),
                "夜晚长睡 → 主睡眠")
    }

    // MARK: — 某天概要（sleep.test.mjs:49-63，6 项；A3 口径拆为 nightForDay/napsForDay）—

    /// sleep.test.mjs:50-54 的 sessions：9/6 与 9/7 各一夜 + 9/7 一段午睡
    var sampleSessions: [SleepSession] {
        [
            ses(ts(9, 5, 23, 30), ts(9, 6, 6, 30), feel: 4),  // 归属 9/6，时长 7h
            ses(ts(9, 6, 23, 40), ts(9, 7, 6, 52), feel: 5),  // 归属 9/7（昨晚），时长 7h12m
            ses(ts(9, 7, 14, 0), ts(9, 7, 14, 30)),           // 9/7 午睡
        ]
    }

    @Test func daySummaryViaNightAndNaps() {
        let night7 = SleepEngine.nightForDay(sampleSessions, day: key("2026-09-07"), calendar: cal)
        #expect(night7?.feel == 5, "9/7 的主睡眠是昨晚那段")
        #expect(night7?.durationSeconds == 7.2 * 3600, "昨晚时长 7h12m")
        #expect(night7?.start == ts(9, 6, 23, 40) && night7?.end == ts(9, 7, 6, 52),
                "就寝/起床时刻正确")
        let naps7 = SleepEngine.napsForDay(sampleSessions, day: key("2026-09-07"), calendar: cal)
        #expect(naps7.count == 1
                && naps7.reduce(0.0) { $0 + SleepEngine.durationSeconds($1) } == 30 * 60,
                "9/7 有 1 段 30 分钟午睡")
        #expect(SleepEngine.nightForDay(sampleSessions, day: key("2026-09-06"), calendar: cal)?.feel == 4,
                "9/6 的主睡眠是前一晚")
        #expect(SleepEngine.nightForDay(sampleSessions, day: key("2026-09-04"), calendar: cal) == nil
                && SleepEngine.napsForDay(sampleSessions, day: key("2026-09-04"), calendar: cal).isEmpty,
                "没记录的日子返回空概要")
    }

    // MARK: — 就寝锚点（sleep.test.mjs:65-68，3 项）—

    @Test func bedtimeAnchorScale() {
        #expect(SleepEngine.bedtimeAnchorMinutes(ts(9, 6, 23, 40), calendar: cal) == 340,
                "23:40 → 18:00 起 340 分钟")
        #expect(SleepEngine.bedtimeAnchorMinutes(ts(9, 7, 0, 10), calendar: cal) == 370,
                "00:10 → 370 分钟（与 23:40 相邻可比）")
        #expect(SleepEngine.anchorToBedtimeHM(340) == "23:40"
                && SleepEngine.anchorToBedtimeHM(370) == "00:10",
                "锚点还原 HH:MM")
    }

    // MARK: — 睡眠分：时长40 + 规律30 + 感受20 + 连续10（sleep.test.mjs:70-82，8 项）—

    @Test func scoreAnchors() {
        let goal = 480
        let anchor330: Double? = 330  // sleep.test.mjs:73 显式传入 medAnchor=330
        let s1 = ses(ts(9, 6, 23, 30), ts(9, 7, 7, 30))  // 睡满 8h，就寝 23:30
        #expect(SleepEngine.score(s1, goalMinutes: goal, medAnchorMinutes: anchor330, calendar: cal) == 93,
                "两击满时长 + 参照就寝 = 93（中性感受 13 + 连续 10）")
        let s2 = ses(ts(9, 6, 23, 30), ts(9, 7, 7, 30), feel: 5)
        #expect(SleepEngine.score(s2, goalMinutes: goal, medAnchorMinutes: anchor330, calendar: cal) == 100,
                "感受极好 → 100")
        let s3 = ses(ts(9, 6, 23, 30), ts(9, 7, 3, 30))  // 只睡 4h
        #expect(SleepEngine.score(s3, goalMinutes: goal, medAnchorMinutes: anchor330, calendar: cal) == 73,
                "睡 4h：时长分 20 + 规律 30 + 中性 23 → 73")
        let s4 = ses(ts(9, 6, 3, 0), ts(9, 7, 11, 0))  // 凌晨 3 点才睡，也睡满 8h
        #expect(SleepEngine.score(s4, goalMinutes: goal, medAnchorMinutes: anchor330, calendar: cal) == 63,
                "凌晨 3 点就寝（偏差 210 分）规律分归零 → 63")
        #expect(SleepEngine.score(ses(ts(9, 6, 23, 30), ts(9, 7, 7, 30), wakes: 2, latency: .slow),
                                  goalMinutes: goal, medAnchorMinutes: anchor330, calendar: cal) == 85,
                "夜醒 2 次 + 入睡慢：连续分 10−5−3=2 → 85")
        #expect(SleepEngine.score(ses(ts(9, 6, 23, 30), ts(9, 7, 7, 30), wakes: 9),
                                  goalMinutes: goal, medAnchorMinutes: anchor330, calendar: cal) == 86,
                "夜醒次数封顶 3 档（连续分 2.5）→ 86")
        #expect(SleepEngine.score(ses(ts(9, 6, 23, 30), ts(9, 7, 7, 30), feel: 2, wakes: 1),
                                  goalMinutes: goal, medAnchorMinutes: anchor330, calendar: cal) == 86,
                "感受差 + 夜醒 1 次（85.5 舍入）→ 86")
        // medAnchor 未传 → nil 走 330 默认（sleepMath.js:98；sleep.test.mjs:73 传 330 锁锚）
        #expect(SleepEngine.score(s1, goalMinutes: goal, medAnchorMinutes: nil, calendar: cal) == 93,
                "medAnchor 未传 → 默认 330 同锚同分")
    }

    // MARK: — 阶段统计（sleep.test.mjs:84-96，10 项；sleepStats → periodSummary）—

    /// 近 7 天（含今天 9/7）区间 = lastNDays(7, NOW) 的等价物
    var last7Span: DateSpan { DateSpan(startDay: key("2026-09-01"), endDay: key("2026-09-07")) }

    @Test func periodSummaryStats() {
        let stats = SleepEngine.periodSummary(sampleSessions, in: last7Span,
                                              goalMinutes: 480, calendar: cal)
        #expect(stats.nights == 2, "近 7 天只统计到 2 晚记录")
        #expect(stats.avgMinutes == (420 + 432) / 2, "平均时长按已记录晚数平均")
        #expect(stats.debtMinutes == (480 - 420) + (480 - 432), "睡眠债 = 各晚缺口之和 → 108 分钟")
        #expect(stats.madMinutes == 5, "两晚就寝 23:30/23:40 的 MAD = 5 分钟")
        #expect(stats.series.count == 7
                && stats.series.filter { $0.durationMinutes == nil }.count == 5,
                "7 天序列含 5 个缺记 nil")
        #expect(stats.series[6].day == key("2026-09-07") && stats.series[6].durationMinutes == 432,
                "序列最后一位是今天（昨晚 7h12m = 432 分）")
        #expect(stats.avgScore == 93, "平均分 (91+94)/2 ≈ 93（区间中位锚 335）")
    }

    @Test func periodSummaryEmptySemantics() {
        let empty = SleepEngine.periodSummary([], in: last7Span,
                                              goalMinutes: 0, calendar: cal)
        #expect(empty.goalMinutes == SleepEngine.defaultGoalMinutes,
                "目标非法时回退默认 8h")
        #expect(empty.nights == 0 && empty.avgMinutes == nil && empty.debtMinutes == 0,
                "无数据不崩溃（缺记夜不进均值不记债）")
        #expect(empty.medBedtimeHM == "23:30", "无数据时中位就寝回退 23:30")
    }

    // MARK: — 边界（sleep.test.mjs:98-101，3 项）—

    @Test func edgeCases() {
        #expect(SleepEngine.durationSeconds(
            ses(Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 0))) == 0,
                "异常数据时长不为负")
        #expect(SleepEngine.nightForDay(sampleSessions, day: key("2026-09-08"), calendar: cal) == nil,
                "未来日期无睡眠")
        #expect(SleepEngine.napsForDay(sampleSessions, day: key("2026-09-07"), calendar: cal).count == 1,
                "午睡按归属日取到")
    }
}

// MARK: - 手动补录 / 编辑（lifttime js/sleep.js:171-279 sessionSheet 的 Core 语义）
//
// 补录会话与两击会话同一 SleepSession 形状、同一读取口径（isNap/sessionDay/
// score/periodSummary 现算）——本组用例验证：构造/校验入口 makeSession、
// 合法补录进入当晚夜睡眠、白天短补录判午睡、跨零点归属、end≤start 拒绝、
// dayOverride 生效与等值收纳（sleep.js:276）、补录会话参与评分与阶段统计。

@Suite("SleepEngine · 手动补录")
struct SleepManualEntryTests {

    let cal = DayCalendar.utc8()

    func ts(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return cal.calendar.date(from: c)!
    }

    /// 两击路径的等价构造（对照组：与 makeSession 产物逐字段同形）。
    func ses(_ start: Date, _ end: Date, feel: Int? = nil, wakeCount: Int? = nil,
             latency: SleepLatency? = nil) -> SleepSession {
        SleepSession(start: start, end: end, feel: feel, wakeCount: wakeCount, latency: latency)
    }

    func key(_ raw: String) -> DayKey { DayKey(rawValue: raw)! }

    /// Result 拆包助手（失败即记 issue 并中止断言链）。
    func unwrap(_ result: Result<SleepSession, SleepEntryError>, _ what: String) -> SleepSession? {
        guard case .success(let session) = result else {
            Issue.record("\(what)：应构造成功，实际 \(result)")
            return nil
        }
        return session
    }

    // MARK: — 构造与校验（sleep.js:253-256 的两条 toast 语义 + 结构性口径）—

    @Test func makeSessionValidFullFields() {
        let session = unwrap(SleepEngine.makeSession(
            start: ts(10, 4, 22, 30), end: ts(10, 5, 6, 30),
            feel: 4, wakeCount: 1, latency: .fast,
            note: "  睡前喝了咖啡  ", calendar: cal), "合法全字段补录")
        #expect(session?.start == ts(10, 4, 22, 30) && session?.end == ts(10, 5, 6, 30),
                "时间原样保留（跨零点合法）")
        #expect(session?.feel == 4 && session?.wakeCount == 1 && session?.latency == .fast,
                "问卷三字段选填保留")
        #expect(session?.note == "睡前喝了咖啡", "note 修剪首尾空白（makeBlock 同款）")
        #expect(session?.dayOverride == nil, "补记不预设手动归属（走 -4h 自动规则）")
    }

    @Test func makeSessionEmptyFieldsLikeTwoTap() {
        let session = unwrap(SleepEngine.makeSession(
            start: ts(10, 4, 23, 0), end: ts(10, 5, 7, 0),
            feel: nil, wakeCount: nil, latency: nil, calendar: cal), "全字段留空补录")
        // 逐字段比对（id 是随机的，Equatable 全量比较会因 id 不同而失败）
        #expect(session?.start == ts(10, 4, 23, 0) && session?.end == ts(10, 5, 7, 0)
                && session?.feel == nil && session?.wakeCount == nil
                && session?.latency == nil && session?.note == nil
                && session?.dayOverride == nil,
                "全跳过补录与两击跳过会话逐字段同形（读取侧无从区分来源）")
    }

    @Test func entryErrorBounds() {
        #expect(SleepEngine.entryError(start: ts(10, 4, 23, 0), end: ts(10, 4, 23, 0))
                    == .endNotAfterStart, "end == start 拒绝")
        #expect(SleepEngine.entryError(start: ts(10, 5, 7, 0), end: ts(10, 4, 23, 0))
                    == .endNotAfterStart, "end < start 拒绝")
        #expect(SleepEngine.entryError(start: ts(10, 4, 23, 0), end: ts(10, 4, 23, 0) + 30)
                    == .tooShort, "不足 1 分钟拒绝（sleep.js:255）")
        #expect(SleepEngine.entryError(start: ts(10, 4, 23, 0), end: ts(10, 4, 23, 0) + 60) == nil,
                "恰 1 分钟合法（严格小于才拒）")
        #expect(SleepEngine.entryError(start: ts(10, 3, 23, 0), end: ts(10, 4, 23, 0) + 3600)
                    == .over24Hours, "超过 24 小时拒绝（sleep.js:256 + 净化域）")
        #expect(SleepEngine.entryError(start: ts(10, 3, 23, 0), end: ts(10, 4, 23, 0)) == nil,
                "恰 24 小时合法（≤24h）")
        if case .failure(let error) = SleepEngine.makeSession(start: ts(10, 5, 8, 0),
                                                              end: ts(10, 5, 7, 0),
                                                              feel: nil, wakeCount: nil,
                                                              latency: nil, calendar: cal) {
            #expect(error == .endNotAfterStart, "makeSession 与 entryError 同口径")
        } else {
            Issue.record("end ≤ start 应构造失败")
        }
    }

    // MARK: — 归属与午睡判定（与两击会话同一读取路径）—

    @Test func validNightEntersThatNight() {
        let session = unwrap(SleepEngine.makeSession(
            start: ts(10, 4, 22, 30), end: ts(10, 5, 6, 30),
            feel: nil, wakeCount: nil, latency: nil, calendar: cal), "夜睡补录")
        guard let session else { return }
        #expect(SleepEngine.sessionDay(session, calendar: cal) == key("2026-10-05"),
                "06:30 醒（−4h = 02:30）→ 归属 10/5「昨晚」")
        let night = SleepEngine.nightForDay([session], day: key("2026-10-05"), calendar: cal)
        #expect(night?.sessionID == session.id && night?.durationSeconds == 8 * 3600,
                "合法补录进入当晚夜睡眠（nightForDay 一视同仁）")
        #expect(SleepEngine.napsForDay([session], day: key("2026-10-05"), calendar: cal).isEmpty,
                "8h 夜睡不判午睡")
    }

    @Test func daytimeShortEntersNaps() {
        let session = unwrap(SleepEngine.makeSession(
            start: ts(10, 5, 13, 0), end: ts(10, 5, 13, 50),
            feel: nil, wakeCount: nil, latency: nil, calendar: cal), "白天短补录")
        guard let session else { return }
        #expect(SleepEngine.isNap(start: session.start, end: session.end, calendar: cal),
                "13:00 开始 50 分钟 → 自动判午睡（无需来源标志）")
        let naps = SleepEngine.napsForDay([session], day: key("2026-10-05"), calendar: cal)
        #expect(naps.map(\.id) == [session.id], "进入当日午睡列表")
        #expect(SleepEngine.nightForDay([session], day: key("2026-10-05"), calendar: cal) == nil,
                "纯午睡不顶替当晚主睡眠")
    }

    @Test func crossMidnightOwnership() {
        let session = unwrap(SleepEngine.makeSession(
            start: ts(10, 4, 22, 0), end: ts(10, 5, 0, 30),
            feel: nil, wakeCount: nil, latency: nil, calendar: cal), "跨零点短补录")
        #expect(session.map { SleepEngine.sessionDay($0, calendar: cal) } == key("2026-10-04"),
                "22:00 睡 00:30 醒（−4h 落 10/4）→ 拉回睡前那个晚上（sleepMath.js:12-18）")
    }

    @Test func dayOverrideAndAutoCollapse() {
        let overridden = unwrap(SleepEngine.makeSession(
            start: ts(10, 4, 22, 0), end: ts(10, 5, 6, 0),
            feel: nil, wakeCount: nil, latency: nil,
            dayOverride: key("2026-10-03"), calendar: cal), "手动归属补录")
        #expect(overridden?.dayOverride == key("2026-10-03")
                && overridden.map({ SleepEngine.sessionDay($0, calendar: cal) }) == key("2026-10-03"),
                "dayOverride 优先于 -4h 自动规则")
        let same = unwrap(SleepEngine.makeSession(
            start: ts(10, 4, 22, 0), end: ts(10, 5, 6, 0),
            feel: nil, wakeCount: nil, latency: nil,
            dayOverride: key("2026-10-05"), calendar: cal), "等值手动归属")
        #expect(same?.dayOverride == nil
                && same.map({ SleepEngine.sessionDay($0, calendar: cal) }) == key("2026-10-05"),
                "手动归属 == 自动归属时收纳为 nil（sleep.js:276 同语义）")
    }

    // MARK: — 评分与阶段统计一视同仁（补录 vs 两击同形同分）—

    @Test func manualScoresSameAsTwoTap() {
        let manual = unwrap(SleepEngine.makeSession(
            start: ts(9, 6, 23, 30), end: ts(9, 7, 7, 30),
            feel: 5, wakeCount: nil, latency: nil, calendar: cal), "补录满时长会话")
        guard let manual else { return }
        let twoTap = ses(ts(9, 6, 23, 30), ts(9, 7, 7, 30), feel: 5)
        #expect(SleepEngine.score(manual, goalMinutes: 480, medAnchorMinutes: 330,
                                  calendar: cal) == 100,
                "补录会话命中已知锚点 100（对照 scoreAnchors 的两击 s2）")
        #expect(SleepEngine.score(manual, goalMinutes: 480, medAnchorMinutes: 330,
                                  calendar: cal)
                == SleepEngine.score(twoTap, goalMinutes: 480, medAnchorMinutes: 330,
                                     calendar: cal),
                "同字段补录与两击会话同分")
    }

    @Test func manualSessionsFeedPeriodSummary() {
        let night = unwrap(SleepEngine.makeSession(
            start: ts(9, 4, 23, 30), end: ts(9, 5, 6, 30),
            feel: 4, wakeCount: nil, latency: nil, calendar: cal), "补录夜睡")
        let nap = unwrap(SleepEngine.makeSession(
            start: ts(9, 5, 14, 0), end: ts(9, 5, 15, 0),
            feel: nil, wakeCount: nil, latency: nil, calendar: cal), "补录午睡")
        guard let night, let nap else { return }
        let stats = SleepEngine.periodSummary([night, nap],
                                              in: DateSpan(startDay: key("2026-09-01"),
                                                           endDay: key("2026-09-07")),
                                              goalMinutes: 480, calendar: cal)
        #expect(stats.nights == 1, "补录夜睡计入已记录晚数")
        #expect(stats.avgMinutes == 420, "7h 补录夜 = 420 分进均值")
        #expect(stats.debtMinutes == 60, "缺口 60 分记入睡眠债")
        #expect(stats.napMinutes == 60, "补录午睡计入区间午睡分钟")
        #expect(stats.series.first { $0.day == key("2026-09-05") }?.durationMinutes == 420
                && stats.series.first { $0.day == key("2026-09-05") }?.score != nil,
                "补录夜出现在逐夜序列且带区间中位锚分数")
        #expect(stats.missingDays.count == 6, "其余 6 晚缺记（不进均值不记债）")
    }

    // MARK: — 归属预览（sheet 实时文案数据源）—

    @Test func entryPreviewSemantics() {
        let night = SleepEngine.entryPreview(start: ts(10, 4, 22, 0), end: ts(10, 5, 0, 30),
                                             dayOverride: nil, calendar: cal)
        #expect(night == SleepEntryPreview(day: key("2026-10-04"), isNap: false),
                "跨零点夜睡预览：归属 10/4 · 夜睡")
        let nap = SleepEngine.entryPreview(start: ts(10, 5, 14, 0), end: ts(10, 5, 14, 40),
                                           dayOverride: nil, calendar: cal)
        #expect(nap == SleepEntryPreview(day: key("2026-10-05"), isNap: true),
                "白天短睡预览：归属当天 · 午睡")
        let overridden = SleepEngine.entryPreview(start: ts(10, 5, 14, 0), end: ts(10, 5, 14, 40),
                                                  dayOverride: key("2026-10-01"), calendar: cal)
        #expect(overridden == SleepEntryPreview(day: key("2026-10-01"), isNap: true),
                "dayOverride 优先：预览日随手动档走（午睡判定仍按起止时刻）")
    }
}
