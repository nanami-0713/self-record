import SelfRecordCore
import SwiftUI

// MARK: - 阶段报告 sheet（design.md §3.6 / §9-7「保留（灵魂，不可砍）」第 7 条）
//
// 五域阶段综合报告的用户入口：三档预设（过去一天/一周/一月）+ 自定义区间
// （DatePicker 起/止，含首尾 ≤366 天）→ ReportEngine.periodReport 五域聚合
// → renderRuleReport 规则版文案立即出。数据全部经 AppModel+Today 的组装方法
// 取自 Core 引擎，视图层零业务逻辑；AI 版后置（§9-5，同一渲染契约）。
//
// 区间档语义 = ReportRange.swift（预设锚今天；自定义 end < start / >366 天
// → nil → 页内提示，UI 层 DatePicker 同步夹住 end ≥ start）。

/// sheet 局部状态（ObservableObject 路径，§8 约定 5；WorkoutListView 同款）。
final class PeriodReportState: ObservableObject {
    @Published var isPresented = false
    /// 区间档（三预设 + 自定义；SRSegmented 选项）
    @Published var mode: ReportMode = .week
    /// 自定义起止（初值 = 近 7 天，与预设周档同区间，避免初始非法）
    @Published var customStart: Date
    @Published var customEnd: Date

    init(now: Date = Date(), calendar: DayCalendar = DayCalendar()) {
        let endKey = calendar.dayKey(for: now)
        let startKey = calendar.addingDays(-6, to: endKey) ?? endKey
        customEnd = calendar.date(of: endKey) ?? now
        customStart = calendar.date(of: startKey) ?? now
    }
}

/// 区间档（SRSegmented 选项；短标签 + 页内区间信息行补全语义）。
enum ReportMode: Hashable, Identifiable, CaseIterable {
    case day
    case week
    case month
    case custom

    var id: Self { self }

    var shortLabel: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        case .custom: return "自定义"
        }
    }

    /// 对应预设档（自定义 → nil）。
    var preset: ReportPreset? {
        switch self {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        case .custom: return nil
        }
    }
}

/// 阶段报告 sheet：选区间 → 渲染 RuleReport 分板块文案。
struct PeriodReportSheet: View {

    @ObservedObject var appModel: AppModel
    @ObservedObject var state: PeriodReportState

    var body: some View {
        let now = Date()
        let calendar = appModel.todayCalendar
        ScrollView {
            VStack(alignment: .leading, spacing: SRSpacing.lg) {
                HStack(spacing: SRSpacing.md) {
                    Text("阶段报告")
                        .srFont(.lg, .semibold)
                        .foregroundStyle(Color.srForeground)
                    Spacer()
                    SRButton("关闭", style: .ghost, size: .sm) { state.isPresented = false }
                }

                SRSegmented(options: ReportMode.allCases,
                            selection: $state.mode) { $0.shortLabel }

                if state.mode == .custom {
                    VStack(alignment: .leading, spacing: SRSpacing.xs) {
                        DatePicker("开始", selection: $state.customStart,
                                   displayedComponents: .date)
                        DatePicker("结束", selection: $state.customEnd,
                                   in: state.customStart...,
                                   displayedComponents: .date)
                    }
                }

                if let range = range(now: now, calendar: calendar) {
                    Text("\(range.label) · \(range.dayCount) 天")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                    ruleSections(range: range, now: now)
                } else {
                    SRCard {
                        Text("自定义区间不可用：起止需含首尾且最长 366 天，请调整范围。")
                            .srFont(.base)
                            .foregroundStyle(Color.srForegroundMuted)
                    }
                }
            }
            .padding(SRSpacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.srBackground)
    }

    // MARK: - 区间换算（经 AppModel 组装通道）

    private func range(now: Date, calendar: DayCalendar) -> ReportRange? {
        if let preset = state.mode.preset {
            return appModel.periodRange(preset: preset, now: now, calendar: calendar)
        }
        let custom = ReportCustomRange(
            startDay: DayKey(state.customStart, calendar: calendar),
            endDay: DayKey(state.customEnd, calendar: calendar)
        )
        return appModel.periodRange(custom: custom, calendar: calendar)
    }

    // MARK: - RuleReport 渲染（板块 = §3.6 契约；文案已含空数据兜底句）

    @ViewBuilder
    private func ruleSections(range: ReportRange, now: Date) -> some View {
        let report = appModel.rulePeriodReport(range: range, now: now)
        VStack(alignment: .leading, spacing: SRSpacing.md) {
            RuleSectionCard(icon: "text.quote", title: "总评",
                            lines: report.overall, elevation: .raised)
            RuleSectionCard(icon: "clock", title: "时间投入", lines: report.time)
            RuleSectionCard(icon: "moon.zzz", title: "睡眠", lines: report.sleep)
            RuleSectionCard(icon: "dumbbell", title: "训练", lines: report.workout)
            RuleSectionCard(icon: "fork.knife", title: "饮食", lines: report.diet)
            RuleSectionCard(icon: "creditcard", title: "开销", lines: report.budget)
            RuleSectionCard(icon: "lightbulb", title: "下阶段建议", lines: report.advice)
        }
    }
}

/// 报告板块卡：图标 + 标题 + 文案行（整体复用 SRCard，不私造样式）。
private struct RuleSectionCard: View {

    let icon: String
    let title: String
    let lines: [String]
    var elevation: SRCardElevation = .flat

    var body: some View {
        SRCard(elevation: elevation) {
            VStack(alignment: .leading, spacing: SRSpacing.sm) {
                HStack(spacing: SRSpacing.sm) {
                    Image(systemName: icon)
                        .font(.sr(.md))
                        .foregroundStyle(Color.srForegroundMuted)
                    Text(title)
                        .srFont(.lg, .medium)
                        .foregroundStyle(Color.srForeground)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .srFont(.base)
                        .foregroundStyle(Color.srForeground)
                        .fixedSize(horizontal: false, vertical: true)   // 长句不截断
                }
            }
        }
    }
}

/// 「今日」页的阶段报告入口卡（点击弹 sheet；非跳转 Tab，独立于 TodayDomainCard）。
struct TodayPeriodReportCard: View {

    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            SRCard {
                VStack(alignment: .leading, spacing: SRSpacing.sm) {
                    HStack(spacing: SRSpacing.sm) {
                        Image(systemName: "chart.bar.doc.horizontal")
                            .font(.sr(.md))
                            .foregroundStyle(Color.srForegroundMuted)
                        Text("阶段报告")
                            .srFont(.lg, .medium)
                            .foregroundStyle(Color.srForeground)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.sr(.sm))
                            .foregroundStyle(Color.srForegroundSubtle)
                    }
                    Text("过去一天/一周/一月或自定义区间的五域综合复盘（规则版）")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TodayPressDimStyle())
        .accessibilityHint("打开阶段报告")
    }
}
