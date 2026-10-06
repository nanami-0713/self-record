import Charts
import SelfRecordCore
import SwiftUI

// MARK: - 五域卡片（design.md §6 TodayView）
//
// 每张卡 = 可点 SRCard（点击跳对应 Tab）+ 域数据（DayReport 的对应分片）。
// 数字排版镜像 SRStatCard 规格（Xxl semibold + Md 单位基线对齐，§7.4）；
// 图表走 Swift Charts + SRChartContainer/SRChartPalette（§7.4 单点收口）。

// MARK: - 卡片外壳

/// 域卡片：图标 + 标题 + 右缘 chevron（点击暗示），整卡可点。
struct TodayDomainCard<Content: View>: View {

    let icon: String
    let title: String
    let onTap: () -> Void
    let content: Content

    init(icon: String, title: String, onTap: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.onTap = onTap
        self.content = content()
    }

    var body: some View {
        Button(action: onTap) {
            SRCard {
                VStack(alignment: .leading, spacing: SRSpacing.md) {
                    HStack(spacing: SRSpacing.sm) {
                        Image(systemName: icon)
                            .font(.sr(.md))
                            .foregroundStyle(Color.srForegroundMuted)
                        Text(title)
                            .srFont(.lg, .medium)
                            .foregroundStyle(Color.srForeground)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.sr(.sm))
                            .foregroundStyle(Color.srForegroundSubtle)
                    }
                    content
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TodayPressDimStyle())
        .accessibilityHint("跳转到\(title)对应页面")
    }
}

/// 数值行：Xxl semibold 数值 + Md 单位（基线对齐）+ Sm muted 标签（SRStatCard 规格）。
private struct TodayHeroValue: View {

    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: SRSpacing.xs) {
                Text(value)
                    .srFont(.xxl, .semibold)
                    .monospacedDigit()
                    .foregroundStyle(Color.srForeground)
                if !unit.isEmpty {
                    Text(unit)
                        .srFont(.md)
                        .foregroundStyle(Color.srForegroundMuted)
                }
            }
            Text(label)
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)
        }
    }
}

/// 键值行：Sm muted 键 + Sm 值（睡眠起止 / 预算周进度等次级信息）。
private struct TodayInfoRow: View {

    let key: String
    let value: String
    var tint: Color = .srForeground

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)
            Spacer(minLength: SRSpacing.sm)
            Text(value)
                .srFont(.sm, .medium)
                .monospacedDigit()
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 时间投入（总时长 + Top3 分类横条，Swift Charts）

struct TodayTimeCard: View {

    let brief: TimeDayBrief
    let summary: String
    let categories: [TimeCategory]
    let onTap: () -> Void

    @Environment(\.colorScheme) private var scheme

    /// Charts 横条行（Identifiable 供 Chart data 用）。
    private struct BarRow: Identifiable {
        let id: String
        let label: String
        let minutes: Double
        let hue: ChartHue
    }

    private var rows: [BarRow] {
        // y 轴类目自下而上排布 → 反转后 Top1 在最上
        brief.topCategories.prefix(3).reversed().map { share in
            BarRow(id: share.categoryID,
                   label: share.label,
                   minutes: share.minutes,
                   hue: categories.first { $0.id == share.categoryID }?.hue ?? .neutral)
        }
    }

    var body: some View {
        TodayDomainCard(icon: "clock", title: "时间投入", onTap: onTap) {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                TodayHeroValue(value: Formatting.duration(minutes: brief.totalMinutes),
                               unit: "",
                               label: "共记录投入")
                if !rows.isEmpty {
                    SRChartContainer(height: CGFloat(rows.count) * 32) {
                        Chart(rows) { row in
                            BarMark(
                                x: .value("分钟", row.minutes),
                                y: .value("分类", row.label)
                            )
                            .foregroundStyle(SRChartPalette.hue(row.hue, scheme))
                            .cornerRadius(2)
                            .annotation(position: .trailing) {
                                Text(Formatting.duration(minutes: row.minutes))
                                    .srFont(.xs)
                                    .foregroundStyle(Color.srForegroundMuted)
                            }
                        }
                        .chartXAxis(.hidden)
                        .chartYAxis {
                            AxisMarks { _ in
                                AxisValueLabel()
                                    .font(.sr(.sm))
                                    .foregroundStyle(Color.srForegroundMuted)
                            }
                        }
                    }
                }
                Text(summary)
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
            }
        }
    }
}

