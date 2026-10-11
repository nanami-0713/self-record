import Foundation
import SelfRecordCore

// MARK: - settings 分组（design.md §6 页面地图 / §8 约定 4）
//
// 界面工程师工作区：Sources/SelfRecordUI/Settings/ 由 settings 分组工程师独占。
// 页面：SettingsView（体重/单位/主题/睡眠目标/周月预算）、CategoryManagerView
// （分类增删改 + 删除/归档历史归并兜底说明）、DataManagementView（导出/导入
// 三步容错净化 + 双确认 / 清空双确认 + 数据概览）。
//
// 约定：
//   - 本文件只放 settings 分组页面的动作方法（extension），不改 AppModel.swift
//     （冻结物 C）；导出/导入/清空走外壳通用入口 exportBackup / importBackup /
//     eraseAll，本层只做接线与确认（确认弹层在 View 层，§5）；
//   - 分类管理语义全部委托 Core（TimeEngine.addCategory / deleteCategory /
//     archiveCategory——历史块归并兜底在引擎完成），视图层零业务逻辑；
//   - SwiftUI 宏禁令（§8 约定 5）：页面局部状态放各页 ObservableObject
//     （见各 View 文件），不写 @State；
//   - 颜色/组件只用 DesignSystem 语义名。

extension AppModel {

    // MARK: - 设置项写入（SettingsView）

    /// 写入整份设置并落盘（值类型快照 → DataStore 写回，§5 编辑流程）。
    /// 绑定路径逐字段改 `model.settings` 后组新快照调本方法（AppSettings 为
    /// Sendable 值类型，无闭包跨 actor 问题）。
    func applySettings(_ new: AppSettings) async {
        settings = new
        await saveSettings()
    }

    // MARK: - 时间分类管理（CategoryManagerView；语义全部在 TimeEngine，§3.1）

    /// 新建自定义分类。id 由 UI 生成（UUID 字符串，过 Core 白名单正则）；
    /// hue 限 8 个彩色档（neutral 为兜底专属，Core 层守一道）。失败 → false。
    @discardableResult
    func addCategory(label: String, hue: ChartHue) async -> Bool {
        guard let updated = TimeEngine.addCategory(id: UUID().uuidString,
                                                   label: label, hue: hue,
                                                   to: categories) else { return false }
        categories = updated
        await saveCategories()
        return true
    }

