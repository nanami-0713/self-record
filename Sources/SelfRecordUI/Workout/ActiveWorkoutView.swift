import SelfRecordCore
import SwiftUI

// MARK: - ActiveWorkoutView（design.md §6「训练」进行中页）
//
// 职责：动作搜索（ExerciseLibrary.search 精确/前缀/包含打分，§3.3）+
// 自定义动作引导（查不到 → 多选肌群 sheet 创建）+ 逐组快速录入（键盘优先，
// 重量×次数）+ 复制上一组一键；结束 → AppModel.endActiveWorkout 生成分析
// 快照并落盘（§3.3）。
//
// 宏禁令（§8 约定 5）：页面局部状态 = ObservableObject + @StateObject；
// 表单焦点 = View 内 @FocusState（例外条款，焦点态不得挪进 ObservableObject）。
//
// QuickSetField 说明：逐组录入需要外部 FocusState 驱动（重量 → 次数 → 记录 →
// 回到重量的键盘流），设计系统 SRField 的焦点是其内部 Bool 态、不外露——此处
// 按同一套令牌（三态边框 / 控件高度 / hit≥44 / SRKeyboard）自建私有小输入框，
// 不新增任何样式档。

/// 逐组录入的焦点域（View 内 @FocusState 的值类型）。
private enum SetField: Hashable {
    case weight(UUID)
    case reps(UUID)
}

/// 页面局部状态（ObservableObject 路径）。
final class ActiveWorkoutState: ObservableObject {
    @Published var query = ""
    /// entryID → 重量 / 次数输入（字典 @Published 支持 `[key, default:]` 下标 Binding）。
    @Published var weightText: [UUID: String] = [:]
    @Published var repsText: [UUID: String] = [:]
    /// 自定义动作引导 sheet。
    @Published var showsCustomSheet = false
    @Published var confirmFinish = false
    @Published var confirmDiscard = false
}

public struct ActiveWorkoutView: View {