// MARK: - 昨晚睡眠（时长/起止/感受/近 7 晚睡眠债；不显示单夜分数，A3 口径）

struct TodaySleepCard: View {

    let brief: DaySleepBrief?
    let isToday: Bool
    let onTap: () -> Void

    var body: some View {
        TodayDomainCard(icon: "moon.zzz", title: "昨晚睡眠", onTap: onTap) {
            if let brief {
                VStack(alignment: .leading, spacing: SRSpacing.md) {
                    TodayHeroValue(value: Formatting.duration(minutes: brief.night.durationSeconds / 60),
                                   unit: "",
                                   label: "\(TodayText.clock(brief.night.start)) – \(TodayText.clock(brief.night.end))")
                    VStack(spacing: SRSpacing.xs) {
                        TodayInfoRow(key: "起床感受",
                                     value: feelText(brief.night.feel))
                        if brief.napMinutes > 0 {
                            TodayInfoRow(key: "当日午睡",
                                         value: Formatting.duration(minutes: Double(brief.napMinutes)))
                        }
                        if brief.weekDebtMinutes > 0 {
                            TodayInfoRow(key: "近 7 晚睡眠债",
                                         value: Formatting.duration(minutes: Double(brief.weekDebtMinutes)),
                                         tint: .srWarning)
                        }
                    }
                }
            } else {
                Text(isToday ? "昨晚没有睡眠记录——睡前在「时间」页点一下就能记。"
                             : "这天没有睡眠记录。")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
            }
        }
    }

    /// 感受 1–5 → 展示串（nil = 问卷跳过，不惩罚——展示「未填」而非占位分）。
    private func feelText(_ feel: Int?) -> String {
        guard let feel else { return "未填" }
        return "\(feel)/5"
    }
}

// MARK: - 当日训练（PR 与 DOMS 徽标 + 恢复建议[RecoveryContext 组装]）

struct TodayWorkoutCard: View {

    let brief: DayWorkoutBrief
    let advice: [String]
    let isToday: Bool
    let onTap: () -> Void

    var body: some View {
        TodayDomainCard(icon: "dumbbell", title: "当日训练", onTap: onTap) {
            if brief.sessions > 0 {
                VStack(alignment: .leading, spacing: SRSpacing.md) {
                    TodayHeroValue(value: brief.volumeKg > 0
                                        ? "\(Int(brief.volumeKg.rounded()))"
                                        : "–",
                                   unit: brief.volumeKg > 0 ? "kg" : "",
                                   label: heroLabel)
                    if !brief.primaryLabels.isEmpty {
                        TodayInfoRow(key: "主练",
                                     value: brief.primaryLabels.prefix(3).joined(separator: "、"))
                    }
                    HStack(spacing: SRSpacing.sm) {
                        if brief.prCount > 0 {
                            SRBadge("\(brief.prCount) 项个人纪录", tone: .success)
                        }
                        if let doms = brief.domsLevel {
                            SRBadge("次日酸痛 · \(domsText(doms))", tone: domsTone(doms))
                        }
                    }
                    if !advice.isEmpty {
                        VStack(alignment: .leading, spacing: SRSpacing.xs) {
                            Text("恢复建议")
                                .srFont(.sm, .medium)
                                .foregroundStyle(Color.srForegroundMuted)
                            ForEach(Array(advice.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .srFont(.sm)
                                    .foregroundStyle(Color.srForeground)
                            }
                        }
                    }
                }
            } else {
                Text(isToday ? "今天还没有训练记录，想练就从「训练」页开始。"
                             : "这天没有训练记录。")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
            }
        }
    }

    private var heroLabel: String {
        var parts = ["\(brief.sessions) 次训练"]
        if brief.volumeKg <= 0 { parts.append("自重为主，容量不计") }
        return parts.joined(separator: " · ")
    }

    /// DOMS 四档展示名（§3.3：≥7 强烈 / ≥5 明显 / ≥3 中度 / 其余轻微）。
    private func domsText(_ level: DOMSLevel) -> String {
        switch level {
        case .severe: "强烈"
        case .noticeable: "明显"
        case .moderate: "中度"
        case .mild: "轻微"
        }
    }

    /// 徽标色调：酸痛越强信号越重（颜色承载含义，§7.1 原则）。
    private func domsTone(_ level: DOMSLevel) -> SRBadge.Tone {
        switch level {
        case .severe: .danger
        case .noticeable: .warning
        case .moderate: .info
        case .mild: .success
        }
    }
}

// MARK: - 当日饮食（宏量环 + 训练日蛋白缺口标黄）

struct TodayDietCard: View {

