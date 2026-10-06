import Charts
import SelfRecordCore
import SwiftUI

// MARK: - WorkoutDetailView（design.md §6「训练」详情页）
//
// 职责：
//   1. 渲染落盘的分析快照 WorkoutAnalysisSnapshot（简评/练后感受/DOMS/PR/肌群容量图/
//      强度带/恢复建议——快照冻结口径，历史报告不随口径升级漂移，§3.3）；
//   2. 「按当前口径再生成」——AppModel.regenerateAnalysis 用当前数据显式覆盖
//      （confirmationDialog 确认，破坏性语义）；
//   3. 阶段分析 7/30/90 天——WorkoutEngine.analyzePeriod（频率/容量环比/部位组分布/
//      窗口 PR/streak/平衡/六档语气），数据全量来自 AppModel 快照，视图零计算。
//
// 图表：Swift Charts（§7.4：图表全走 Charts，单色系列——颜色承载含义而非装饰）。

/// 页面局部状态（ObservableObject 路径，§8 约定 5）。
final class WorkoutDetailState: ObservableObject {
    @Published var windowDays: Int = 7
    @Published var confirmRegenerate = false
}

/// 阶段分析窗口档（SRSegmented 选项）。
private struct PeriodOption: Hashable, Identifiable {
    let id: Int      // 天数：7 / 30 / 90
}

