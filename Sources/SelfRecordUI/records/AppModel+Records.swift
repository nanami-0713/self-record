import Foundation
import SelfRecordCore

// MARK: - records 分组动作方法（design.md §6 页面地图 / §8 约定 4）
//
// TimeView / SleepView / DietView 的接线层：
// - 视图只绑定 AppModel 快照 + 调本文件的动作方法；业务判定全部走 Core 引擎
//   （TimeEngine / SleepEngine / DietEngine —— §2.1 聚合 API 与模块自有 API），
//   本文件只做「引擎产物 → 快照更新 → DataStore 写回」的编排，不写业务规则；
// - 单槽计时器（日常/睡眠互斥）的崩溃恢复态走 `saveActiveState()`（active.json）；
// - SwiftUI 宏禁令（§8 约定 5）：本文件不写 View。

extension AppModel {

    // MARK: - 锚点

    /// 运行时历法（公历 + 当前时区；骨架裁决 design.md §12.6）。
    var recordsCalendar: DayCalendar { DayCalendar() }

    /// 表单默认分类：第一个未归档分类 → 兜底分类。
    var recordsDefaultCategoryID: String {
        categories.first { !$0.isArchived }?.id
            ?? categories.first { $0.isFallback }?.id
            ?? "other"
    }

    /// 今天。
    func recordsToday(now: Date = Date()) -> DayKey {
        DayKey(now, calendar: recordsCalendar)
    }

    /// 截至今天（含）的近 n 天区间（「近 7 / 近 30」档用；含首尾）。
    func recordsRecentSpan(days: Int, now: Date = Date()) -> DateSpan {
        let calendar = recordsCalendar
        let end = DayKey(now, calendar: calendar)
        let start = calendar.addingDays(1 - days, to: end) ?? end
        return DateSpan(startDay: start, endDay: end)
    }

    // MARK: - 时间（TimeView 接线；引擎 = TimeEngine）

    /// 开始日常计时（单槽；任何计时进行中 → false，UI 层引导）。
    @discardableResult
    func startGeneralTimer(now: Date = Date()) -> Bool {
        switch TimeEngine.startTimer(kind: .general, at: now, current: activeTimer) {
        case .started(let timer):
            activeTimer = timer
            Task { await saveActiveState() }
            return true
        case .rejected:
            return false
        }
    }

    /// 上床（单槽；日常计时进行中 → false，UI 层引导先结束它）。
    @discardableResult
    func startSleepTimer(now: Date = Date()) -> Bool {
        switch TimeEngine.startTimer(kind: .sleep, at: now, current: activeTimer) {
        case .started(let timer):
            activeTimer = timer
            Task { await saveActiveState() }
            return true
        case .rejected:
            return false
        }
    }

    /// 结束日常计时 → 选分类存块（TimeEngine.stopTimer 做 end>start 校验、
    /// 分类归一与备注修剪，失败 → false 不动计时槽）。
    @discardableResult
    func stopGeneralTimer(categoryID: String, note: String?, now: Date = Date()) -> Bool {
        guard let timer = activeTimer, timer.kind == .general,
              let block = TimeEngine.stopTimer(timer, at: now, categoryID: categoryID,
                                               note: note, categories: categories)
        else { return false }
        timeBlocks.append(block)
        activeTimer = nil
        Task {
            await saveTimeBlocks()
            await saveActiveState()
        }
        return true
    }

    /// 丢弃进行中的计时（不产块，槽清空）。
    func discardActiveTimer() {
        guard activeTimer != nil else { return }
        activeTimer = nil
        Task { await saveActiveState() }
    }

    /// 补记时间块（makeBlock 校验 end>start、归一分类与备注）。
    @discardableResult
    func addTimeBlock(start: Date, end: Date, categoryID: String, note: String?) -> Bool {
        guard let block = TimeEngine.makeBlock(start: start, end: end,
                                               categoryID: categoryID, note: note,
                                               categories: categories)
        else { return false }
        timeBlocks.append(block)
        Task { await saveTimeBlocks() }
        return true
    }

    /// 编辑时间块（makeBlock 重新校验归一；保留原 id / 在原位替换）。
    @discardableResult
    func updateTimeBlock(id: UUID, start: Date, end: Date,
                         categoryID: String, note: String?) -> Bool {
        guard var block = TimeEngine.makeBlock(start: start, end: end,
                                               categoryID: categoryID, note: note,
                                               categories: categories)
        else { return false }
        block.id = id
        guard let index = timeBlocks.firstIndex(where: { $0.id == id }) else { return false }
        timeBlocks[index] = block
        Task { await saveTimeBlocks() }
        return true
    }

    func deleteTimeBlock(id: UUID) {
        guard timeBlocks.contains(where: { $0.id == id }) else { return }
        timeBlocks.removeAll { $0.id == id }
        Task { await saveTimeBlocks() }
    }

    // MARK: - 睡眠（SleepView 接线；引擎 = SleepEngine）

