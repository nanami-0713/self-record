import Testing
import Foundation
@testable import SelfRecordCore

// MARK: - 基础层测试：TimeKit（DayKey / DayCalendar / DateSpan / Formatting）
//
// 本文件属基础层（骨架冻结物 A 的测试面），模块工程师不改（§3.0 / §8 约定 3）。
// 时间锚定固定时区 UTC+8（§8 约定 2），绝不依赖宿主时区。

// 便捷锚：UTC+8 历法
private let cal = DayCalendar.utc8()

/// 构造 UTC+8 下的本地时刻（等效 lifttime「固定 NOW + 本地构造 Date」手法）。
private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    cal.date(of: DayKey(rawValue: String(format: "%04d-%02d-%02d", y, mo, d))!)!
        .addingTimeInterval(TimeInterval(h * 3600 + mi * 60))
}

@Test func dayKeyAcceptsValidDates() {
    #expect(DayKey(rawValue: "2026-10-06") != nil)
    #expect(DayKey(rawValue: "2024-02-29") != nil)   // 闰年
    #expect(DayKey(rawValue: "0001-01-01") != nil)
}

@Test func dayKeyRejectsInvalidRawValues() {
    #expect(DayKey(rawValue: "2026-02-30") == nil)   // 非真实日期（溢出归一化防住）
    #expect(DayKey(rawValue: "2023-02-29") == nil)
    #expect(DayKey(rawValue: "2026/09/06") == nil)   // 斜杠格式（§13 v3 用例）
    #expect(DayKey(rawValue: "2026-1-6") == nil)     // 非两位补零
    #expect(DayKey(rawValue: "20261006") == nil)
    #expect(DayKey(rawValue: "") == nil)
    #expect(DayKey(rawValue: "2026-13-01") == nil)   // 月越界
    #expect(DayKey(rawValue: "2026-00-10") == nil)
    #expect(DayKey(rawValue: "2026-10-32") == nil)
    #expect(DayKey(rawValue: "２０２６-１０-０６") == nil)  // 全角数字
}

@Test func dayKeyFromDateUsesInjectedCalendar() {
    // UTC+8 的 23:30 与次日 00:30：
    // 23:30 属当天；00:30 属次日——归属只由注入时区决定，与宿主时区无关
    #expect(cal.dayKey(for: date(2026, 10, 6, 23, 30)).rawValue == "2026-10-06")
    #expect(cal.dayKey(for: date(2026, 10, 7, 0, 30)).rawValue == "2026-10-07")
    // 同一绝对时刻在不同注入时区可属不同日（跨时区运算必须经由 DayCalendar 的实证）
    let instant = date(2026, 10, 6, 23, 30)
    let utc = DayCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)
    #expect(utc.dayKey(for: instant).rawValue == "2026-10-06")   // UTC 15:30 同日
    let utcMinus5 = DayCalendar(timeZone: TimeZone(secondsFromGMT: -5 * 3600)!)
    #expect(utcMinus5.dayKey(for: instant).rawValue == "2026-10-06")  // 10:30 同日
    // 反例：UTC+8 的 00:30 在 UTC-5 是前一天 11:30
    let earlyMorning = date(2026, 10, 7, 0, 30)
    #expect(utcMinus5.dayKey(for: earlyMorning).rawValue == "2026-10-06")
}

@Test func dayKeyDateRoundtrip() {
    for raw in ["2026-10-06", "2026-01-01", "2024-12-31"] {
        let key = DayKey(rawValue: raw)!
        let back = cal.date(of: key)!
        #expect(cal.dayKey(for: back) == key)
    }
}

@Test func addingDaysCrossesMonthAndYear() {
    let key = DayKey(rawValue: "2026-10-31")!
    #expect(cal.addingDays(1, to: key)?.rawValue == "2026-11-01")
    #expect(cal.addingDays(-1, to: key)?.rawValue == "2026-10-30")
    let yearEnd = DayKey(rawValue: "2026-12-31")!
    #expect(cal.addingDays(1, to: yearEnd)?.rawValue == "2027-01-01")
    let leap = DayKey(rawValue: "2024-02-28")!
    #expect(cal.addingDays(1, to: leap)?.rawValue == "2024-02-29")  // 闰日
}

@Test func dayCalendarExposesClockComponents() {
    #expect(cal.hour(of: date(2026, 10, 6, 21, 5)) == 21)           // 晚 9 点判定（§3.4）
    #expect(cal.minutesSinceMidnight(of: date(2026, 10, 6, 23, 30)) == 23 * 60 + 30)
}

@Test func dateSpanContainsInclusiveBothEnds() {
    let span = DateSpan(startDay: DayKey(rawValue: "2026-10-01")!,
                        endDay: DayKey(rawValue: "2026-10-07")!)
    #expect(span.contains(DayKey(rawValue: "2026-10-01")!))   // 含首
    #expect(span.contains(DayKey(rawValue: "2026-10-07")!))   // 含尾
    #expect(!span.contains(DayKey(rawValue: "2026-09-30")!))
    #expect(!span.contains(DayKey(rawValue: "2026-10-08")!))
    #expect(span.isValid)
    #expect(!DateSpan(startDay: DayKey(rawValue: "2026-10-08")!,
                      endDay: DayKey(rawValue: "2026-10-01")!).isValid)
}

@Test func formattingDurationsAndMacros() {
    #expect(Formatting.duration(minutes: 90) == "1 小时 30 分")
    #expect(Formatting.duration(minutes: 45.4) == "45 分")
    #expect(Formatting.duration(minutes: 60) == "1 小时 0 分")
    #expect(Formatting.grams(86.43) == "86 g")
    #expect(Formatting.kcal(1830.2) == "1830 kcal")
    #expect(Formatting.yuan(23) == "¥23")
    #expect(Formatting.yuan(23.5) == "¥23.5")
}

@Test func weightConversionUsesExactPoundDefinition() {
    // 1 lb = 0.45359237 kg（国际磅精确定义）；往返换算误差可忽略
    #expect(abs(Formatting.lbToKg(1) - 0.45359237) < 1e-12)
    #expect(abs(Formatting.kgToLb(Formatting.lbToKg(159.8)) - 159.8) < 1e-9)
    #expect(Formatting.weight(72.5, unit: .kilogram) == "72.5 kg")
}