public struct WorkoutDetailView: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @StateObject private var state = WorkoutDetailState()
    private let workoutID: UUID

    public init(workoutID: UUID) {
        self.workoutID = workoutID
    }

    public var body: some View {
        Group {
            if let workout = model.workouts.first(where: { $0.id == workoutID }) {
                detail(workout)
            } else {
                missingCard
            }
        }
        .background(Color.srBackground)
        .navigationTitle("训练详情")
    }

    private var missingCard: some View {
        ScrollView {
            SRCard {
                VStack(alignment: .leading, spacing: SRSpacing.xs) {
                    Text("该记录不存在")
                        .srFont(.lg, .medium)
                        .foregroundStyle(Color.srForeground)
                    Text("可能已被导入的数据覆盖。")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                }
            }
            .padding(SRSpacing.lg)
        }
    }

    // MARK: - 主体

    private func detail(_ workout: Workout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SRSpacing.lg) {
                header(workout)
                snapshotSection(workout)
                regenerateSection
                periodSection
            }
            .padding(SRSpacing.lg)
        }
    }

    private func header(_ workout: Workout) -> some View {
        SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.xs) {
                Text(workout.startedAt.formatted(.dateTime.year().month().day().weekday(.wide)))
                    .srFont(.lg, .medium)
                    .foregroundStyle(Color.srForeground)
                Text("\(workout.startedAt.formatted(.dateTime.hour().minute()))"
                     + "–\(workout.endedAt.formatted(.dateTime.hour().minute()))"
                     + " · \(Formatting.duration(minutes: workout.endedAt.timeIntervalSince(workout.startedAt) / 60))")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
                if let analysis = workout.analysis {
                    HStack(spacing: SRSpacing.xs) {
                        SRBadge(WorkoutDisplay.intensityText(analysis.intensityBand),
                                tone: WorkoutDisplay.intensityTone(analysis.intensityBand))
                        SRBadge(WorkoutDisplay.domsText(analysis.domsLevel),
                                tone: WorkoutDisplay.domsTone(analysis.domsLevel))
                        if let ratio = analysis.volumeVsRecentAverage {
                            SRBadge("容量为近几次均值 \(Int((ratio * 100).rounded()))%")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 分析快照渲染（规则版结构 = 渲染契约，§1 原则 2）

    @ViewBuilder
    private func snapshotSection(_ workout: Workout) -> some View {
        if let analysis = workout.analysis {
            VStack(alignment: .leading, spacing: SRSpacing.lg) {
                HStack(spacing: SRSpacing.md) {
                    SRStatCard(label: "组数", value: "\(analysis.totals.setCount)")
                    SRStatCard(label: "总次数", value: "\(analysis.totals.repCount)")
                    SRStatCard(label: "总容量",
                               value: WorkoutDisplay.kg(analysis.totals.volumeKg),
                               suffix: "kg")
                }
                sectionCard("简评") { bulletList(analysis.brief) }
                if !analysis.prs.isEmpty {
                    sectionCard("个人纪录（估算 1RM）") { prList(analysis.prs) }
                }
                muscleChart(analysis.muscleVolume)
                sectionCard("练后感受") { bulletList(analysis.postFeel) }
                sectionCard("次日预期") {
                    VStack(alignment: .leading, spacing: SRSpacing.sm) {
                        SRBadge(WorkoutDisplay.domsText(analysis.domsLevel),
                                tone: WorkoutDisplay.domsTone(analysis.domsLevel))
                        Text(analysis.nextDayText)
                            .srFont(.base)
                            .foregroundStyle(Color.srForeground)
                    }
                }
                sectionCard("恢复饮食建议") { bulletList(analysis.diet) }
                sectionCard("休息建议") { bulletList(analysis.rest) }
            }
        } else {
            SRCard {
                VStack(alignment: .leading, spacing: SRSpacing.sm) {
                    Text("这条记录没有分析快照")
                        .srFont(.lg, .medium)
                        .foregroundStyle(Color.srForeground)
                    Text("可能来自导入的历史数据。可用当前口径立即生成一份。")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                    SRButton("生成分析", icon: "sparkles", style: .secondary, size: .sm) {
                        Task { await model.regenerateAnalysis(for: workoutID) }
                    }
                }
            }
        }
    }

    private func prList(_ prs: [PRRecord]) -> some View {
        VStack(spacing: SRSpacing.sm) {
            ForEach(prs) { pr in
                HStack(spacing: SRSpacing.sm) {
                    Text(model.exerciseDisplayName(pr.exerciseID))
                        .srFont(.base)
                        .foregroundStyle(Color.srForeground)
                    Spacer()
                    Text("e1RM \(WorkoutDisplay.kg(pr.bestE1RM)) kg")
                        .font(.srMono(.sm))
                        .monospacedDigit()
                        .foregroundStyle(Color.srForegroundMuted)
                    SRBadge(pr.isNewBaseline ? "首次基准" : "刷新纪录",
                            tone: pr.isNewBaseline ? .info : .success)
                }
            }
        }
    }

    // MARK: - 肌群容量图（Swift Charts 横条，§7.4）

    private struct MusclePoint: Identifiable {
        let id: MuscleGroup
        let label: String
        let volume: Double
    }

    private func muscleChart(_ muscleVolume: [MuscleGroup: Double]) -> some View {
        let points = muscleVolume
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { MusclePoint(id: $0.key,
                               label: ExerciseLibrary.muscleLabel($0.key),
                               volume: $0.value) }
        return sectionCard("肌群容量（分摊）") {
            if points.isEmpty {
                Text("本次没有负重动作的容量记录（自重动作容量记 0、组数计入）。")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
            } else {
                SRChartContainer(height: 200) {
                    Chart(points) { point in
                        BarMark(
                            x: .value("容量", point.volume),
                            y: .value("肌群", point.label)
                        )
                        .foregroundStyle(SRChartPalette.hue(.blue, scheme))
                    }
                }
            }
        }
    }

    // MARK: - 按当前口径再生成（§6：历史快照不漂移，再生成显式覆盖）

    private var regenerateSection: some View {
        SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.sm) {
                Text("分析快照")
                    .srFont(.sm, .medium)
                    .foregroundStyle(Color.srForegroundMuted)
                Text("快照在训练结束时生成并冻结，历史报告不随口径升级漂移；"
                     + "「再生成」会按当前的体重、自定义动作库与当日饮食/时间记录重算并覆盖。")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
                SRButton("按当前口径再生成", icon: "arrow.clockwise",
                         style: .secondary, size: .sm) {
                    state.confirmRegenerate = true
                }
            }
        }
        .confirmationDialog("覆盖为当前口径？", isPresented: $state.confirmRegenerate,
                            titleVisibility: .visible) {
            Button("覆盖（不可撤销）", role: .destructive) {
                Task { await model.regenerateAnalysis(for: workoutID) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原快照将被重算结果替换，此操作不可撤销。")
        }
    }

    // MARK: - 阶段分析（7/30/90 天，§3.3：analyzePeriod）

    private var periodAnalysis: WorkoutPeriodAnalysis {
        let calendar = DayCalendar()
        let end = DayKey(Date(), calendar: calendar)
        let start = calendar.addingDays(-(state.windowDays - 1), to: end) ?? end
        return WorkoutEngine.analyzePeriod(model.workouts,
                                           customExercises: model.customExercises,
                                           in: DateSpan(startDay: start, endDay: end),
                                           calendar: calendar)
    }

    private var periodSection: some View {
        let analysis = periodAnalysis
        return VStack(alignment: .leading, spacing: SRSpacing.lg) {
            HStack(spacing: SRSpacing.md) {
                Text("阶段分析")
                    .srFont(.lg, .medium)
                    .foregroundStyle(Color.srForeground)
                Spacer()
                SRSegmented(options: [PeriodOption(id: 7), PeriodOption(id: 30), PeriodOption(id: 90)],
                            selection: periodBinding) { "\($0.id) 天" }
            }
            HStack(spacing: SRSpacing.md) {
                SRStatCard(label: "训练次数", value: "\(analysis.sessions)")
                SRStatCard(label: "频率",
                           value: String(format: "%.1f", analysis.freqPerWeek),
                           suffix: "次/周")
                SRStatCard(label: "阶段容量",
                           value: WorkoutDisplay.kg(analysis.volumeKg),
                           suffix: "kg",
                           trend: periodTrend(analysis.trendPct))
            }
            HStack(spacing: SRSpacing.xs) {
                SRBadge(analysis.streak >= 5 ? "连续训练 \(analysis.streak) 天" : "连续 \(analysis.streak) 天",
                        tone: analysis.streak >= 5 ? .warning : .neutral)
                SRBadge("休息 \(analysis.restDays) 天")
            }
            sectionCard("状态解读") {
                VStack(alignment: .leading, spacing: SRSpacing.sm) {
                    Text(analysis.tone)
                        .srFont(.lg)
                        .foregroundStyle(Color.srForeground)
                    bulletList(analysis.stateParts)
                    if !analysis.advice.isEmpty {
                        bulletList(analysis.advice)
                    }
                }
            }
            if !analysis.groups.isEmpty {
                groupChart(analysis.groups)
            }
            if !analysis.balanceNotes.isEmpty {
                sectionCard("结构平衡") { bulletList(analysis.balanceNotes) }
            }
            if !analysis.prs.isEmpty {
                sectionCard("窗口个人纪录（估算 1RM）") { windowPRList(analysis.prs) }
            }
            dailyVolumeChart(analysis.dailyVolume)
        }
    }

    private var periodBinding: Binding<PeriodOption> {
        Binding(
            get: { PeriodOption(id: state.windowDays) },
            set: { state.windowDays = $0.id }
        )
    }

    /// 容量环比 → SRStatCard 趋势（nil = 上一窗口无记录，不出趋势）。
    private func periodTrend(_ trendPct: Int?) -> SRStatCard.Trend? {
        guard let pct = trendPct else { return nil }
        return SRStatCard.Trend(direction: pct > 0 ? .up : (pct < 0 ? .down : .flat),
                                text: "\(pct > 0 ? "+" : "")\(pct)%")
    }

    private func windowPRList(_ prs: [WindowPRRecord]) -> some View {
        VStack(spacing: SRSpacing.sm) {
            ForEach(prs) { pr in
                HStack(spacing: SRSpacing.sm) {
                    Text(pr.at.formatted(.dateTime.month().day()))
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                    Text(model.exerciseDisplayName(pr.exerciseID))
                        .srFont(.base)
                        .foregroundStyle(Color.srForeground)
                    Spacer()
                    Text("e1RM \(WorkoutDisplay.kg(pr.e1RM)) kg")
                        .font(.srMono(.sm))
                        .monospacedDigit()
                        .foregroundStyle(Color.srForegroundMuted)
                    SRBadge(pr.prevE1RM > 0 ? "刷新" : "首次基准",
                            tone: pr.prevE1RM > 0 ? .success : .info)
                }
            }
        }
    }

    // MARK: - 阶段图表

    private func groupChart(_ groups: [GroupStat]) -> some View {
        sectionCard("部位组容量分布") {
            SRChartContainer(height: 180) {
                Chart(groups) { group in
                    BarMark(
                        x: .value("容量", group.volume),
                        y: .value("部位组", group.label)
                    )
                    .foregroundStyle(SRChartPalette.hue(.teal, scheme))
                }
            }
        }
    }

    private struct VolumePoint: Identifiable {
        let id: DayKey
        let date: Date
        let volume: Double
    }

    private func dailyVolumeChart(_ daily: [DailyVolumePoint]) -> some View {
        let calendar = DayCalendar()
        let points = daily.map { point in
            VolumePoint(id: point.day,
                        date: calendar.date(of: point.day) ?? .distantPast,
                        volume: point.volumeKg)
        }
        let strideDays = state.windowDays <= 7 ? 1 : (state.windowDays <= 30 ? 7 : 30)
        return sectionCard("逐日容量") {
            SRChartContainer(height: 180) {
                Chart(points) { point in
                    BarMark(
                        x: .value("日期", point.date, unit: .day),
                        y: .value("容量", point.volume)
                    )
                    .foregroundStyle(SRChartPalette.hue(.blue, scheme))
                }
                .srYAxisGrid()
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: strideDays)) { _ in
                        AxisValueLabel(format: .dateTime.month().day())
                            .font(.sr(.sm))
                            .foregroundStyle(Color.srForegroundMuted)
                    }
                }
            }
        }
    }

    // MARK: - 小件

    private func sectionCard<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.sm) {
                Text(title)
                    .srFont(.sm, .medium)
                    .foregroundStyle(Color.srForegroundMuted)
                content()
            }
        }
    }

    private func bulletList(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: SRSpacing.sm) {
                    SRDotBadge(.srForegroundSubtle)
                        .padding(.top, 6)
                    Text(line)
                        .srFont(.base)
                        .foregroundStyle(Color.srForeground)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
