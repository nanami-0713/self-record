import SelfRecordCore
import SwiftUI

// MARK: - TodayView（design.md §6「今日」Tab）
//
// 日简报五域合一：日期前后翻页 + 进行中计时器常驻状态条（点按直达对应记录页）
// + 五张域卡片（点击跳对应 Tab）。数据全部经 AppModel+Today 的组装方法取自
// Core 引擎（DayReport / RecoveryContext / 恢复建议），视图层零业务逻辑。
//
// ⚠ 与 design.md §6「toolbar 箭头」的实现偏离（显式记录）：本机无法验证 app
// 入口是否把 Tab 包进 NavigationStack——不在容器内时 `.toolbar` 内容不渲染，
// 翻页会整体消失。故翻页放页内头部（恒可见、macOS 编译零风险）；app 入口
// 接 NavigationStack 后如需迁回 toolbar，只动本文件的 header 一处。
//
// Tab 跳转经闭包注入（app 入口把闭包接到 TabView selection）——today 分组
// 不拥有顶层导航，也不在共享文件里造路由类型（§8 约定 4：零共享可变文件）。

/// 「今日」页。
public struct TodayView: View {

    @ObservedObject public var appModel: AppModel

    // 卡片点击跳对应 Tab（§6）：时间/睡眠/饮食三卡都落在「记录」Tab 的
    // 三段页签上，入口按闭包分别接线（后续 records 分组的段选择器就绪后
    // 可在闭包里带段位）。
    public var onOpenTime: () -> Void
    public var onOpenSleep: () -> Void
    public var onOpenDiet: () -> Void
    public var onOpenWorkout: () -> Void
    public var onOpenBudget: () -> Void

    @StateObject private var pager: TodayPager
    @StateObject private var reportState = PeriodReportState()

    public init(appModel: AppModel,
                onOpenTime: @escaping () -> Void = {},
                onOpenSleep: @escaping () -> Void = {},
                onOpenDiet: @escaping () -> Void = {},
                onOpenWorkout: @escaping () -> Void = {},
                onOpenBudget: @escaping () -> Void = {}) {
        self.appModel = appModel
        self.onOpenTime = onOpenTime
        self.onOpenSleep = onOpenSleep
        self.onOpenDiet = onOpenDiet
        self.onOpenWorkout = onOpenWorkout
        self.onOpenBudget = onOpenBudget
        _pager = StateObject(wrappedValue: TodayPager(calendar: DayCalendar()))
    }

    public var body: some View {
        let now = Date()
        let report = appModel.dayReport(day: pager.selectedDay,
                                        calendar: appModel.todayCalendar, now: now)
        ScrollView {
            VStack(spacing: SRSpacing.md) {
                TodayHeaderView(pager: pager)
                activeStrips
                TodayTimeCard(brief: report.time,
                              summary: report.timeSummary,
                              categories: appModel.categories,
                              onTap: onOpenTime)
                TodaySleepCard(brief: report.sleep,
                               isToday: pager.isToday,
                               onTap: onOpenSleep)
                TodayWorkoutCard(brief: report.workout,
                                 advice: appModel.recoveryAdvice(day: pager.selectedDay,
                                                                 calendar: appModel.todayCalendar),
                                 isToday: pager.isToday,
                                 onTap: onOpenWorkout)
                TodayDietCard(brief: report.diet,
                              onTap: onOpenDiet)
                TodayBudgetCard(brief: report.budget,
                                 onTap: onOpenBudget)
                TodayPeriodReportCard(onTap: { reportState.isPresented = true })
            }
            .padding(.horizontal, SRSpacing.lg)
            .padding(.vertical, SRSpacing.md)
        }
        .background(Color.srBackground)
        .sheet(isPresented: $reportState.isPresented) {
            PeriodReportSheet(appModel: appModel, state: reportState)
        }
    }

    // MARK: - 进行中常驻条（§6：点按直达对应记录页）

