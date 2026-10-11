import Testing
import Foundation
@testable import SelfRecordCore

// MARK: - 基础层测试：模型默认数据 + 净化管线 + DataStore（design.md §4 / §5）
//
// 本文件属基础层（骨架冻结物 A 的测试面），模块工程师不改（§3.0 / §8 约定 3）。
// 覆盖 §10 存储测试要点：元素级容错端到端（单条坏枚举/坏 dayOverride/坏时间戳
// 混入数组：坏条剔除/字段归 nil、好条目全部存活——§4 三步管线的验收测试）、
// 损坏文件启动降级、净化域收敛、customFoods 导入完整保留（§4 正向断言）。

// MARK: 工具

private func jsonData(_ string: String) -> Data {
    string.data(using: .utf8)!
}

private let uuidA = "8E4C1B1A-0F5E-4C6B-9C2A-3D4E5F6A7B8C"
private let uuidB = "1A2B3C4D-5E6F-4A5B-8C9D-0E1F2A3B4C5D"
private let uuidC = "AABBCCDD-0011-4223-8445-566778899AAB"

// MARK: §4.1 默认数据

@Test func defaultCategoriesAreNineWithSingleFallback() {
    let defaults = TimeCategory.defaults
    #expect(defaults.count == 9)
    #expect(defaults.filter(\.isFallback).count == 1)
    #expect(defaults.first(where: \.isFallback)?.id == "other")
    #expect(defaults.first(where: \.isFallback)?.hue == .neutral)
    // id 清单与 §4.1 表一致
    #expect(defaults.map(\.id) == ["warmup", "strength", "cardio", "stretch",
                                   "commute", "meal", "supplement", "shower", "other"])
}

// MARK: 管线 1+2：元素级容错 + 字段宽容

@Test func lenientDecodeDropsOnlyBrokenElement() {
    // 好条 / 坏条（必填 date 类型错）/ 好条 —— 坏条丢弃，好条全部存活（§13 v3 实验）
    let json = jsonData("""
    [
      {"id":"\(uuidA)","date":"2026-10-06T12:00:00Z","meal":"lunch","rawText":"两碗米饭","totals":{}},
      {"id":"\(uuidB)","date":"不是时间戳","meal":"dinner","rawText":"坏条","totals":{}},
      {"id":"\(uuidC)","date":"2026-10-06T18:00:00Z","meal":"dinner","rawText":"鸡胸肉 200g","totals":{}}
    ]
    """)
    let entries: [DietEntry] = BackupSanitizer.lenientArray(from: json)
    #expect(entries.count == 2)
    #expect(entries.map(\.id) == [UUID(uuidString: uuidA)!, UUID(uuidString: uuidC)!])
}