    @EnvironmentObject private var model: AppModel
    @StateObject private var state = ActiveWorkoutState()
    @FocusState private var setFocus: SetField?
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        Group {
            if let active = model.activeWorkout {
                session(active)
            } else {
                idlePlaceholder
            }
        }
        .background(Color.srBackground)
        .sheet(isPresented: $state.showsCustomSheet) {
            AddCustomExerciseView(prefilledName: trimmedQuery) {
                state.query = ""
            }
            .interactiveDismissDisabled(true)   // 表单防误关（§6 全局交互约定）
        }
        .confirmationDialog(hasSets ? "结束训练？" : "结束训练？（还没有记录任何组）",
                            isPresented: $state.confirmFinish,
                            titleVisibility: .visible) {
            Button(hasSets ? "结束并生成分析" : "结束并丢弃", role: hasSets ? nil : .destructive) {
                Task {
                    await model.endActiveWorkout()
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(hasSets
                 ? "将按当前体重、今日饮食与健身时间记录生成分析快照（恢复建议会读实际蛋白摄入）。"
                 : "没有任何组的训练不会写入历史。")
        }
        .confirmationDialog("放弃本次训练？", isPresented: $state.confirmDiscard, titleVisibility: .visible) {
            Button("放弃（已记的组不保存）", role: .destructive) {
                Task {
                    await model.discardActiveWorkout()
                    dismiss()
                }
            }
            Button("继续训练", role: .cancel) {}
        }
    }

    // MARK: - 会话主体

    private func session(_ active: ActiveWorkout) -> some View {
        ScrollView {
            VStack(spacing: SRSpacing.lg) {
                header(active)
                searchSection
                entriesSection(active)
            }
            .padding(SRSpacing.lg)
        }
        .safeAreaInset(edge: .bottom) { footer }
    }

    private func header(_ active: ActiveWorkout) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: SRSpacing.xs) {
                Text("训练进行中")
                    .srFont(.lg, .medium)
                    .foregroundStyle(Color.srForeground)
                Text("开始于 \(active.startedAt.formatted(.dateTime.hour().minute()))"
                     + " · \(active.entries.count) 个动作"
                     + " · \(active.entries.reduce(0) { $0 + $1.sets.count }) 组")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(WorkoutDisplay.elapsed(active.startedAt, now: context.date))
                    .font(.srMono(.xl, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.srForeground)
            }
        }
    }

    // MARK: - 动作搜索 + 自定义动作引导

    private var trimmedQuery: String {
        state.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [Exercise] {
        guard !trimmedQuery.isEmpty else { return [] }
        return ExerciseLibrary.search(trimmedQuery, customExercises: model.customExercises)
    }

    private var searchSection: some View {
        // 打分搜索单次求值（isEmpty/prefix/count 三处原先各跑一遍全库搜索）
        let results = self.results
        return VStack(alignment: .leading, spacing: SRSpacing.sm) {
            SRField(text: $state.query,
                    placeholder: "搜索动作：深蹲、划船、bench press…",
                    icon: "magnifyingglass")
            if trimmedQuery.isEmpty {
                quickPicks
            } else if results.isEmpty {
                customGuide
            } else {
                VStack(spacing: SRSpacing.xs) {
                    ForEach(results.prefix(8)) { exercise in
                        exerciseRow(exercise)
                    }
                    if results.count > 8 {
                        Text("前 8 个结果，继续输入可以更精确")
                            .srFont(.sm)
                            .foregroundStyle(Color.srForegroundSubtle)
                    }
                }
            }
        }
    }

    /// 空查询时的快速添加（内置库前 8 项）。
    private var quickPicks: some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            Text("常用动作")
                .srFont(.sm, .medium)
                .foregroundStyle(Color.srForegroundMuted)
            ForEach(Array(ExerciseLibrary.all.prefix(8))) { exercise in
                exerciseRow(exercise)
            }
        }
    }

    /// 查不到 → 自定义动作引导（§6：多选肌群 sheet）。
    private var customGuide: some View {
        SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.sm) {
                Text("没找到「\(trimmedQuery)」")
                    .srFont(.lg, .medium)
                    .foregroundStyle(Color.srForeground)
                Text("可以创建自定义动作：选择它主要练哪些部位，容量、PR 与 DOMS 分析会照常统计。")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
                SRButton("创建自定义动作", icon: "plus", style: .secondary, size: .sm) {
                    state.showsCustomSheet = true
                }
            }
        }
    }

    private func exerciseRow(_ exercise: Exercise) -> some View {
        Button {
            Task { await model.addExercise(exercise) }
        } label: {
            HStack(spacing: SRSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .srFont(.base, .medium)
                        .foregroundStyle(Color.srForeground)
                    Text(exercise.primaryMuscles.map { ExerciseLibrary.muscleLabel($0) }
                        .joined(separator: "、"))
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                }
                Spacer()
                HStack(spacing: SRSpacing.xs) {
                    if exercise.isCustom { SRBadge("自定义", tone: .info) }
                    if exercise.isBodyweight { SRBadge("自重") }
                    if exercise.isCardio { SRBadge("有氧") }
                    if exercise.isEccentricHeavy { SRBadge("离心大") }
                }
                Image(systemName: "plus")
                    .font(.sr(.sm))
                    .foregroundStyle(Color.srForegroundMuted)
            }
            .padding(.horizontal, SRSpacing.md)
            .padding(.vertical, SRSpacing.sm)
            .srSurface(.surface, radius: SRRadius.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("添加动作 \(exercise.name)")
    }

    // MARK: - 已添加动作 · 逐组录入

    private func entriesSection(_ active: ActiveWorkout) -> some View {
        VStack(spacing: SRSpacing.md) {
            if active.entries.isEmpty {
                SRCard {
                    VStack(alignment: .leading, spacing: SRSpacing.xs) {
                        Text("从上方搜索并添加第一个动作")
                            .srFont(.lg, .medium)
                            .foregroundStyle(Color.srForeground)
                        Text("查不到的动作可以创建自定义动作，选好肌群即可照常计入分析。")
                            .srFont(.sm)
                            .foregroundStyle(Color.srForegroundMuted)
                    }
                }
            }
            ForEach(active.entries) { entry in
                ExerciseEntryCard(
                    entry: entry,
                    name: model.exerciseDisplayName(entry.exerciseID),
                    weightText: Binding(
                        get: { state.weightText[entry.id] ?? "" },
                        set: { state.weightText[entry.id] = $0 }
                    ),
                    repsText: Binding(
                        get: { state.repsText[entry.id] ?? "" },
                        set: { state.repsText[entry.id] = $0 }
                    ),
                    focus: $setFocus,
                    onLog: { weightKg, reps in
                        Task {
                            await model.logSet(entryID: entry.id, weightKg: weightKg, reps: reps)
                            state.weightText[entry.id] = ""
                            state.repsText[entry.id] = ""
                            setFocus = .weight(entry.id)   // 连续记录：回到重量框
                        }
                    },
                    onCopyLast: {
                        guard let last = entry.sets.last else { return }
                        Task {
                            await model.logSet(entryID: entry.id,
                                               weightKg: last.weightKg,
                                               reps: last.reps)
                        }
                    },
                    onRemoveEntry: {
                        Task { await model.removeEntry(id: entry.id) }
                    },
                    onRemoveSet: { setID in
                        Task { await model.removeSet(entryID: entry.id, setID: setID) }
                    })
            }
        }
    }

    // MARK: - 底部操作条

    private var footer: some View {
        HStack(spacing: SRSpacing.md) {
            SRButton("放弃", icon: "trash", style: .ghost, size: .md) {
                state.confirmDiscard = true
            }
            Spacer()
            SRButton("结束训练", icon: "checkmark", style: .primary, size: .md) {
                state.confirmFinish = true
            }
        }
        .padding(.horizontal, SRSpacing.lg)
        .padding(.vertical, SRSpacing.sm)
        .background(Color.srSurface)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.srBorder).frame(height: 1)
        }
    }

    /// 训练已被结束/放弃（sheet 仍短暂在屏）时的兜底画面。
    private var idlePlaceholder: some View {
        VStack(spacing: SRSpacing.md) {
            Text("没有进行中的训练")
                .srFont(.lg, .medium)
                .foregroundStyle(Color.srForegroundMuted)
            SRButton("返回", style: .secondary, size: .sm) { dismiss() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasSets: Bool {
        model.activeWorkout?.entries.contains { !$0.sets.isEmpty } ?? false
    }
}

// MARK: - 单动作条目卡（组列表 + 逐组快速录入 + 复制上一组）

private struct ExerciseEntryCard: View {

    let entry: WorkoutExerciseEntry
    let name: String
    @Binding var weightText: String
    @Binding var repsText: String
    /// View 内 @FocusState 的投影（焦点态留在 View，§8 约定 5）。
    let focus: FocusState<SetField?>.Binding
    let onLog: (Double, Int) -> Void
    let onCopyLast: () -> Void
    let onRemoveEntry: () -> Void
    let onRemoveSet: (UUID) -> Void

    /// 重量输入解析：空 = 自重(0)；解析失败 → nil（红框）。
    private var weightValue: Double? {
        let t = weightText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return 0 }
        guard let v = Double(t), v >= 0 else { return nil }
        return v
    }

    /// 次数输入解析：必须为正整数。
    private var repsValue: Int? {
        let t = repsText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let v = Int(t), v > 0 else { return nil }
        return v
    }

    private var canLog: Bool { weightValue != nil && repsValue != nil }

    var body: some View {
        SRCard(padding: SRSpacing.md) {
            VStack(alignment: .leading, spacing: SRSpacing.sm) {
                HStack(spacing: SRSpacing.sm) {
                    Text(name)
                        .srFont(.lg, .medium)
                        .foregroundStyle(Color.srForeground)
                    SRBadge("\(entry.sets.count) 组")
                    Spacer()
                    SRButton("复制上一组", icon: "doc.on.doc", style: .subtle, size: .sm) {
                        onCopyLast()
                    }
                    .disabled(entry.sets.isEmpty)
                }
                setsList
                quickEntry
            }
        }
        .contextMenu {
            Button("删除该动作（含已记的组）", role: .destructive) { onRemoveEntry() }
        }
    }

    @ViewBuilder
    private var setsList: some View {
        if entry.sets.isEmpty {
            Text("还没有组——输入重量×次数（重量留空 = 自重）后点「记录」")
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundSubtle)
        } else {
            VStack(spacing: SRSpacing.xs) {
                ForEach(Array(entry.sets.enumerated()), id: \.element.id) { index, set in
                    HStack(spacing: SRSpacing.sm) {
                        Text("\(index + 1)")
                            .font(.srMono(.sm))
                            .monospacedDigit()
                            .foregroundStyle(Color.srForegroundSubtle)
                            .frame(width: 20, alignment: .trailing)
                        Text(WorkoutDisplay.setSummary(set))
                            .font(.srMono(.base))
                            .monospacedDigit()
                            .foregroundStyle(Color.srForeground)
                        Spacer()
                    }
                    .padding(.horizontal, SRSpacing.sm)
                    .padding(.vertical, SRSpacing.xs)
                    .srSurface(.sunken, radius: SRRadius.md)
                    .contextMenu {
                        Button("删除该组", role: .destructive) { onRemoveSet(set.id) }
                    }
                }
            }
        }
    }

    /// 键盘优先录入流：重量(回车)→ 次数(回车)→ 记录 → 焦点回重量框。
    private var quickEntry: some View {
        HStack(spacing: SRSpacing.sm) {
            QuickSetField(text: $weightText,
                          placeholder: "重量",
                          unit: "kg",
                          field: .weight(entry.id),
                          focus: focus,
                          keyboard: .decimal,
                          isInvalid: weightText.isEmpty ? false : weightValue == nil)
                .onSubmit { focus.wrappedValue = .reps(entry.id) }
            Text("×")
                .srFont(.base)
                .foregroundStyle(Color.srForegroundMuted)
            QuickSetField(text: $repsText,
                          placeholder: "次数",
                          unit: "次",
                          field: .reps(entry.id),
                          focus: focus,
                          keyboard: .number,
                          isInvalid: repsText.isEmpty ? false : repsValue == nil)
                .onSubmit {
                    if let w = weightValue, let r = repsValue { onLog(w, r) }
                }
            SRButton("记录", style: .primary, size: .sm) {
                if let w = weightValue, let r = repsValue { onLog(w, r) }
            }
            .disabled(!canLog)
        }
    }
}

