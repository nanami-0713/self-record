import Foundation
import SelfRecordCore

// MARK: - workout 分组（design.md §6 页面地图 / §8 约定 4）
//
// 界面工程师工作区：Sources/SelfRecordUI/Workout/ 由 workout 分组工程师独占。
// 页面：WorkoutListView（历史 + 开始训练 + 进行中恢复条）、ActiveWorkoutView（动作搜索 +
// 自定义动作引导 + 逐组录入 + 复制上一组）、WorkoutDetailView（快照渲染 + 按当前口径
// 再生成 + 7/30/90 阶段分析）。
//
// 约定：
//   - 本文件只放动作方法（extension），不改 AppModel.swift（冻结物 C）；
//   - 数据一律来自 SelfRecordCore 引擎/模型，视图层零业务逻辑——分析快照 =
//     WorkoutEngine.analyzeSession，跨域上下文 = §2.1 冻结聚合 API 组装
//     （DietEngine.dayIntake + TimeEngine.fitnessMinutes）；
//   - SwiftUI 宏禁令（§8 约定 5）：本文件无 UI；页面局部状态在各自 View 文件内
//     用 ObservableObject + @StateObject / @FocusState 承载。

extension AppModel {

    // MARK: - 进行中训练（active.json 崩溃恢复态，design.md §5 / §6 恢复条）

    /// 开始训练：占用进行中槽位（单槽，已占用时不变）。落盘 active.json 供崩溃恢复。
    func startWorkout(now: Date = Date()) async {
        guard activeWorkout == nil else { return }
        activeWorkout = ActiveWorkout(startedAt: now)
        await saveActiveState()
    }

    /// 放弃进行中训练：清恢复态，不写历史。
    func discardActiveWorkout() async {
        activeWorkout = nil
        await saveActiveState()
    }

    /// 往进行中训练追加一个动作条目（新条目从 0 组开始）。
    func addExercise(_ exercise: Exercise) async {
        guard activeWorkout != nil else { return }
        activeWorkout?.entries.append(WorkoutExerciseEntry(exerciseID: exercise.id))
        await saveActiveState()
    }

    /// 删除进行中训练里的一个动作条目（连同其已记组）。
    func removeEntry(id: UUID) async {
        guard activeWorkout != nil else { return }
        activeWorkout?.entries.removeAll { $0.id == id }
        await saveActiveState()
    }

    /// 逐组快速录入：重量 kg（0 = 自重/无重量）× 次数；次数非正不落。
    func logSet(entryID: UUID, weightKg: Double, reps: Int, now: Date = Date()) async {
        guard let active = activeWorkout,
              let idx = active.entries.firstIndex(where: { $0.id == entryID }),
              reps > 0
        else { return }
        activeWorkout?.entries[idx].sets.append(
            WorkoutSet(weightKg: Swift.max(0, weightKg), reps: reps, timestamp: now)
        )
        await saveActiveState()
    }

    /// 删除某动作条目里的一组。
    func removeSet(entryID: UUID, setID: UUID) async {
        guard let active = activeWorkout,
              let idx = active.entries.firstIndex(where: { $0.id == entryID })
        else { return }
        activeWorkout?.entries[idx].sets.removeAll { $0.id == setID }
        await saveActiveState()
    }

    // MARK: - 结束训练 → 分析快照落盘（design.md §3.3 / §6）