    @ViewBuilder
    private var activeStrips: some View {
        if let timer = appModel.activeTimer {
            TodayActiveStrip(icon: timer.kind == .sleep ? "moon.zzz.fill" : "timer",
                             title: timer.kind == .sleep ? "睡眠记录中" : "日常计时进行中",
                             subtitle: "开始于 \(TodayText.clock(timer.startedAt))",
                             startedAt: timer.startedAt,
                             onTap: timer.kind == .sleep ? onOpenSleep : onOpenTime)
        }
        if let workout = appModel.activeWorkout {
            TodayActiveStrip(icon: "dumbbell.fill",
                             title: "训练进行中",
                             subtitle: workout.entries.isEmpty
                                ? "还没有记录组"
                                : "已记 \(workout.entries.count) 个动作",
                             startedAt: workout.startedAt,
                             onTap: onOpenWorkout)
        }
    }
}

// MARK: - 页头（日期翻页）

private struct TodayHeaderView: View {

    @ObservedObject var pager: TodayPager

    var body: some View {
        HStack(spacing: SRSpacing.sm) {
            SRButton("", icon: "chevron.left", style: .ghost, size: .sm) {
                pager.goBackward()
            }
            .accessibilityLabel("前一天")

            Spacer()

            VStack(spacing: SRSpacing.xs) {
                Text(TodayText.dayTitle(pager.selectedDay))
                    .srFont(.lg, .semibold)
                    .foregroundStyle(Color.srForeground)
                if !pager.isToday {
                    SRButton("回到今天", style: .link, size: .sm) {
                        pager.goToday()
                    }
                }
            }

            Spacer()

            SRButton("", icon: "chevron.right", style: .ghost, size: .sm) {
                pager.goForward()
            }
            .disabled(pager.isToday)   // 到今天为止，不翻向未来
            .accessibilityLabel("后一天")
        }
        .padding(.top, SRSpacing.xs)
    }
}

// MARK: - 进行中常驻条

private struct TodayActiveStrip: View {

    let icon: String
    let title: String
    let subtitle: String
    let startedAt: Date
    let onTap: () -> Void

    var body: some View {
        // 流逝时间用 TimelineView 每秒重绘（§6 全局交互约定；重算范围收敛在
        // 本条内，不触发整页 body → 不重算五域聚合）。
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Button(action: onTap) {
                HStack(spacing: SRSpacing.md) {
                    Image(systemName: icon)
                        .font(.sr(.md))
                        .foregroundStyle(Color.srAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .srFont(.base, .medium)
                            .foregroundStyle(Color.srForeground)
                        Text(subtitle)
                            .srFont(.sm)
                            .foregroundStyle(Color.srForegroundMuted)
                    }
                    Spacer(minLength: SRSpacing.md)
                    Text(TodayText.elapsed(from: startedAt, to: context.date))
                        .srFont(.lg, .semibold)
                        .monospacedDigit()
                        .foregroundStyle(Color.srForeground)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.right")
                        .font(.sr(.sm))
                        .foregroundStyle(Color.srForegroundSubtle)
                }
                .padding(.horizontal, SRSpacing.lg)
                .padding(.vertical, SRSpacing.md)
                .contentShape(Rectangle())
                .srSurface(.surface, radius: SRRadius.lg)
                .srShadow(.raised)
            }
            .buttonStyle(TodayPressDimStyle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title)，\(subtitle)")
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

// MARK: - 卡片按压态（Ely 无 scale 形变：纯透明度变化，克制）

struct TodayPressDimStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : SRMotion.fast, value: configuration.isPressed)
    }
}

// MARK: - 展示格式化（值 → 串；非业务逻辑）

enum TodayText {

    /// 日键 → 页头标题：「10月6日 周二」；解析失败退回原始键。
    static func dayTitle(_ day: DayKey) -> String {
        guard let date = DayCalendar().date(of: day) else { return day.rawValue }
        return date.formatted(
            .dateTime.month().day().weekday().locale(Locale(identifier: "zh_CN"))
        )
    }

    /// 时刻 → 「23:12」（起止/开始于共用）。
    static func clock(_ date: Date) -> String {
        date.formatted(
            .dateTime.hour().minute().locale(Locale(identifier: "zh_CN"))
        )
    }

    /// 流逝秒 → 「1:23:45」（常驻条计时口吻，秒级跳动）。
    static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