// MARK: - 逐组录入小输入框（外部 FocusState 驱动；令牌同 SRField，见文件头注）

private struct QuickSetField: View {

    @Binding var text: String
    let placeholder: String
    let unit: String
    let field: SetField
    let focus: FocusState<SetField?>.Binding
    let keyboard: SRKeyboard
    let isInvalid: Bool

    private var isFocused: Bool { focus.wrappedValue == field }

    var body: some View {
        HStack(spacing: SRSpacing.xs) {
            TextField(placeholder, text: $text)
                .srFont(.base)
                .foregroundStyle(Color.srForeground)
                .focused(focus, equals: field)
                .srKeyboard(keyboard)
                .multilineTextAlignment(.trailing)
            Text(unit)
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)
        }
        .padding(.horizontal, SRSpacing.md)
        .frame(width: 104, height: SRControlSize.sm.height)
        .frame(minHeight: 44)                       // hit 区 ≥44（§7.3）
        .background(Color.srSurface)
        .clipShape(RoundedRectangle(cornerRadius: SRRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SRRadius.md, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .animation(SRMotion.fast, value: isFocused)
        .animation(SRMotion.fast, value: isInvalid)
    }

    /// 三态边框（默认 border_strong / 聚焦 focus / 失败 danger），同 SRField。
    private var borderColor: Color {
        if isInvalid { return .srDanger }
        if isFocused { return .srFocus }
        return .srBorderStrong
    }
}

// MARK: - 自定义动作引导（多选肌群 sheet，§6 页面地图）

private final class CustomExerciseDraft: ObservableObject {
    @Published var name: String
    @Published var primary: Set<MuscleGroup> = []
    @Published var isBodyweight = false
    @Published var errorMessage: String?
    @Published var isSaving = false