    /// 编辑分类（改名 / 改色）。兜底分类不可改色（neutral 为其专属档，§4.1）；
    /// 其余分类的 hue 不接受 neutral。名称去空白非空、截 64 字符（与净化同界）。
    /// 返回 false = 目标不存在或参数不合法。
    @discardableResult
    func updateCategory(id: String, label: String, hue: ChartHue) async -> Bool {
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return false }
        let target = categories[index]
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard target.isFallback || hue != .neutral else { return false }
        var updated = categories
        updated[index].label = String(trimmed.prefix(SanitizeLimits.labelMaxLength))
        updated[index].hue = target.isFallback ? .neutral : hue
        categories = updated
        await saveCategories()
        return true
    }

    /// 删除 / 归档分类的结果（对 TimeEngine.CategoryMutationOutcome 的 UI 落点翻译）。
    enum CategoryMutationResult: Equatable, Sendable {
        /// 已应用；`migratedCount` = 改挂兜底分类的历史时间块数（toast 文案用）。
        case applied(migratedCount: Int)
        /// 目标是兜底分类：不可删 / 不可归档（§4 isFallback 注释）。
        case rejectedFallback
        /// 分类表中无此 id。
        case notFound
    }

    /// 删除分类：历史块全部改挂兜底分类（引擎完成，§3.1），分类与块双写回。
    func deleteCategory(id: String) async -> CategoryMutationResult {
        let usage = timeBlocks.filter { $0.categoryID == id }.count
        switch TimeEngine.deleteCategory(id: id, categories: categories, blocks: timeBlocks) {
        case .applied(let newCategories, let newBlocks):
            categories = newCategories
            timeBlocks = newBlocks
            await saveCategories()
            await saveTimeBlocks()
            return .applied(migratedCount: usage)
        case .rejectedFallback:
            return .rejectedFallback
        case .notFound:
            return .notFound
        }
    }

    /// 归档分类（从选择列表退役，历史块同样归并兜底，§3.1）。
    func archiveCategory(id: String) async -> CategoryMutationResult {
        let usage = timeBlocks.filter { $0.categoryID == id }.count
        switch TimeEngine.archiveCategory(id: id, categories: categories, blocks: timeBlocks) {
        case .applied(let newCategories, let newBlocks):
            categories = newCategories
            timeBlocks = newBlocks
            await saveCategories()
            await saveTimeBlocks()
            return .applied(migratedCount: usage)
        case .rejectedFallback:
            return .rejectedFallback
        case .notFound:
            return .notFound
        }
    }

    /// 恢复已归档分类（仅恢复可选性；此前归并到兜底分类的历史块不回迁——
    /// 引擎语义如此，UI 文案已注明）。
    @discardableResult
    func restoreCategory(id: String) async -> Bool {
        guard let index = categories.firstIndex(where: { $0.id == id }),
              categories[index].isArchived
        else { return false }
        var updated = categories
        updated[index].isArchived = false
        categories = updated
        await saveCategories()
        return true
    }

    /// 各分类的历史时间块数（CategoryManagerView 列表「N 段记录」展示）。
    func categoryUsageCounts() -> [String: Int] {
        timeBlocks.reduce(into: [String: Int]()) { counts, block in
            counts[block.categoryID, default: 0] += 1
        }
    }

    // MARK: - 数据概览（DataManagementView「存储占用概览」）

    /// 当前各域记录数 + 估算落盘体积（按 DataStore 同款编码选项序列化内存快照；
    /// 个人数据量级下可同步计算）。
    struct DataOverview: Equatable, Sendable {
        public var categories: Int
        public var timeBlocks: Int
        public var sleepSessions: Int
        public var workouts: Int
        public var dietEntries: Int
        public var expenses: Int
        public var customFoods: Int
        public var customExercises: Int
        /// 各域 JSON 估算字节数之和（与磁盘编码选项一致：iso8601 + pretty + sorted）。
        public var totalBytes: Int
    }

    /// 概览输入快照：主线程取各域数组拷贝（值类型，Sendable），体积编码在
    /// 后台执行——8 个域 pretty-print 编码在导入大备份后可达秒级，不该卡主线程。
    struct DataOverviewInput: Sendable {
        var categories: [TimeCategory]
        var timeBlocks: [TimeBlock]
        var sleepSessions: [SleepSession]
        var workouts: [Workout]
        var dietEntries: [DietEntry]
        var expenses: [Expense]
        var customFoods: [CustomFood]
        var customExercises: [Exercise]
    }

    /// 取当前内存快照的概览输入（计数即时可得，编码另走 `computeOverview`）。
    func dataOverviewInput() -> DataOverviewInput {
        DataOverviewInput(categories: categories,
                          timeBlocks: timeBlocks,
                          sleepSessions: sleepSessions,
                          workouts: workouts,
                          dietEntries: dietEntries,
                          expenses: expenses,
                          customFoods: customFoods,
                          customExercises: customExercises)
    }

    /// 后台编码体积估算（按 DataStore 同款编码选项序列化；
    /// nonisolated——输入快照自包含，不触主线程状态）。
    nonisolated static func computeOverview(_ input: DataOverviewInput) -> DataOverview {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func bytes<T: Encodable>(_ value: T) -> Int {
            (try? encoder.encode(value))?.count ?? 0
        }
        return DataOverview(
            categories: input.categories.count,
            timeBlocks: input.timeBlocks.count,
            sleepSessions: input.sleepSessions.count,
            workouts: input.workouts.count,
            dietEntries: input.dietEntries.count,
            expenses: input.expenses.count,
            customFoods: input.customFoods.count,
            customExercises: input.customExercises.count,
            totalBytes: bytes(input.categories) + bytes(input.timeBlocks)
                + bytes(input.sleepSessions) + bytes(input.workouts)
                + bytes(input.dietEntries) + bytes(input.expenses)
                + bytes(input.customFoods) + bytes(input.customExercises))
    }

    /// 同步便捷入口（小数据量 / 测试用）；页面路径走 refresh 的后台版。
    func dataOverview() -> DataOverview {
        Self.computeOverview(dataOverviewInput())
    }

    // MARK: - 导入预检（三步容错净化的干跑；落盘走外壳 importBackup）

    /// 干跑净化：与 `store.importBackup` 同一条 `BackupSanitizer.sanitizeDocument`
    /// 管线（50MB 预检 → 元素级容错解码 → 值上业务校验），但不落盘——
    /// 供导入预览页展示净化后摘要，双确认后由调用方再走外壳 `importBackup`。
    nonisolated static func sanitizeForPreview(_ data: Data) throws -> BackupDocument {
        try BackupSanitizer.sanitizeDocument(from: data)
    }
}