    /// 起床并保存会话：清睡眠计时槽 + 会话入库。问卷三题全可空（= 跳过不惩罚，
    /// 中性分口径在 SleepEngine.score）。非睡眠计时占用 / 时间非法 → nil。
    @discardableResult
    func completeSleepSession(startedAt: Date, wokeAt: Date,
                              feel: Int?, wakeCount: Int?, latency: SleepLatency?,
                              note: String?) -> SleepSession? {
        guard let timer = activeTimer, timer.kind == .sleep, timer.startedAt == startedAt,
              wokeAt > startedAt
        else { return nil }
        let session = SleepSession(start: startedAt, end: wokeAt, feel: feel,
                                   wakeCount: wakeCount, latency: latency, note: note)
        sleepSessions.append(session)
        activeTimer = nil
        Task {
            await saveSleepSessions()
            await saveActiveState()
        }
        return session
    }

    /// 归属调整（dayOverride）：nil = 恢复 -4h 自动规则（SleepEngine.sessionDay 口径）。
    func setSleepDayOverride(_ day: DayKey?, for sessionID: UUID) {
        guard let index = sleepSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        guard sleepSessions[index].dayOverride != day else { return }
        sleepSessions[index].dayOverride = day
        Task { await saveSleepSessions() }
    }

    /// 手动补录一段睡眠（忘了两击上床/起床时；lifttime sleep.js:100/:259-267）。
    /// 构造与校验全在 `SleepEngine.makeSession`（含跨零点合法性、dayOverride 收纳、
    /// note 修剪）；失败 → 错误原样返回供 sheet 展示，不入库。
    @discardableResult
    func addManualSleepSession(start: Date, end: Date,
                               feel: Int?, wakeCount: Int?, latency: SleepLatency?) -> SleepEntryError? {
        switch SleepEngine.makeSession(start: start, end: end, feel: feel,
                                       wakeCount: wakeCount, latency: latency,
                                       calendar: recordsCalendar) {
        case .success(let session):
            sleepSessions.append(session)
            Task { await saveSleepSessions() }
            return nil
        case .failure(let error):
            return error
        }
    }

    /// 编辑已有会话（补录/两击记录通用；sleep.js:269-279）：改时间与问卷三字段，
    /// 备注不在编辑范围、原样保留；dayOverride 透传（makeSession 会在与自动归属
    /// 等值时收纳为 nil）。校验失败 → 返回错误，不动原会话。
    @discardableResult
    func updateSleepSession(id: UUID, start: Date, end: Date,
                            feel: Int?, wakeCount: Int?, latency: SleepLatency?,
                            dayOverride: DayKey?) -> SleepEntryError? {
        guard let index = sleepSessions.firstIndex(where: { $0.id == id }) else { return nil }
        switch SleepEngine.makeSession(start: start, end: end, feel: feel,
                                       wakeCount: wakeCount, latency: latency,
                                       note: sleepSessions[index].note,
                                       dayOverride: dayOverride,
                                       calendar: recordsCalendar) {
        case .success(var session):
            session.id = id
            sleepSessions[index] = session
            Task { await saveSleepSessions() }
            return nil
        case .failure(let error):
            return error
        }
    }

    func deleteSleepSession(id: UUID) {
        guard sleepSessions.contains(where: { $0.id == id }) else { return }
        sleepSessions.removeAll { $0.id == id }
        Task { await saveSleepSessions() }
    }

    // MARK: - 饮食（DietView 接线；引擎 = DietEngine）

    /// 保存一餐：totals 由 `DietEngine.entryTotals` 计算（命中 + 未排除手估）；
    /// 花费 >0 才落 costYuan（模型注释口径：>0 派生预算 auto 开销）；
    /// 手估项归一每 100g 学进自学习库（`learnFood`，§3.4——拒绝零值/空名/超长名）。
    @discardableResult
    func saveDietEntry(date: Date, meal: MealSlot, rawText: String,
                       parsedTotals: MacroTotals, items: [FoodMatch],
                       manualItems: [ManualFoodItem], unmatched: [String],
                       costYuan: Double?) -> DietEntry? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let totals = DietEngine.entryTotals(parsed: parsedTotals, manualItems: manualItems)
        let cost = (costYuan ?? 0) > 0 ? costYuan : nil
        let entry = DietEntry(date: date, meal: meal, rawText: text, items: items,
                              manualItems: manualItems, unmatched: unmatched,
                              totals: totals, costYuan: cost)
        dietEntries.append(entry)

        // 自学习：手估项 → 归一每 100g 入库（同名更新 + 计一次使用，新名追加）
        var learnedAny = false
        for item in manualItems {
            guard let learned = DietEngine.learnFood(item) else { continue }
            upsertLearnedFood(learned)
            learnedAny = true
        }
        Task {
            await saveDietEntries()
            if learnedAny { await saveCustomFoods() }
        }
        return entry
    }

    func deleteDietEntry(id: UUID) {
        guard dietEntries.contains(where: { $0.id == id }) else { return }
        dietEntries.removeAll { $0.id == id }
        Task { await saveDietEntries() }
    }

    /// 自学习库 upsert（learnFood 每次产出整条归一值：同名替换 per100g 并 +1 使用数）。
    private func upsertLearnedFood(_ learned: CustomFood) {
        if let index = customFoods.firstIndex(where: { $0.name == learned.name }) {
            var existing = customFoods[index]
            existing.per100g = learned.per100g
            existing.useCount += 1
            customFoods[index] = existing
        } else {
            customFoods.append(learned)
        }
    }
}