    init(name: String) {
        self.name = name
    }

    func toggle(_ muscle: MuscleGroup) {
        primary.formSymmetricDifference([muscle])
    }
}

private struct AddCustomExerciseView: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: CustomExerciseDraft
    /// 创建成功后回调（清空搜索词，回到干净的下一次搜索）。
    let onCreated: () -> Void

    init(prefilledName: String, onCreated: @escaping () -> Void) {
        self.onCreated = onCreated
        _draft = StateObject(wrappedValue: CustomExerciseDraft(name: prefilledName))
    }

    private var canCreate: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.primary.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SRSpacing.lg) {
                VStack(alignment: .leading, spacing: SRSpacing.xs) {
                    Text("创建自定义动作")
                        .srFont(.xl, .semibold)
                        .foregroundStyle(Color.srForeground)
                    Text("选好主要肌群，容量分摊、PR 与 DOMS 计分会照常生效。")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                }
                VStack(alignment: .leading, spacing: SRSpacing.sm) {
                    Text("名称")
                        .srFont(.sm, .medium)
                        .foregroundStyle(Color.srForegroundMuted)
                    SRField(text: $draft.name, placeholder: "动作名称", icon: nil,
                            showsClearButton: false)
                }
                VStack(alignment: .leading, spacing: SRSpacing.sm) {
                    Text("主要练哪些部位（多选）")
                        .srFont(.sm, .medium)
                        .foregroundStyle(Color.srForegroundMuted)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              spacing: SRSpacing.xs) {
                        ForEach(MuscleGroup.allCases, id: \.self) { muscle in
                            muscleToggle(muscle)
                        }
                    }
                }
                SRSwitch(isOn: $draft.isBodyweight, label: "自重动作（容量记 0，组数计入）")
                if let error = draft.errorMessage {
                    Text(error)
                        .srFont(.sm)
                        .foregroundStyle(Color.srDanger)
                }
                HStack(spacing: SRSpacing.md) {
                    SRButton("取消", style: .ghost, size: .md) { dismiss() }
                    Spacer()
                    SRButton("创建并加入训练", style: .primary, size: .md, isLoading: draft.isSaving) {
                        create()
                    }
                    .disabled(!canCreate)
                }
            }
            .padding(SRSpacing.lg)
        }
        .background(Color.srBackground)
    }

    /// 肌群多选：勾选框（SRCheck）与整行都能切换（同一 toggle，不嵌套按钮）。
    private func muscleToggle(_ muscle: MuscleGroup) -> some View {
        let selected = draft.primary.contains(muscle)
        return HStack(spacing: SRSpacing.sm) {
            SRCheck(state: selected ? .on : .off,
                    accessibilityLabel: ExerciseLibrary.muscleLabel(muscle)) {
                draft.toggle(muscle)
            }
            Text(ExerciseLibrary.muscleLabel(muscle))
                .srFont(.base)
                .foregroundStyle(Color.srForeground)
            Spacer()
        }
        .padding(.horizontal, SRSpacing.sm)
        .padding(.vertical, SRSpacing.xs)
        .srSurface(.sunken, radius: SRRadius.md)
        .contentShape(Rectangle())
        .onTapGesture { draft.toggle(muscle) }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func create() {
        let muscles = MuscleGroup.allCases.filter { draft.primary.contains($0) }
        draft.isSaving = true
        draft.errorMessage = nil
        Task {
            if let exercise = await model.addCustomExercise(name: draft.name,
                                                            primaryMuscles: muscles,
                                                            isBodyweight: draft.isBodyweight) {
                await model.addExercise(exercise)
                onCreated()
                dismiss()
            } else {
                draft.errorMessage = "创建失败：名称为空、未选肌群，或与现有动作重名。"
            }
            draft.isSaving = false
        }
    }
}