    /// 结束训练：生成分析快照并落盘（快照冻结口径，历史报告不随口径升级漂移，
    /// 详情页「再生成」走 regenerateAnalysis 显式覆盖）。恢复建议上下文按
    /// 「训练当天」取数（§2 RecoveryContext 注入契约，注入者 = UI 层组装）。
    /// 全程没有任何组 → 视为放弃，不写历史，返回 nil。
    @discardableResult
    func endActiveWorkout(now: Date = Date(), calendar: DayCalendar = DayCalendar()) async -> Workout? {
        guard let active = activeWorkout else { return nil }
        guard active.entries.contains(where: { !$0.sets.isEmpty }) else {
            activeWorkout = nil
            await saveActiveState()
            return nil
        }
        var workout = Workout(startedAt: active.startedAt,
                              endedAt: now,
                              entries: active.entries,
                              notes: active.notes)
        workout.analysis = WorkoutEngine.analyzeSession(
            workout,
            history: workouts,
            customExercises: customExercises,
            recovery: recoveryContext(workoutStartedAt: active.startedAt, calendar: calendar)
        )
        workouts.append(workout)
        activeWorkout = nil
        await saveWorkouts()
        await saveActiveState()
        return workout
    }

    /// 「按当前口径再生成」（WorkoutDetailView）：同引擎、当前数据源重跑并
    /// 显式覆盖落盘快照。饮食/时间上下文仍按该次训练当天取数。
    func regenerateAnalysis(for workoutID: UUID, calendar: DayCalendar = DayCalendar()) async {
        guard let idx = workouts.firstIndex(where: { $0.id == workoutID }) else { return }
        let workout = workouts[idx]
        workouts[idx].analysis = WorkoutEngine.analyzeSession(
            workout,
            history: workouts,
            customExercises: customExercises,
            recovery: recoveryContext(workoutStartedAt: workout.startedAt, calendar: calendar)
        )
        await saveWorkouts()
    }

    // MARK: - 跨域注入组装（§2 冻结契约的唯一合法通道）

    /// RecoveryContext 组装：bodyweight 取设置；dayIntake / fitnessTimeMinutes
    /// 均按 workoutStartedAt 所在日取数（DietEngine.dayIntake 的 hasPostMeal 判定
    /// 需要 woStartedAt；TimeEngine.fitnessMinutes = 当日 FITNESS_CATS 时间块合计）。
    func recoveryContext(workoutStartedAt: Date, calendar: DayCalendar) -> RecoveryContext {
        let day = DayKey(workoutStartedAt, calendar: calendar)
        return RecoveryContext(
            bodyweightKg: settings.bodyweightKg,
            dayIntake: DietEngine.dayIntake(dietEntries,
                                            day: day,
                                            woStartedAt: workoutStartedAt,
                                            calendar: calendar),
            fitnessTimeMinutes: TimeEngine.fitnessMinutes(timeBlocks, day: day, calendar: calendar)
        )
    }

    // MARK: - 自定义动作（design.md §3.3：查不到时引导创建，id = UUID 字符串）

    /// 创建自定义动作并入库（exercises.json）。名称为空、未选肌群、或与
    /// 内置/自定义库现有动作重名时返回 nil。成功返回新动作供调用方直接
    /// 加入进行中训练。
    @discardableResult
    func addCustomExercise(name: String,
                           primaryMuscles: [MuscleGroup],
                           isBodyweight: Bool) async -> Exercise? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !primaryMuscles.isEmpty else { return nil }
        guard ExerciseLibrary.find(name: trimmed, customExercises: customExercises) == nil else {
            return nil
        }
        let exercise = Exercise(id: UUID().uuidString,
                                name: trimmed,
                                primaryMuscles: primaryMuscles,
                                isCustom: true,
                                isBodyweight: isBodyweight)
        customExercises.append(exercise)
        await saveCustomExercises()
        return exercise
    }

    // MARK: - 展示取数（纯转发 Core，视图层不重复实现解析）

    /// 动作 id → 展示名（内置 id=规范名；自定义取 name；未知原样）。
    func exerciseDisplayName(_ exerciseID: String) -> String {
        ExerciseLibrary.resolve(exerciseID: exerciseID, customExercises: customExercises)?.name
            ?? exerciseID
    }

    /// 历史训练（新→旧）。
    var workoutHistory: [Workout] {
        workouts.sorted { $0.startedAt > $1.startedAt }
    }
}
