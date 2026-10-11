import Combine
import Foundation
import SelfRecordCore

// MARK: - AppModel 外壳（design.md §8 约定 4；骨架冻结物 C）
//
// 冻结约定：本文件只含 DataStore 装配、各域只读快照（@Published）与通用保存入口。
// 各界面分组的动作方法放各自目录的 AppModel+<分组>.swift（extension），**不改本文件**；
// 发现缺口报修复工程师，不私改（§2 冻结物 C / §8 约定 3）。
//
// SwiftUI 宏禁令（§0-2 / §8 约定 5）：本包禁 @State / @Observable 等 SwiftUI 宏——
// 状态管理 = ObservableObject + @Published（propertyWrapper，实测可编译）。
// AppModel 为 @MainActor 主线程状态容器（§8 约定 1）。

@MainActor
public final class AppModel: ObservableObject {

    // MARK: - 各域只读快照（View 绑定；写入经分组 extension 的动作方法）

    @Published public internal(set) var settings: AppSettings = AppSettings()
    @Published public internal(set) var categories: [TimeCategory] = TimeCategory.defaults
    @Published public internal(set) var timeBlocks: [TimeBlock] = []
    @Published public internal(set) var sleepSessions: [SleepSession] = []
    @Published public internal(set) var workouts: [Workout] = []
    @Published public internal(set) var customExercises: [Exercise] = []
    @Published public internal(set) var dietEntries: [DietEntry] = []
    @Published public internal(set) var customFoods: [CustomFood] = []
    @Published public internal(set) var expenses: [Expense] = []

    /// 崩溃恢复态（§5 active.json：启动即读，UI 层常驻状态条）。
    @Published public internal(set) var activeTimer: ActiveTimer?
    @Published public internal(set) var activeWorkout: ActiveWorkout?

    // MARK: - DataStore 装配

    public let store: DataStore

    public init(store: DataStore) {
        self.store = store
    }

    /// 默认装配：`<ApplicationSupport>/SelfRecord/`（§5）。
    public init(directory: URL = DataStore.defaultDirectory()) throws {
        self.store = try DataStore(directory: directory)
    }

    // MARK: - 启动全量载入（§5：启动全量载入内存值类型快照）

    /// 并发读盘（actor 串行执行读，但十次 actor hop 并起来），赋值集中到
    /// 同一函数尾段——同一 runloop tick 内的多次 objectWillChange 会被
    /// SwiftUI 合并为一轮刷新（原先逐条 await 赋值，首帧后最多重渲染 11 轮）。
    public func loadAll() async {
        async let aSettings = store.loadSettings()
        async let aCategories = store.loadCategories()
        async let aTimeBlocks = store.loadTimeBlocks()
        async let aSleepSessions = store.loadSleepSessions()
        async let aWorkouts = store.loadWorkouts()
        async let aCustomExercises = store.loadCustomExercises()
        async let aDietEntries = store.loadDietEntries()
        async let aCustomFoods = store.loadCustomFoods()
        async let aExpenses = store.loadExpenses()
        async let aActive = store.loadActive()

        settings = await aSettings
        let loadedCategories = await aCategories
        // 首启/空分类文档 → 播种默认 9 分类（§4.1）；含 fallback 修正已在净化层完成
        categories = loadedCategories.isEmpty ? TimeCategory.defaults : loadedCategories
        timeBlocks = await aTimeBlocks
        sleepSessions = await aSleepSessions
        workouts = await aWorkouts
        customExercises = await aCustomExercises
        dietEntries = await aDietEntries
        customFoods = await aCustomFoods
        expenses = await aExpenses
        let active = await aActive
        activeTimer = active?.timer
        activeWorkout = active?.workout
    }

    // MARK: - 通用保存入口（编辑流程末段：新快照 → DataStore 写回 → UI 自动刷新）

    public func saveSettings() async { await store.save(settings: settings) }
    public func saveCategories() async { await store.save(categories: categories) }
    public func saveTimeBlocks() async { await store.save(timeBlocks: timeBlocks) }
    public func saveSleepSessions() async { await store.save(sleepSessions: sleepSessions) }
    public func saveWorkouts() async { await store.save(workouts: workouts) }
    public func saveCustomExercises() async { await store.save(customExercises: customExercises) }
    public func saveDietEntries() async { await store.save(dietEntries: dietEntries) }
    public func saveCustomFoods() async { await store.save(customFoods: customFoods) }
    public func saveExpenses() async { await store.save(expenses: expenses) }
    public func saveActiveState() async {
        await store.save(active: ActiveStateRecord(timer: activeTimer, workout: activeWorkout))
    }

    // MARK: - 备份 / 清空（设置页 DataManagementView 接线；确认弹层在 View 层）

    /// 导出全量 JSON（文件名带日期、AI Key 剔除由 BackupDocument 结构保证——无该字段）。
    public func exportBackup(now: Date = Date()) async throws -> Data {
        try await store.exportBackup(now: now)
    }

    /// 导入：净化（元素级容错）→ 覆盖落盘 → 刷新全部快照。返回净化后的文档。
    @discardableResult
    public func importBackup(_ data: Data) async throws -> BackupDocument {
        let document = try await store.importBackup(from: data)
        await loadAll()
        return document
    }

    public func eraseAll() async throws {
        try await store.eraseAll()
        await loadAll()
    }
}
