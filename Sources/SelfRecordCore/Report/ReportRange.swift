import Foundation

// MARK: - 阶段报告区间（design.md §3.6；lifttime reportBuilder.js:12-40）

/// 阶段报告预设档（lifttime REPORT_RANGES 的 key：day/week/month）。
/// 自定义区间走 `custom(startDay:endDay:)`，含首尾、最长 366 天。
public enum ReportPreset: String, Codable, Sendable, CaseIterable, Hashable {
    case day      // 过去一天
    case week     // 过去一周
    case month    // 过去一个月

    public var label: String {
        switch self {
        case .day: return "过去一天"
        case .week: return "过去一周"
        case .month: return "过去一个月"
        }
    }
}

/// 报告区间：预设或自定义起止换算的结果（含首尾两日）。
///
/// 语义 = lifttime reportBuilder.js:19-40 reportRange——
/// - 三档预设以「今天」为末日：day = 今天单日；week = 近 7 天含今天；
///   month = 近 30 天含今天（reportBuilder.js:21-29）；
/// - 自定义 = startDay…endDay 闭区间（lifttime 的 end 为末日 24 点，
///   Swift 侧以 DateSpan 含首尾表达同一语义），天数 = 末日 − 首日 + 1
///   （reportBuilder.test.mjs「自定义区间含首尾两天」：9/1–9/7 = 7 天）；
/// - 自定义非法（end < start / 超 366 天）→ nil（reportBuilder.js:33-35）。
public struct ReportRange: Codable, Sendable, Equatable, Hashable {
    /// 区间（含首尾）
    public var span: DateSpan
    /// 区间天数（含首尾）
    public var dayCount: Int
    /// 展示名：预设档带默认名，自定义为「9/1 – 9/7」（lifttime reportBuilder.js:37）
    public var label: String

    public init(span: DateSpan, dayCount: Int, label: String) {
        self.span = span
        self.dayCount = dayCount
        self.label = label
    }
}

/// 自定义区间上限（design.md §3.6「自定义 ≤366 天」= lifttime reportBuilder.js:35）。
public let reportMaxCustomDays = 366

/// 区间自定义参数（start/end 缺一即非法 → reportRange 返回 nil，
/// lifttime reportBuilder.js:30 `custom && custom.startKey && custom.endKey`）。
public struct ReportCustomRange: Codable, Sendable, Equatable, Hashable {
    public var startDay: DayKey
    public var endDay: DayKey

    public init(startDay: DayKey, endDay: DayKey) {
        self.startDay = startDay
        self.endDay = endDay
    }
}

extension ReportEngine {

    /// 区间换算：预设档或自定义 → ReportRange；非法 → nil。
    ///
    /// - 预设档锚定 `now` 所在日为末日（day/week/month 见 ReportRange 注释）；
    /// - 自定义：endDay < startDay → nil；天数（含首尾）> 366 → nil；
    ///   label 为「M/D – M/D」（月/日不补零，lifttime reportBuilder.js:37）。
    public static func reportRange(preset: ReportPreset,
                                   now: Date, calendar: DayCalendar) -> ReportRange? {
        let today = calendar.dayKey(for: now)
        switch preset {
        case .day:
            return ReportRange(span: DateSpan(startDay: today, endDay: today),
                               dayCount: 1,
                               label: "过去一天（今天）")
        case .week:
            guard let start = calendar.addingDays(-6, to: today) else { return nil }
            return ReportRange(span: DateSpan(startDay: start, endDay: today),
                               dayCount: 7,
                               label: "过去一周")
        case .month:
            guard let start = calendar.addingDays(-29, to: today) else { return nil }
            return ReportRange(span: DateSpan(startDay: start, endDay: today),
                               dayCount: 30,
                               label: "过去一个月")
        }
    }

    /// 自定义区间（含首尾；end 早于 start 或超 366 天 → nil）。
    public static func reportRange(custom: ReportCustomRange,
                                   calendar: DayCalendar) -> ReportRange? {
        guard custom.endDay.rawValue >= custom.startDay.rawValue else { return nil }
        guard let days = inclusiveDayCount(from: custom.startDay, to: custom.endDay,
                                           calendar: calendar),
              days <= reportMaxCustomDays
        else { return nil }
        let label = "\(monthDay(custom.startDay, calendar: calendar)) – "
            + "\(monthDay(custom.endDay, calendar: calendar))"
        return ReportRange(span: DateSpan(startDay: custom.startDay, endDay: custom.endDay),
                           dayCount: days,
                           label: label)
    }

    /// 含首尾天数：start…end 逐日步进计数（加减日期跨月/跨年由 DayCalendar 保证）。
    /// 起点无法解析等异常 → nil。
    static func inclusiveDayCount(from start: DayKey, to end: DayKey,
                                  calendar: DayCalendar) -> Int? {
        guard calendar.date(of: start) != nil else { return nil }
        var count = 1
        var cursor = start
        while cursor.rawValue < end.rawValue {
            guard let next = calendar.addingDays(1, to: cursor),
                  next.rawValue > cursor.rawValue
            else { return nil }
            cursor = next
            count += 1
            // 防御：异常历法下步进失效不应无限循环
            if count > reportMaxCustomDays + 1 { return nil }
        }
        return count
    }

    /// 「9/7」式月/日展示（不补零，lifttime reportBuilder.js:37 同形）。
    static func monthDay(_ day: DayKey, calendar: DayCalendar) -> String {
        guard let date = calendar.date(of: day) else { return day.rawValue }
        let c = calendar.calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }
}
