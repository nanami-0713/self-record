import Combine
import Foundation
import SelfRecordCore

// MARK: - 日期翻页状态（design.md §6 TodayView「日期前后翻页」）
//
// ObservableObject 路径（§8 约定 5：View 持有态走 @StateObject + @Published，
// 禁 SwiftUI 宏）。日历由构造方注入，不隐式依赖全局时区；「今天」在每次
// 比较时现取（跨午夜停留时前进箭头会正确禁用）。
@MainActor
final class TodayPager: ObservableObject {

    /// 当前查看的日键（含首尾语义见 DayKey；翻页 = addDays ±1）。
    @Published private(set) var selectedDay: DayKey

    private let calendar: DayCalendar

    init(calendar: DayCalendar, now: Date = Date()) {
        self.calendar = calendar
        self.selectedDay = calendar.dayKey(for: now)
    }

    var isToday: Bool {
        selectedDay == calendar.dayKey(for: Date())
    }

    /// 前一天（无限回看）。
    func goBackward() {
        if let previous = calendar.addingDays(-1, to: selectedDay) {
            selectedDay = previous
        }
    }

    /// 后一天（到今天为止，不翻向未来）。
    func goForward() {
        guard !isToday,
              let next = calendar.addingDays(1, to: selectedDay) else { return }
        selectedDay = next
    }

    /// 一键回到今天（不在今天时页头展示）。
    func goToday() {
        selectedDay = calendar.dayKey(for: Date())
    }
}
