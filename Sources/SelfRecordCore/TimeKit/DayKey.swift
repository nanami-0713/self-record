import Foundation

/// 「yyyy-MM-dd」日键（design.md §4；等价 lifttime 的 dayKey）。
///
/// 语义 = `Calendar.startOfDay`；跨时区运算必须经由注入的 `DayCalendar`，不隐式依赖宿主时区。
///
/// 解码口径（§4 净化管线第 2 步，实测依据 §13 v3）：
/// - `init?(rawValue:)` 是**构造侧**校验入口（格式 + 真实日期）；
/// - `init(from:)` 是**宽松**解码入口——任何字符串都解得进来，不承担解码拒绝。
///   非法值的处置（如 `dayOverride` 归 nil）由 `BackupSanitizer` 在解码后的值上
///   重跑构造侧校验完成。实测强校验 init 走 Codable 合成路径会把「仅 dayOverride
///   非法」的会话整条丢掉，违背「字段归 null、保留整条」语义——故必须双入口。
public struct DayKey: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String

    /// 构造侧校验：`yyyy-MM-dd` 且为真实存在的公历日期（2026-02-30 → nil）。
    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// 由日期按注入历法取所在日的键（startOfDay 语义）。
    public init(_ date: Date, calendar: DayCalendar) {
        self = calendar.dayKey(for: date)
    }

    /// 宽松解码（§4 管线 2）：接受任意字符串，不校验。
    /// 非法值的净化在 `BackupSanitizer` 值上重跑 `isValid` 完成。
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// `yyyy-MM-dd` 且年月日真实存在（公历校验，回读比对防 02-30 溢出归一化）。
    public static func isValid(_ string: String) -> Bool {
        guard let parts = parse(string) else { return false }
        var utcGregorian = Calendar(identifier: .gregorian)
        utcGregorian.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = parts.year
        components.month = parts.month
        components.day = parts.day
        guard let date = utcGregorian.date(from: components) else { return false }
        let back = utcGregorian.dateComponents([.year, .month, .day], from: date)
        return back.year == parts.year && back.month == parts.month && back.day == parts.day
    }

    /// 拆 `yyyy-MM-dd`（严格 10 位、ASCII 数字、连字符），不合形状 → nil。
    static func parse(_ string: String) -> (year: Int, month: Int, day: Int)? {
        let chars = Array(string.utf8)
        guard chars.count == 10,
              chars[4] == 0x2D, chars[7] == 0x2D  // '-'
        else { return nil }
        func digits(_ range: Range<Int>) -> Int? {
            var value = 0
            for i in range {
                let c = chars[i]
                guard c >= 0x30, c <= 0x39 else { return nil }
                value = value * 10 + Int(c - 0x30)
            }
            return value
        }
        guard let year = digits(0..<4),
              let month = digits(5..<7),
              let day = digits(8..<10),
              (1...12).contains(month),
              (1...31).contains(day)
        else { return nil }
        return (year, month, day)
    }
}
