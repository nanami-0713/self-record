import SelfRecordCore
import SwiftUI

// MARK: - WorkoutListView（design.md §6「训练」Tab 首页）
//
// 职责：历史训练列表（日期/主练/容量/PR 徽标）+「开始训练」主按钮 +
// 进行中训练常驻恢复条（active.json 崩溃恢复态，§5）。
//
// 宿主约定：需在 NavigationStack 内呈现（行点击 push WorkoutDetailView）、
// 根部注入 .environmentObject(AppModel)——装配归 app 入口。
//
// 宏禁令（§8 约定 5）：页面局部状态（sheet 开关）用 ObservableObject +
// @StateObject；无 @State。

/// 页面局部状态（ObservableObject 路径，§8 约定 5）。
final class WorkoutListState: ObservableObject {
    /// 进行中训练 sheet 的开关（恢复条「继续」与「开始训练」共用）。
    @Published var showsActiveSession = false
}

public struct WorkoutListView: View {

    @EnvironmentObject private var model: AppModel
    @StateObject private var state = WorkoutListState()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: SRSpacing.lg) {
                if let active = model.activeWorkout {
                    activeBanner(active)
                }
                SRButton("开始训练", icon: "dumbbell", style: .primary, size: .md) {
                    Task {
                        await model.startWorkout()
                        state.showsActiveSession = true
                    }
                }
                .disabled(model.activeWorkout != nil)   // 单槽：占用中禁用，走恢复条继续
                historySection
            }
            .padding(SRSpacing.lg)
        }
        .background(Color.srBackground)
        .navigationTitle("训练")
        .sheet(isPresented: $state.showsActiveSession) {
            ActiveWorkoutView()                          // sheet 天然继承 environmentObject
        }
    }

    // MARK: - 进行中恢复条（§6：进行中训练存在时顶部常驻）

    private func activeBanner(_ active: ActiveWorkout) -> some View {
        SRCard(elevation: .raised) {
            HStack(spacing: SRSpacing.md) {
                SRDotBadge(.srSuccess)
                VStack(alignment: .leading, spacing: 2) {
                    Text("训练进行中")
                        .srFont(.base, .medium)
                        .foregroundStyle(Color.srForeground)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("已进行 \(WorkoutDisplay.elapsed(active.startedAt, now: context.date))")
                            .font(.srMono(.sm))
                            .monospacedDigit()
                            .foregroundStyle(Color.srForegroundMuted)
                    }
                }
                Spacer()
                SRButton("继续", icon: "chevron.right", style: .secondary, size: .sm) {
                    state.showsActiveSession = true
                }
            }
        }
    }

    // MARK: - 历史列表

    private var history: [Workout] { model.workoutHistory }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: SRSpacing.md) {
            HStack(spacing: SRSpacing.sm) {
                Text("历史训练")
                    .srFont(.lg, .medium)
                    .foregroundStyle(Color.srForeground)
                SRCountBadge(count: history.count)
                Spacer()
            }
            if history.isEmpty {
                SRCard {
                    VStack(alignment: .leading, spacing: SRSpacing.xs) {
                        Text("还没有训练记录")
                            .srFont(.lg, .medium)
                            .foregroundStyle(Color.srForeground)
                        Text("点「开始训练」记录第一次训练，结束后会自动生成分析快照。")
                            .srFont(.sm)
                            .foregroundStyle(Color.srForegroundMuted)
                    }
                }
            } else {
                LazyVStack(spacing: SRSpacing.sm) {
                    ForEach(history) { workout in
                        NavigationLink {
                            WorkoutDetailView(workoutID: workout.id)
                        } label: {
                            WorkoutHistoryRow(workout: workout,
                                              customExercises: model.customExercises)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - 历史行（日期 / 主练 / 容量 / PR 徽标，§6 页面地图）

/// 单条历史摘要。优先读落盘的分析快照（口径冻结，§3.3）；无快照（如导入的旧数据）
/// 时退回 WorkoutEngine.sessionStats 现算展示值——计算全在 Core，视图只取数。
private struct WorkoutHistoryRow: View {

    let workout: Workout
    let customExercises: [Exercise]

    private var primaryText: String {
        let keys: [MuscleGroup]
        if let analysis = workout.analysis {
            keys = analysis.primaryMuscles
        } else {
            keys = WorkoutEngine.sessionStats(workout, customExercises: customExercises)
                .muscles.prefix(3).map(\.key)
        }
        return keys.map { ExerciseLibrary.muscleLabel($0) }.joined(separator: "、")
    }

    private var volumeValue: Double {
        workout.analysis?.totals.volumeKg
            ?? WorkoutEngine.sessionStats(workout, customExercises: customExercises).tonnage
    }

    private var prCount: Int { workout.analysis?.prs.count ?? 0 }

    private var durationText: String {
        Formatting.duration(minutes: workout.endedAt.timeIntervalSince(workout.startedAt) / 60)
    }

    var body: some View {
        SRCard(padding: SRSpacing.md) {
            HStack(alignment: .center, spacing: SRSpacing.md) {
                VStack(alignment: .leading, spacing: SRSpacing.xs) {
                    Text(workout.startedAt.formatted(.dateTime.month().day()))
                        .srFont(.lg, .medium)
                        .foregroundStyle(Color.srForeground)
                    Text("\(workout.startedAt.formatted(.dateTime.hour().minute()))"
                         + "–\(workout.endedAt.formatted(.dateTime.hour().minute()))"
                         + " · \(durationText)")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: SRSpacing.xs) {
                    HStack(spacing: SRSpacing.xs) {
                        Text(WorkoutDisplay.kg(volumeValue))
                            .font(.srMono(.md, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.srForeground)
                        Text("kg")
                            .srFont(.sm)
                            .foregroundStyle(Color.srForegroundMuted)
                    }
                    HStack(spacing: SRSpacing.xs) {
                        if prCount > 0 {
                            SRBadge("PR ×\(prCount)", tone: .success)
                        }
                        if let doms = workout.analysis?.domsLevel {
                            SRBadge(WorkoutDisplay.domsText(doms),
                                    tone: WorkoutDisplay.domsTone(doms))
                        }
                    }
                    Text("主练 \(primaryText)")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