@Test func unknownMealFallsBackToSnackNotDropped() {
    // meal:"brunch"（非法枚举）→ 归 .snack，整条保留（§4 管线 2；§13 v3：好条目存活）
    let json = jsonData(#"[{"id":"\#(uuidA)","date":"2026-10-06T12:00:00Z","meal":"brunch","rawText":"brunch 应归加餐","totals":{}}]"#)
    let entries: [DietEntry] = BackupSanitizer.lenientArray(from: json)
    #expect(entries.count == 1)
    #expect(entries.first?.meal == .snack)
}

@Test func invalidDayOverrideBecomesNilNotDropped() {
    // dayOverride 斜杠格式 → 归 nil，整条存活（lifttime store.js:137 语义）
    let json = jsonData(#"""
    [{"id":"\#(uuidA)","start":"2026-10-05T23:00:00Z","end":"2026-10-06T07:00:00Z","dayOverride":"2026/09/06"}]
    """#)
    let sessions: [SleepSession] = BackupSanitizer.lenientArray(from: json)
    #expect(sessions.count == 1)
    #expect(sessions.first?.dayOverride == nil)
}

@Test func brokenJsonFileDegradesToEmptyArray() {
    // 半写/损坏 JSON → 空域（§5 读取降级）
    let garbage = jsonData("[{\"id\": \"8E4C1B1A-0F5E-4C6B")
    let sessions: [SleepSession] = BackupSanitizer.lenientArray(from: garbage)
    #expect(sessions.isEmpty)
}

@Test func legacyTimerWithoutKindDecodesAsGeneral() {
    // 旧数据无 kind → 归 general（store.test.mjs timer 向后兼容断言，§3.1）
    let json = jsonData(#"{"startedAt":"2026-10-06T09:00:00Z"}"#)
    let timer = try? BackupSanitizer.makeDecoder().decode(ActiveTimer.self, from: json)
    #expect(timer?.kind == .general)
}

// MARK: 管线 3：值上业务校验

@Test func sleepSanitizeDropsStructurallyInvalidAndNilifiesOutOfRange() {
    let base = Date(timeIntervalSince1970: 1_760_000_000)
    let good = SleepSession(start: base, end: base.addingTimeInterval(8 * 3600), feel: 4)
    let endBeforeStart = SleepSession(start: base, end: base.addingTimeInterval(-60))
    let tooLong = SleepSession(start: base, end: base.addingTimeInterval(25 * 3600))
    let badFeel = SleepSession(start: base, end: base.addingTimeInterval(7 * 3600), feel: 9)
    let badWakes = SleepSession(start: base, end: base.addingTimeInterval(7 * 3600), wakeCount: 7)
    let longNote = SleepSession(start: base, end: base.addingTimeInterval(7 * 3600),
                                note: String(repeating: "长", count: 3000))
    let result = BackupSanitizer.sanitize([good, endBeforeStart, tooLong, badFeel, badWakes, longNote])
    // 结构性非法剔除（end≤start、>24h），可恢复字段归 nil/截断，好条目存活
    #expect(result.count == 4)
    #expect(result[0] == good)
    #expect(result.first(where: { $0.feel == 9 }) == nil)
    #expect(result.first(where: { $0.wakeCount == 7 }) == nil)
    #expect(result.last?.note?.count == SanitizeLimits.stringMaxLength)
}

@Test func settingsSanitizeConvergesDomains() {
    var settings = AppSettings()
    settings.bodyweightKg = 3000                    // 越界（0–2000）→ nil
    settings.sleepGoalMinutes = 100                 // 越界（240–720）→ 收敛到 240
    settings.weeklyBudgetYuan = -5                  // 越界（0–1e7）→ nil
    settings.monthlyBudgetYuan = 10_000_001         // 越界 → nil
    settings.aiConfig.baseURLString = "ftp://example.com"  // 非 http(s) → nil
    settings.aiConfig.model = "glm-5.3-flash"
    let sanitized = BackupSanitizer.sanitize(settings)
    #expect(sanitized.bodyweightKg == nil)
    #expect(sanitized.sleepGoalMinutes == 240)
    #expect(sanitized.weeklyBudgetYuan == nil)
    #expect(sanitized.monthlyBudgetYuan == nil)
    #expect(sanitized.aiConfig.baseURLString == nil)
    // AI 配置净化后不丢（store.test.mjs 语义）
    #expect(sanitized.aiConfig.model == "glm-5.3-flash")

    var ok = AppSettings()
    ok.bodyweightKg = 72.5
    ok.weeklyBudgetYuan = 500
    ok.aiConfig.baseURLString = "https://api.example.com/v1"
    let kept = BackupSanitizer.sanitize(ok)
    #expect(kept.bodyweightKg == 72.5)
    #expect(kept.weeklyBudgetYuan == 500)
    #expect(kept.aiConfig.baseURLString == "https://api.example.com/v1")
}

@Test func blockSanitizeDropsInvalidSpansAndCategoryIDs() {
    let base = Date(timeIntervalSince1970: 1_760_000_000)
    let good = TimeBlock(start: base, end: base.addingTimeInterval(1800), categoryID: "strength")
    let badSpan = TimeBlock(start: base, end: base, categoryID: "strength")          // end == start
    let badCategory = TimeBlock(start: base, end: base.addingTimeInterval(60), categoryID: "非法 id!")
    let result = BackupSanitizer.sanitize([good, badSpan, badCategory])
    #expect(result == [good])
}

@Test func categorySanitizeEnforcesSingleFallback() {
    // 无 fallback → 净化补位（恰一个 isFallback）
    let noFallback = [TimeCategory(id: "work", label: "工作", hue: .blue)]
    let fixed = BackupSanitizer.sanitize(noFallback)
    #expect(fixed.filter(\.isFallback).count == 1)
    #expect(fixed.first(where: \.isFallback)?.id == "other")
    // 多 fallback → 只保首个
    let multi = [
        TimeCategory(id: "a", label: "A", hue: .blue, isFallback: true),
        TimeCategory(id: "b", label: "B", hue: .teal, isFallback: true),
    ]
    let trimmed = BackupSanitizer.sanitize(multi)
    #expect(trimmed.filter(\.isFallback).count == 1)
    #expect(trimmed.first(where: \.isFallback)?.id == "a")
}

@Test func expenseSanitizeClampsAmountAndNilifiesUnknownCategory() {
    var e = Expense(date: Date(), amountYuan: -3, category: nil, note: nil)
    // 非法分类字符串（如通用记账 "shopping"）经宽容解码归 nil
    let json = jsonData(#"{"id":"\#(uuidA)","date":"2026-10-06T12:00:00Z","amountYuan":25.5,"category":"shopping"}"#)
    let decoded = try! BackupSanitizer.makeDecoder().decode(Expense.self, from: json)
    #expect(decoded.category == nil)
    let sanitized = BackupSanitizer.sanitize([e, decoded])
    #expect(sanitized[0].amountYuan == 0)          // 负值收敛到 0
    #expect(sanitized[1].amountYuan == 25.5)
    e.amountYuan = 0
}

@Test func workoutSanitizeDropsInvalidAndConvergesValues() {
    // 结构性非法（end≤start）剔除；负重量/次数收敛非负；feeling 越界归 nil
    let t = Date(timeIntervalSince1970: 1_760_000_000)
    let badSet = WorkoutSet(weightKg: -20, reps: -3, timestamp: t)
    let good = Workout(startedAt: t, endedAt: t.addingTimeInterval(3600),
                       entries: [WorkoutExerciseEntry(exerciseID: "barbell-squat", sets: [badSet])],
                       feeling: 4)
    let invalid = Workout(startedAt: t, endedAt: t, entries: [], feeling: 2)   // end == start
    let badFeeling = Workout(startedAt: t, endedAt: t.addingTimeInterval(3600),
                             entries: [], feeling: 9)
    let result = BackupSanitizer.sanitize([good, invalid, badFeeling])
    #expect(result.count == 2)
    #expect(result.first?.entries.first?.sets.first?.weightKg == 0)
    #expect(result.first?.entries.first?.sets.first?.reps == 0)
    #expect(result.first?.feeling == 4)
    #expect(result.last?.feeling == nil)
}

@Test func exerciseSanitizeDropsEmptyIDOrName() {
    let good = Exercise(id: "custom-1", name: "保加利亚分腿蹲", isCustom: true)
    let noName = Exercise(id: "custom-2", name: "", isCustom: true)
    let noID = Exercise(id: "", name: "无 id 动作", isCustom: true)
    let longName = Exercise(id: "custom-3",
                            name: String(repeating: "名", count: 3000), isCustom: true)
    let result = BackupSanitizer.sanitize([good, noName, noID, longName])
    #expect(result.count == 2)
    #expect(result.map(\.id) == ["custom-1", "custom-3"])
    #expect(result.last?.name.count == SanitizeLimits.stringMaxLength)
}

@Test func dietEntrySanitizeConvergesNegativesAndNilifiesCost() {
    // 负宏量收敛 0；costYuan 越界（负值）归 nil；items 负克数收敛 0
    let t = Date(timeIntervalSince1970: 1_760_000_000)
    let entry = DietEntry(date: t, meal: .lunch, rawText: "测试",
                          items: [FoodMatch(name: "鸡胸肉", grams: -50,
                                            per100g: Per100g(kcal: -133, proteinG: 24, carbsG: 1, fatG: 3))],
                          totals: MacroTotals(kcal: -100, proteinG: -5, carbsG: 2, fatG: 3),
                          costYuan: -8)
    let result = BackupSanitizer.sanitize([entry])
    #expect(result.count == 1)
    #expect(result.first?.totals.kcal == 0)
    #expect(result.first?.totals.proteinG == 0)
    #expect(result.first?.costYuan == nil)
    #expect(result.first?.items.first?.grams == 0)
    #expect(result.first?.items.first?.per100g.kcal == 0)
    #expect(result.first?.items.first?.per100g.proteinG == 24)
}

// MARK: 文档级净化（导入路径）

@Test func sanitizeDocumentKeepsCustomFoods() throws {
    // §4 净化语义修正的正向断言：导入后 customFoods 完整保留
    let food = CustomFood(name: "无糖希腊酸奶",
                          per100g: Per100g(kcal: 97, proteinG: 10, carbsG: 3.6, fatG: 5),
                          useCount: 3)
    let document = BackupDocument(exportedAt: Date(),
                                  settings: AppSettings(),
                                  categories: TimeCategory.defaults,
                                  timeBlocks: [], sleepSessions: [], workouts: [],
                                  customExercises: [], dietEntries: [], expenses: [],
                                  customFoods: [food])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(document)
    let sanitized = try BackupSanitizer.sanitizeDocument(from: data)
    #expect(sanitized.customFoods == [food])
}

@Test func sanitizeDocumentRejectsBadPayloads() throws {
    // 非 JSON
    #expect(throws: SanitizeError.self) {
        _ = try BackupSanitizer.sanitizeDocument(from: jsonData("not json at all"))
    }
    // 顶层不是对象
    #expect(throws: SanitizeError.notObject) {
        _ = try BackupSanitizer.sanitizeDocument(from: jsonData("[1,2,3]"))
    }
    // 深度 > maxDepth（10）：1 层对象 + 12 层数组 = 13，须仍被拒
    //（上限 2026-10-06→10-12 从 6 提到 10：带组的训练合法形状即 8 层，见
    // sanitizeDocumentAcceptsNestedRealShapes；此处深度用 12 保证余量不被误伤）
    let deep = jsonData("{\"a\":" + String(repeating: "[", count: 12) + String(repeating: "]", count: 12) + "}")
    #expect(throws: SanitizeError.tooDeep) {
        _ = try BackupSanitizer.sanitizeDocument(from: deep)
    }
}

@Test func sanitizeDocumentAcceptsNestedRealShapes() throws {
    // maxDepth 回归锚点：真实文档最深合法形状——带组的训练
    // root→workouts→Workout→entries→entry→sets→set→标量 = 8 层；
    // 带命中的记餐 root→dietEntries→DietEntry→items→FoodMatch→per100g→标量 = 7 层。
    // 上限曾为 6：导出的备份只要含一条带组训练/带命中记餐，导入即 tooDeep 整体失败
    //（2026-10-12 修复，配套 DataStore 导出→导入往返见下）。
    let t = Date(timeIntervalSince1970: 1_760_000_000)
    let set = WorkoutSet(weightKg: 100, reps: 5, timestamp: t)
    let entry = WorkoutExerciseEntry(exerciseID: "barbell-squat", sets: [set, set])
    let workout = Workout(startedAt: t, endedAt: t.addingTimeInterval(3600),
                          entries: [entry], feeling: 4)
    let diet = DietEntry(date: t, meal: .lunch, rawText: "鸡胸肉 200g",
                         items: [FoodMatch(name: "鸡胸肉", grams: 200,
                                           per100g: Per100g(kcal: 133, proteinG: 24, carbsG: 1, fatG: 3))],
                         totals: MacroTotals(kcal: 266, proteinG: 48, carbsG: 2, fatG: 6),
                         costYuan: 12)
    let document = BackupDocument(exportedAt: t,
                                  settings: AppSettings(),
                                  categories: TimeCategory.defaults,
                                  timeBlocks: [], sleepSessions: [],
                                  workouts: [workout],
                                  customExercises: [], dietEntries: [diet],
                                  expenses: [], customFoods: [])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(document)

    let sanitized = try BackupSanitizer.sanitizeDocument(from: data)
    #expect(sanitized.workouts.count == 1)
    #expect(sanitized.workouts.first?.entries.first?.sets.count == 2)
    #expect(sanitized.workouts.first?.entries.first?.sets.first?.weightKg == 100)
    #expect(sanitized.dietEntries.count == 1)
    #expect(sanitized.dietEntries.first?.items.first?.per100g.proteinG == 24)
    #expect(sanitized.dietEntries.first?.costYuan == 12)
}

// MARK: DataStore 端到端（临时目录注入，§5/§10）

@Test func dataStoreRoundTripAndLenientRead() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sr-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = try DataStore(directory: dir)

    // 1) 正常往返（值类型快照 → 写回 → 重读）
    let base = Date(timeIntervalSince1970: 1_760_000_000)
    let session = SleepSession(start: base, end: base.addingTimeInterval(8 * 3600), feel: 4)
    await store.save(sleepSessions: [session])
    await store.flushNow()
    let loaded = await store.loadSleepSessions()
    #expect(loaded == [session])

    // 2) 元素级容错端到端：往 sleep.json 混入坏条（start 非时间戳）+ 非法 dayOverride 条
    let mixed = """
    [
      {"id":"\(uuidA)","start":"坏时间戳","end":"2026-10-06T07:00:00Z"},
      {"id":"\(uuidB)","start":"2026-10-05T23:00:00Z","end":"2026-10-06T07:00:00Z","dayOverride":"2026/09/06","feel":9},
      {"id":"\(uuidC)","start":"2026-10-04T23:00:00Z","end":"2026-10-05T06:30:00Z","feel":3}
    ]
    """
    try jsonData(mixed).write(to: dir.appendingPathComponent("sleep.json"), options: .atomic)
    let sanitizedLoad = await store.loadSleepSessions()
    // 坏条剔除；dayOverride 归 nil；feel 越界归 nil；两条好条目全部存活
    #expect(sanitizedLoad.count == 2)
    #expect(sanitizedLoad.allSatisfy { $0.dayOverride == nil })
    #expect(sanitizedLoad.allSatisfy { $0.feel == nil || (1...5).contains($0.feel!) })

    // 3) 损坏文件（半写 JSON）→ 降级为空域
    try jsonData("{\"settings\": 垃圾").write(to: dir.appendingPathComponent("expenses.json"),
                                              options: .atomic)
    let degraded = await store.loadExpenses()
    #expect(degraded.isEmpty)

    // 4) settings 缺失 → 默认值
    let settings = await store.loadSettings()
    #expect(settings == AppSettings())
}

@Test func dataStoreImportReplacesDomainsAndKeepsCustomFoods() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sr-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try DataStore(directory: dir)

    let food = CustomFood(name: "蛋白棒", per100g: Per100g(kcal: 350, proteinG: 30, carbsG: 35, fatG: 10))
    let expense = Expense(date: Date(timeIntervalSince1970: 1_760_000_000), amountYuan: 23, category: .takeout)
    let document = BackupDocument(exportedAt: Date(timeIntervalSince1970: 1_760_000_000),
                                  settings: AppSettings(),
                                  categories: TimeCategory.defaults,
                                  timeBlocks: [],
                                  sleepSessions: [SleepSession(start: Date(timeIntervalSince1970: 1_760_000_000),
                                                                end: Date(timeIntervalSince1970: 1_760_000_000 + 28_800))],
                                  workouts: [], customExercises: [], dietEntries: [],
                                  expenses: [expense], customFoods: [food])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(document)

    let imported = try await store.importBackup(from: data)
    #expect(imported.customFoods == [food])
    let foods = await store.loadCustomFoods()
    #expect(foods == [food])
    let expenses = await store.loadExpenses()
    #expect(expenses == [expense])
    let sessions = await store.loadSleepSessions()
    #expect(sessions.count == 1)
}

// MARK: DataStore 导出→导入往返 / 防抖 / 清空 / plans（2026-10-12 补）

/// maxDepth 回归（端到端）：自己导出的备份（含嵌套真实数据）必须能导入自己。
/// 修复前：带组的训练深度 8 > 旧上限 6 → tooDeep 整体失败（导出能用导入全挂）。
@Test func dataStoreExportImportRoundTripWithNestedData() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sr-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try DataStore(directory: dir)

    let t = Date(timeIntervalSince1970: 1_760_000_000)
    let set = WorkoutSet(weightKg: 102.5, reps: 5, timestamp: t)
    let workout = Workout(startedAt: t, endedAt: t.addingTimeInterval(5400),
                          entries: [WorkoutExerciseEntry(exerciseID: "barbell-squat", sets: [set, set])],
                          feeling: 4)
    let diet = DietEntry(date: t, meal: .postworkout, rawText: "鸡胸肉 200g",
                         items: [FoodMatch(name: "鸡胸肉", grams: 200,
                                           per100g: Per100g(kcal: 133, proteinG: 24, carbsG: 1, fatG: 3))],
                         totals: MacroTotals(kcal: 266, proteinG: 48),
                         costYuan: 15)
    await store.save(workouts: [workout])
    await store.save(dietEntries: [diet])

    let exported = try await store.exportBackup()

    // 同一 store 覆盖导入（换机语义 = 新 store 导入同款数据，净化管线相同）
    _ = try await store.importBackup(from: exported)
    let workouts = await store.loadWorkouts()
    #expect(workouts.count == 1)
    #expect(workouts.first?.entries.first?.sets.count == 2)
    #expect(workouts.first?.entries.first?.sets.first?.weightKg == 102.5)
    #expect(workouts.first?.feeling == 4)
    let entries = await store.loadDietEntries()
    #expect(entries.count == 1)
    #expect(entries.first?.items.first?.per100g.proteinG == 24)
    #expect(entries.first?.costYuan == 15)
}

/// 防抖合并语义（§5「commit 立即写 + 150ms 内合并为最后一次写」，design.md §10
/// 承诺要点）：首笔立即落盘 → 后续变更只进 pending → flushNow 后盘上是最后一次。
/// 注入 10s 超长防抖：窗口内定时器绝不触发，flush 时机完全由测试控制。
@Test func dataStoreDebounceMergesIntoFinalWrite() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sr-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try DataStore(directory: dir, debounceNanoseconds: 10_000_000_000)

    let t = Date(timeIntervalSince1970: 1_760_000_000)
    let v1 = SleepSession(start: t, end: t.addingTimeInterval(7 * 3600), feel: 3)
    let v2 = SleepSession(start: t, end: t.addingTimeInterval(8 * 3600), feel: 4)

    await store.save(sleepSessions: [v1])
    // 首笔立即写：盘上已是 v1（不等防抖）
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let disk1 = try Data(contentsOf: dir.appendingPathComponent("sleep.json"))
    #expect((try decoder.decode([SleepSession].self, from: disk1)) == [v1])

    await store.save(sleepSessions: [v2])
    // 防抖窗口内：盘上仍是 v1（v2 只在 pending）
    let disk2 = try Data(contentsOf: dir.appendingPathComponent("sleep.json"))
    #expect((try decoder.decode([SleepSession].self, from: disk2)) == [v1])

    await store.flushNow()
    // 合并落盘：盘上是最后一次（v2）
    let disk3 = try Data(contentsOf: dir.appendingPathComponent("sleep.json"))
    #expect((try decoder.decode([SleepSession].self, from: disk3)) == [v2])
    let loaded = await store.loadSleepSessions()
    #expect(loaded == [v2])
}

/// 导出前 flush：防抖窗口内未落盘的最后一笔必须进导出文件。
@Test func dataStoreExportIncludesPendingWrites() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sr-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try DataStore(directory: dir, debounceNanoseconds: 10_000_000_000)

    let t = Date(timeIntervalSince1970: 1_760_000_000)
    let early = SleepSession(start: t, end: t.addingTimeInterval(6 * 3600), feel: 3)
    let latest = SleepSession(start: t, end: t.addingTimeInterval(8 * 3600), feel: 4)
    await store.save(sleepSessions: [early])
    await store.save(sleepSessions: [latest])     // 仅进 pending（150ms 窗口内）

    let exported = try await store.exportBackup() // 修复点：导出前 flushNow
    let document = try BackupSanitizer.sanitizeDocument(from: exported)
    #expect(document.sleepSessions == [latest])
}

/// 导入清防抖账：已入队的导入前旧快照不得在导入后由 flushNow 写回覆盖导入数据。
@Test func dataStoreImportInvalidatesPendingWrites() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sr-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try DataStore(directory: dir, debounceNanoseconds: 10_000_000_000)

    // t=0 编辑（立即写 + pending 入队 + 150ms 定时器）
    let t = Date(timeIntervalSince1970: 1_760_000_000)
    let staleBlock = TimeBlock(start: t, end: t.addingTimeInterval(1800), categoryID: "strength")
    await store.save(timeBlocks: [staleBlock])

    // t<150ms 导入：导入数据落盘，随后定时器触发的 flushNow 不得写回旧快照
    let importedBlock = TimeBlock(start: t.addingTimeInterval(7200),
                                  end: t.addingTimeInterval(9000), categoryID: "cardio")
    let document = BackupDocument(exportedAt: t, settings: AppSettings(),
                                  categories: TimeCategory.defaults,
                                  timeBlocks: [importedBlock],
                                  sleepSessions: [], workouts: [], customExercises: [],
                                  dietEntries: [], expenses: [], customFoods: [])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    _ = try await store.importBackup(from: encoder.encode(document))
    await store.flushNow()                        // 显式触发原会覆盖导入的路径

    let blocks = await store.loadTimeBlocks()
    #expect(blocks == [importedBlock])
}

/// eraseAll（§6 DataManagementView「清空」落点）：各域文件删除，读回空/默认。
@Test func dataStoreEraseAllClearsDomains() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sr-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try DataStore(directory: dir)

    let t = Date(timeIntervalSince1970: 1_760_000_000)
    var settings = AppSettings()
    settings.weeklyBudgetYuan = 500
    await store.save(settings: settings)
    await store.save(sleepSessions: [SleepSession(start: t, end: t.addingTimeInterval(8 * 3600))])
    await store.save(workouts: [Workout(startedAt: t, endedAt: t.addingTimeInterval(3600))])
    await store.save(expenses: [Expense(date: t, amountYuan: 23, category: .takeout)])

    try await store.eraseAll()

    #expect(await store.loadSettings() == AppSettings())          // 默认值
    #expect(await store.loadSleepSessions().isEmpty)
    #expect(await store.loadWorkouts().isEmpty)
    #expect(await store.loadExpenses().isEmpty)
}

/// plans 域持久化（.plans 不在 BackupDocument 内——冻结契约，见 DataStore 注释；
/// 此处只锚定 save/load 往返与坏计划剔除语义）。
@Test func dataStoreBudgetPlansRoundTrip() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sr-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try DataStore(directory: dir)

    let cal = DayCalendar()
    let today = cal.dayKey(for: Date(timeIntervalSince1970: 1_760_000_000))
    let valid = CustomBudgetPlan(name: "双十一冲刺", amountYuan: 800,
                                 startDay: today,
                                 endDay: cal.addingDays(13, to: today) ?? today)
    let invalid = CustomBudgetPlan(name: "坏计划", amountYuan: -1,
                                   startDay: today, endDay: today)  // 金额越界 → isValid false
    await store.save(budgetPlans: [valid, invalid])
    await store.flushNow()

    let loaded = await store.loadBudgetPlans()
    #expect(loaded == [valid])                    // 坏条剔除（sanitized），好条存活
}