    let brief: DayDietBrief
    let onTap: () -> Void

    var body: some View {
        TodayDomainCard(icon: "fork.knife", title: "当日饮食", onTap: onTap) {
            let summary = brief.summary
            let totals = summary.totals.totals
            if summary.totals.itemCount == 0 {
                Text(summary.advice.first ?? "今天还没记饮食。")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
            } else {
                HStack(alignment: .center, spacing: SRSpacing.lg) {
                    proteinRing(totals.proteinG, targets: summary.targets)
                    VStack(alignment: .leading, spacing: SRSpacing.xs) {
                        TodayInfoRow(key: "热量",
                                     value: "\(Int(totals.kcal.rounded())) / \(summary.targets.kcal) kcal")
                        TodayInfoRow(key: "蛋白质",
                                     value: "\(Int(totals.proteinG.rounded())) / \(summary.targets.proteinLo)–\(summary.targets.proteinHi) g",
                                     tint: brief.proteinGapOnTrainingDay ? .srWarning : .srForeground)
                        if brief.proteinGapOnTrainingDay {
                            SRBadge("训练日蛋白缺口", tone: .warning)
                        } else if brief.postWorkoutMealEaten {
                            SRBadge("练后餐已补", tone: .success)
                        }
                    }
                }
            }
        }
    }

    /// 蛋白环：进度 = 已摄入 / 目标中值；缺口→warning、达标→success、其余 accent。
    @ViewBuilder
    private func proteinRing(_ proteinG: Double, targets: NutritionTargets) -> some View {
        let ratio = targets.proteinTarget > 0
            ? proteinG / Double(targets.proteinTarget)
            : 0
        let tint: Color = brief.proteinGapOnTrainingDay
            ? .srWarning
            : (proteinG >= Double(targets.proteinLo) ? .srSuccess : .srAccent)
        SRProgressRing(progress: ratio, tint: tint) {
            VStack(spacing: 0) {
                Text("\(Int((ratio * 100).rounded()))")
                    .srFont(.sm, .semibold)
                    .monospacedDigit()
                    .foregroundStyle(Color.srForeground)
                Text("%")
                    .srFont(.xs)
                    .foregroundStyle(Color.srForegroundMuted)
            }
        }
        .accessibilityLabel("蛋白质目标达成")
    }
}

// MARK: - 开销（日/周预算进度条）

struct TodayBudgetCard: View {

    let brief: DayBudgetBrief
    let onTap: () -> Void

    var body: some View {
        TodayDomainCard(icon: "creditcard", title: "开销", onTap: onTap) {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                TodayHeroValue(value: Formatting.yuan(brief.daySpentYuan),
                               unit: "",
                               label: "今日开销")
                if let budget = brief.weekBudgetYuan, budget > 0,
                   let weekSpent = brief.weekSpentYuan {
                    let percent = brief.weekUsedPercent ?? 0
                    VStack(alignment: .leading, spacing: SRSpacing.xs) {
                        SRProgressBar(progress: weekSpent / budget, tint: progressTint(percent))
                        TodayInfoRow(key: "本周",
                                     value: "\(Formatting.yuan(weekSpent)) / \(Formatting.yuan(budget)) · \(percent)%",
                                     tint: progressTint(percent))
                    }
                } else if let weekSpent = brief.weekSpentYuan {
                    TodayInfoRow(key: "本周已花", value: Formatting.yuan(weekSpent))
                    Text("在「设置」里设周预算后可看进度。")
                        .srFont(.xs)
                        .foregroundStyle(Color.srForegroundSubtle)
                }
            }
        }
    }

    /// 进度语义色：超支 danger、临期(>80%) warning、正常 accent。
    private func progressTint(_ percent: Int) -> Color {
        if percent > 100 { return .srDanger }
        if percent > 80 { return .srWarning }
        return .srAccent
    }
}
