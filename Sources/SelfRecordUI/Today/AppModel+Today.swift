import Foundation
import SelfRecordCore

// MARK: - today 分组（design.md §6 页面地图 / §8 约定 4）
//
// 界面工程师工作区：Sources/SelfRecordUI/Today/ 由 today 分组工程师独占。
// 页面：TodayView（日简报五域卡片、日期前后翻页、进行中计时器常驻状态条）。
//
// 约定：
//   - 动作方法放本文件（extension AppModel），不改 AppModel.swift（冻结物 C）；
//   - 跨域取数只经 §2.1 聚合 API 组装（RecoveryContext = DietEngine.dayIntake
//     + TimeEngine.fitnessMinutes），不越层直捣各域内部函数；
//   - SwiftUI 宏禁令（§8 约定 5）：禁 @State 等；ObservableObject 路径；
//   - 颜色/组件只用 DesignSystem 语义名。
//
// 本文件只做「快照 → 引擎入参」的组装与结果透传，视图层零业务逻辑；
// DayCalendar 由调用方（View）注入（§2 依赖规则末条：不隐式依赖时区）。

extension AppModel {

    /// 日历装配：运行时 UI 用「公历 + 当前时区」（DayCalendar 骨架默认裁决，
    /// design.md §12.6）。引擎函数仍显式收参数，不隐式读全局。
    var todayCalendar: DayCalendar { DayCalendar() }

    /// 五域聚合输入：各域只读快照 → ReportInputs（report 的唯一聚合入口，
    /// §2.1 冻结物 B 的消费形态）。
    func reportInputs() -> ReportInputs {
        ReportInputs(categories: categories,
                     timeBlocks: timeBlocks,
                     sleepSessions: sleepSessions,
                     workouts: workouts,
                     dietEntries: dietEntries,
                     expenses: expenses,
                     customExercises: customExercises,
                     bodyweightKg: settings.bodyweightKg,
                     sleepGoalMinutes: settings.sleepGoalMinutes,
                     weeklyBudgetYuan: settings.weeklyBudgetYuan)
    }

    /// 日简报（五域合一）：日期翻页 = 换 DayKey 再调一次（§6）。
    /// 睡眠域不含单夜分数（A3 口径——分数归区间层）。
    func dayReport(day: DayKey, calendar: DayCalendar, now: Date) -> DayReport {
        ReportEngine.dayReport(day: day, inputs: reportInputs(), calendar: calendar, now: now)
    }

    /// 阶段报告区间换算：预设档（day/week/month 锚定 now 所在日，§3.6）。
    func periodRange(preset: ReportPreset, now: Date,
                     calendar: DayCalendar) -> ReportRange? {
        ReportEngine.reportRange(preset: preset, now: now, calendar: calendar)
    }

    /// 阶段报告区间换算：自定义起止（含首尾；end < start 或 >366 天 → nil，§3.6）。
    func periodRange(custom: ReportCustomRange, calendar: DayCalendar) -> ReportRange? {
        ReportEngine.reportRange(custom: custom, calendar: calendar)
    }

    /// 规则版阶段报告（§3.6「规则版报告立即出」）：区间 → 五域聚合 → 分板块文案。
    /// 与未来 AI 版同一数据契约（§9-7：一份渲染两用，AI 只加网络层）。
    func rulePeriodReport(range: ReportRange, now: Date) -> RuleReport {
        ReportEngine.renderRuleReport(
            ReportEngine.periodReport(range: range, inputs: reportInputs(),
                                      calendar: todayCalendar, now: now)
        )
    }

    /// 跨域恢复上下文组装（design.md §8 约定 4 的定型通道，唯一合法形态）：
    /// `DietEngine.dayIntake`（练后餐判定用当日最后一次训练开始时刻，与
    /// ReportEngine.dayReport 同口径）+ `TimeEngine.fitnessMinutes`（当日
    /// FITNESS_CATS 时间块合计）+ 设置里的体重。
    func recoveryContext(day: DayKey, calendar: DayCalendar) -> RecoveryContext {
        let startedAt = workouts(on: day, calendar: calendar)
            .max { $0.startedAt < $1.startedAt }?
            .startedAt
        return RecoveryContext(
            bodyweightKg: settings.bodyweightKg,
            dayIntake: DietEngine.dayIntake(dietEntries, day: day,
                                            woStartedAt: startedAt, calendar: calendar),
            fitnessTimeMinutes: TimeEngine.fitnessMinutes(timeBlocks, day: day, calendar: calendar)
        )
    }

    /// 当日训练（start 归属该日的记录，升序无关）。
    private func workouts(on day: DayKey, calendar: DayCalendar) -> [Workout] {
        workouts.filter { calendar.dayKey(for: $0.startedAt) == day }
    }

    /// 当日恢复建议（训练卡的「恢复建议」区）：取当日最后一次训练，用当前
    /// 域快照 + 组装好的 RecoveryContext 重跑 `WorkoutEngine.analyzeSession`
    /// （与「按当前口径再生成」同通道，§3.3——建议读实际蛋白摄入，随当日
    /// 记餐动态更新，不用落盘时的冻结快照）。无训练日返回空。
    ///
    /// 产出 ≤3 条：饮食建议首条 + 休息建议首条（hasPostMeal 为真时它就是
    /// 「练后餐已经吃上了 ✓」）+ 训练耗时联动句（fitnessTimeMinutes > 0 时）。
    func recoveryAdvice(day: DayKey, calendar: DayCalendar) -> [String] {
        let dayWorkouts = workouts(on: day, calendar: calendar)
        guard let last = dayWorkouts.max(by: { $0.startedAt < $1.startedAt }) else {
            return []
        }
        let context = recoveryContext(day: day, calendar: calendar)
        let snapshot = WorkoutEngine.analyzeSession(last,
                                                    history: workouts,
                                                    customExercises: customExercises,
                                                    recovery: context)
        var lines: [String] = []
        if let diet = snapshot.diet.first { lines.append(diet) }
        if let rest = snapshot.rest.first { lines.append(rest) }
        if let minutes = context.fitnessTimeMinutes, minutes > 0,
           let crossDomain = snapshot.brief.last {     // analysis.js:263 联动句固定在 brief 末位
            lines.append(crossDomain)
        }
        return lines
    }
}
