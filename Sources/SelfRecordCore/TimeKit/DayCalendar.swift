import Foundation

/// `Calendar + TimeZone` 注入封装（design.md §3.0 TimeKit 职责；§2 依赖规则末条）。
///
/// 所有引擎函数显式接收 `DayCalendar`，不隐式依赖 `TimeZone.current`——
/// 测试锚定固定时区（§8 约定 2：`TimeZone(secondsFromGMT: 8 * 3600)`）。
///
/// 默认历法固定为公历（`Calendar(identifier: .gregorian)`）：`.current` 会随用户
/// 区域设置取到非公历历法（佛历/和历），日键会出非四位公元年——这是骨架裁决，
/// 见 design.md §12。需要特殊历法行为的调用方显式注入。
public struct DayCalendar: Sendable, Equatable {
    public var calendar: Calendar
    public var timeZone: TimeZone

    public init(calendar: Calendar = Calendar(identifier: .gregorian),
                timeZone: TimeZone = .current) {
        var adjusted = calendar
        adjusted.timeZone = timeZone
        self.calendar = adjusted
        self.timeZone = timeZone
    }

    /// 测试锚定时区 UTC+8（§8 约定 2；lifttime「固定 NOW + 本地构造」手法的等价物）。
    public static func utc8() -> DayCalendar {
        guard let tz = TimeZone(secondsFromGMT: 8 * 3600) else {
            preconditionFailure("TimeZone(secondsFromGMT: 28800) 恒存在")
        }
        return DayCalendar(timeZone: tz)
    }

    // MARK: - 日键 ↔ 日期

    /// 该日期所在日的键（startOfDay 语义）。
    public func dayKey(for date: Date) -> DayKey {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let raw = String(format: "%04d-%02d-%02d",
                         c.year ?? 0, c.month ?? 0, c.day ?? 0)
        // 正常历法组件不会拆出非法键；万一拆出（历法配置异常）退化为宽松 DayKey，
        // 由净化管线兜底——引擎路径以能表示为先。
        return DayKey(rawValue: raw) ?? DayKey(fromUnchecked: raw)
    }

    /// 该日的 00:00 时刻；键本身非法 → nil。
    public func date(of day: DayKey) -> Date? {
        guard let parts = DayKey.parse(day.rawValue) else { return nil }
        var components = DateComponents()
        components.year = parts.year
        components.month = parts.month
        components.day = parts.day
        return calendar.date(from: components)
    }

    /// 日键 + n 天（跨月/跨年正确）；非法键 → nil。
    public func addingDays(_ days: Int, to day: DayKey) -> DayKey? {
        guard let start = date(of: day),
              let shifted = calendar.date(byAdding: .day, value: days, to: start)
        else { return nil }
        return dayKey(for: shifted)
    }

    /// 键是否落在区间内（DateSpan 含首尾）。
    public func contains(_ day: DayKey, in span: DateSpan) -> Bool {
        span.contains(day)
    }

    // MARK: - 时刻组件（diet 晚加餐 hour≥21、sleep 就寝锚分钟数等判定用）

    public func hour(of date: Date) -> Int {
        calendar.component(.hour, from: date)
    }

    public func minute(of date: Date) -> Int {
        calendar.component(.minute, from: date)
    }

    /// 自当日 00:00 起的分钟数（含秒折算向下取整）。
    public func minutesSinceMidnight(of date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0) + ((c.second ?? 0) >= 30 ? 1 : 0)
    }
}

extension DayKey {
    /// 仅限 DayCalendar.dayKey(for:) 内部兜底路径：绕过构造校验持有宽松值
    /// （与宽松解码同一理由——能表示优先，合法性由净化管线把关）。
    init(fromUnchecked raw: String) {
        self.rawValue = raw
    }
}
