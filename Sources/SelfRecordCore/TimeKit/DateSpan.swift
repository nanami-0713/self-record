import Foundation

/// 区间值类型（design.md §2.1 冻结物 B 的区间载体）：**含首尾两日**。
/// report / budget / diet 的区间聚合 API 统一用它。
public struct DateSpan: Hashable, Codable, Sendable {
    public var startDay: DayKey
    public var endDay: DayKey

    public init(startDay: DayKey, endDay: DayKey) {
        self.startDay = startDay
        self.endDay = endDay
    }

    /// start ≤ end 才有效（report 区间换算「自定义含首尾」语义的前提）。
    public var isValid: Bool { startDay.rawValue <= endDay.rawValue }

    /// 键是否落在区间内（含首尾；字符串序 = 日期序，yyyy-MM-dd 格式保证）。
    public func contains(_ day: DayKey) -> Bool {
        startDay.rawValue <= day.rawValue && day.rawValue <= endDay.rawValue
    }
}
