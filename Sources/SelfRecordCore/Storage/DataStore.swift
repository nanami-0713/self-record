import Foundation

// MARK: - 分域 JSON 文件仓库（design.md §5；骨架冻结物 A 的一部分）

/// 自研 `DataStore` actor（不用 SwiftData / Core Data，选型理由见 §5）：
/// - 分域 JSON 文件（§5 布局），写入粒度小、并行模块测试互不干扰；
/// - 原子写（临时文件 + rename，`Data.write(options: .atomic)` 即此语义）；
/// - 每次变更立即写一次 + 150ms 防抖合并后续写（lifttime「commit 立即写 + 防抖再写」
///   语义，store.js:210-216 防抖 120ms，取 150ms 同语义近值）；
/// - 读取：本地读盘与导入备份走同一条净化管线（`BackupSanitizer`，§4 三步）；
/// - 目录参数化注入（测试用临时目录，§10）。
public actor DataStore {

    // MARK: 域文件（§5 布局）

    private enum Domain: String, CaseIterable {
        case settings, categories, active
        case time, sleep, workouts, exercises, diet, foods, expenses
        case plans        // budget 模块自定义周期计划（BudgetPlans.swift；2026-10-06 增）
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SelfRecord", isDirectory: true)
    }

    private let directory: URL
    private let decoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private let encoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// 防抖合并区：最近一次编码结果 per 域（150ms 内的后续 save 只更新这里）。
    private var pendingWrites: [Domain: Data] = [:]
    private var debounceTasks: [Domain: Task<Void, Never>] = [:]
    /// 防抖间隔（默认 150ms；测试可注入超长间隔，把 flush 时机交给显式调用——
    /// 避免测试对「操作在 150ms 内完成」的隐含时序假设）。
    private let debounceNanoseconds: UInt64
    public static let defaultDebounceNanoseconds: UInt64 = 150_000_000

    public init(directory: URL,
                debounceNanoseconds: UInt64 = DataStore.defaultDebounceNanoseconds) throws {
        self.directory = directory
        self.debounceNanoseconds = debounceNanoseconds
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    /// 便捷构造：默认 `<ApplicationSupport>/SelfRecord/`。
    public static func openDefault() throws -> DataStore {
        try DataStore(directory: DataStore.defaultDirectory())
    }

    private func fileURL(_ domain: Domain) -> URL {
        directory.appendingPathComponent("\(domain.rawValue).json")
    }

    private func readData(_ domain: Domain) -> Data? {
        let url = fileURL(domain)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    // MARK: 写入（立即写 + 防抖合并）

    private func write<T: Encodable>(_ value: T, to domain: Domain) {
        guard let data = try? encoder.encode(value) else { return }
        let first = pendingWrites[domain] == nil
        pendingWrites[domain] = data
        if first {
            // 每次变更（first 起始）立即写一次；150ms 内后续变更合并为最后一次写
            try? atomicWrite(data, to: fileURL(domain))
        }
        scheduleFlush(domain)
    }

    private func scheduleFlush(_ domain: Domain) {
        debounceTasks[domain]?.cancel()
        debounceTasks[domain] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNanoseconds
                                      ?? DataStore.defaultDebounceNanoseconds)
            guard let self, !Task.isCancelled else { return }
            await self.flushNow()
        }
    }

    /// 立即落盘全部 pending（防抖到期 / 显式调用，如应用退后台）。
    public func flushNow() {
        for (domain, data) in pendingWrites {
            try? atomicWrite(data, to: fileURL(domain))
        }
        pendingWrites.removeAll()
        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
    }

    /// 清空防抖账（取消全部定时器并丢弃 pending）：导入覆盖各域文件前调用，
    /// 否则 150ms 窗口内已入队的旧快照会在导入后由 `flushNow` 写回，
    /// 覆盖刚导入的数据（内存/磁盘分叉，下次启动回退导入前状态）。
    private func clearPendingWrites() {
        pendingWrites.removeAll()
        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
    }

    // MARK: 载入（本地读盘走净化管线，与导入同一条——§1 原则 3）

    public func loadSettings() -> AppSettings {
        guard let data = readData(.settings),
              let raw = try? decoder.decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return BackupSanitizer.sanitize(raw)
    }

    /// 空文件/首启返回 []（由 AppModel 决定是否播种 `TimeCategory.defaults`）。
    public func loadCategories() -> [TimeCategory] {
        guard let data = readData(.categories) else { return [] }
        return BackupSanitizer.sanitize(
            BackupSanitizer.lenientArray(from: data, decoder: decoder))
    }

    /// 崩溃恢复态（active.json），启动即读（§5）。
    public func loadActive() -> ActiveStateRecord? {
        guard let data = readData(.active) else { return nil }
        return try? decoder.decode(ActiveStateRecord.self, from: data)
    }

    public func loadTimeBlocks() -> [TimeBlock] {
        guard let data = readData(.time) else { return [] }
        return BackupSanitizer.sanitize(
            BackupSanitizer.lenientArray(from: data, decoder: decoder))
    }

    public func loadSleepSessions() -> [SleepSession] {
        guard let data = readData(.sleep) else { return [] }
        return BackupSanitizer.sanitize(
            BackupSanitizer.lenientArray(from: data, decoder: decoder))
    }

    public func loadWorkouts() -> [Workout] {
        guard let data = readData(.workouts) else { return [] }
        return BackupSanitizer.sanitize(
            BackupSanitizer.lenientArray(from: data, decoder: decoder))
    }

    public func loadCustomExercises() -> [Exercise] {
        guard let data = readData(.exercises) else { return [] }
        return BackupSanitizer.sanitize(
            BackupSanitizer.lenientArray(from: data, decoder: decoder))
    }

    public func loadDietEntries() -> [DietEntry] {
        guard let data = readData(.diet) else { return [] }
        return BackupSanitizer.sanitize(
            BackupSanitizer.lenientArray(from: data, decoder: decoder))
    }

    public func loadCustomFoods() -> [CustomFood] {
        guard let data = readData(.foods) else { return [] }
        return BackupSanitizer.sanitize(
            BackupSanitizer.lenientArray(from: data, decoder: decoder))
    }

    public func loadExpenses() -> [Expense] {
        guard let data = readData(.expenses) else { return [] }
        return BackupSanitizer.sanitize(
            BackupSanitizer.lenientArray(from: data, decoder: decoder))
    }

    /// 自定义周期计划（budget 模块 BudgetPlans.swift；2026-10-06 增，只加不改）。
    /// 元素级容错（lenientArray）+ 计划净化（`CustomBudgetPlan.sanitized`，
    /// §4 管线 2/3）——坏条剔除、好条存活。**不在 BackupDocument 备份域内**
    /// （该文档为冻结契约，计划随功能新增，备份集成留待后续裁决）。
    public func loadBudgetPlans() -> [CustomBudgetPlan] {
        guard let data = readData(.plans) else { return [] }
        return CustomBudgetPlan.sanitized(
            BackupSanitizer.lenientArray(from: data, decoder: decoder))
    }

    // MARK: 保存

    public func save(settings: AppSettings) { write(settings, to: .settings) }
    public func save(categories: [TimeCategory]) { write(categories, to: .categories) }
    public func save(active: ActiveStateRecord?) {
        // nil 也落盘（清空崩溃恢复态），ActiveStateRecord 本身可表示空
        write(active ?? ActiveStateRecord(), to: .active)
    }
    public func save(timeBlocks: [TimeBlock]) { write(timeBlocks, to: .time) }
    public func save(sleepSessions: [SleepSession]) { write(sleepSessions, to: .sleep) }
    public func save(workouts: [Workout]) { write(workouts, to: .workouts) }
    public func save(customExercises: [Exercise]) { write(customExercises, to: .exercises) }
    public func save(dietEntries: [DietEntry]) { write(dietEntries, to: .diet) }
    public func save(customFoods: [CustomFood]) { write(customFoods, to: .foods) }
    public func save(expenses: [Expense]) { write(expenses, to: .expenses) }
    /// 自定义周期计划（只加不改；2026-10-06 增）。
    public func save(budgetPlans: [CustomBudgetPlan]) { write(budgetPlans, to: .plans) }

    // MARK: 备份（§5 导出/导入）

    /// 合并各域为单个 `BackupDocument` JSON（文件名带日期由 UI 层处理）。
    /// 从盘读当前态组装（DataStore 不持内存缓存——内存快照在 AppModel）；
    /// 先 `flushNow` 落盘防抖窗口内的最新变更，避免导出缺最后一笔。
    public func exportBackup(now: Date = Date()) throws -> Data {
        flushNow()
        let document = BackupDocument(
            version: BackupDocument.currentVersion,
            exportedAt: now,
            settings: loadSettings(),
            categories: loadCategories(),
            timeBlocks: loadTimeBlocks(),
            sleepSessions: loadSleepSessions(),
            workouts: loadWorkouts(),
            customExercises: loadCustomExercises(),
            dietEntries: loadDietEntries(),
            expenses: loadExpenses(),
            customFoods: loadCustomFoods())
        return try encoder.encode(document)
    }

    /// 导入：`BackupSanitizer` 元素级容错净化（§4 三步管线）→ 整体替换各域文件。
    /// 覆盖确认（confirmationDialog 双确认）在 UI 层（§5），本方法只做净化与落盘。
    /// 落盘前先清防抖账：已入队的导入前旧快照不得覆盖刚写入的导入数据。
    @discardableResult
    public func importBackup(from data: Data) throws -> BackupDocument {
        let document = try BackupSanitizer.sanitizeDocument(from: data)
        clearPendingWrites()
        try importWrite(document.settings, to: .settings)
        try importWrite(document.categories, to: .categories)
        try importWrite(document.timeBlocks, to: .time)
        try importWrite(document.sleepSessions, to: .sleep)
        try importWrite(document.workouts, to: .workouts)
        try importWrite(document.customExercises, to: .exercises)
        try importWrite(document.dietEntries, to: .diet)
        try importWrite(document.expenses, to: .expenses)
        try importWrite(document.customFoods, to: .foods)
        return document
    }

    /// 导入路径直接原子写（绕过防抖，立即生效）。
    private func importWrite<T: Encodable>(_ value: T, to domain: Domain) throws {
        let data = try encoder.encode(value)
        try atomicWrite(data, to: fileURL(domain))
    }

    /// 清空全部域文件（设置页「清空」双确认后的落点，§6 DataManagementView）。
    public func eraseAll() throws {
        flushNow()
        for domain in Domain.allCases {
            let url = fileURL(domain)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
