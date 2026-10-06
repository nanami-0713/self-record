import Foundation

// MARK: - time-tracking 模块（design.md §3.1）
//
// 只依赖基础层（Model/ Storage/ TimeKit/），禁止横向调用其它功能模块（§2）。
// lifttime 对应：js/time.js（计时/补记/编辑/三档区间图）+ js/store.js 的
// timer / timeBlocks / categories / DEFAULT_CATEGORIES 部分 + js/analysis.js
// dayBrief 时间部分 + js/workout.js:12 FITNESS_CATS / :338-343 fitnessTimeToday。
//
// 归属口径（与 lifttime 一致，本模块所有聚合统一遵守）：
// 时间块归属 = **start 所在日**（time.js:145 `b.start >= start && b.start < end`、
// chartHTML byDay 用 dayKey(b.start)）——跨午夜块整段记到开始那天，不拆分。

/// 健身相关分类集合（§3.1，与 lifttime workout.js:12 口径一致）——
/// 「今天为这次训练总共花掉 X」这条时间×训练联动的数据源。
/// 已由骨架冻结：FITNESS_CATS 的取值不得增删（改了会改变 fitnessMinutes 口径）。
public let FITNESS_CATS: Set<String> = ["warmup", "strength", "cardio", "stretch", "shower"]

/// dayBrief 返回类型（§3.1）：总分钟 + Top 分类（report 日简报「时间」域）。
/// 语义 = lifttime analysis.js:402-423 dayBrief 时间部分（totalMs + top 降序表）。
public struct TimeDayBrief: Codable, Sendable, Equatable {
    /// 当日时间块总分钟（块时长之和，精确值；展示取整归 Formatting/UI 层）。
    public var totalMinutes: Double
    /// 按分钟降序的分类份额表（引用未知分类的块经兜底分类入账，见 resolveCategory）。
    public var topCategories: [TimeCategoryShare]

    public init(totalMinutes: Double = 0, topCategories: [TimeCategoryShare] = []) {
        self.totalMinutes = totalMinutes
        self.topCategories = topCategories
    }
}

/// 日简报里的单分类份额（lifttime dayBrief top 表目的 Swift 形状：
/// `{ label, ms }` → id/label/minutes，分钟制）。
public struct TimeCategoryShare: Codable, Sendable, Equatable, Identifiable {
    public var id: String { categoryID }
    public var categoryID: String
    public var label: String
    public var minutes: Double

    public init(categoryID: String, label: String, minutes: Double) {
        self.categoryID = categoryID
        self.label = label
        self.minutes = minutes
    }
}

/// 时间引擎（§3.1）。§2.1 冻结物 B 的三个签名**逐字保留**；
/// 其余为本模块自有 API（计时器单槽互斥、时间块校验、分类管理）。
public enum TimeEngine {

    // MARK: - 冻结物 B（§2.1 聚合 API）

    /// 当日时间投入简报：总分钟 + Top 分类（report 日简报「时间」域）
    /// lifttime analysis.dayBrief 时间部分。
    ///
    /// 「当日」= start 落在该日的时间块（跨午夜块整段归开始日）；
    /// 块引用的分类不在表中 → 经兜底分类入账（resolveCategory）；
    /// 分类表为空且无兜底时该块不计。
    public static func dayBrief(_ blocks: [TimeBlock], day: DayKey, categories: [TimeCategory],
                                calendar: DayCalendar) -> TimeDayBrief {
        var byCategory: [String: (label: String, seconds: Double)] = [:]
        var totalSeconds = 0.0
        for block in blocks where calendar.dayKey(for: block.start) == day {
            guard let category = resolveCategory(block.categoryID, in: categories) else { continue }
            let seconds = block.end.timeIntervalSince(block.start)
            guard seconds > 0 else { continue }
            totalSeconds += seconds
            let slot = byCategory[category.id] ?? (category.label, 0)
            byCategory[category.id] = (slot.label, slot.seconds + seconds)
        }
        let shares = byCategory.map { key, value in
            TimeCategoryShare(categoryID: key, label: value.label, minutes: value.seconds / 60)
        }
        .sorted { lhs, rhs in
            lhs.minutes != rhs.minutes ? lhs.minutes > rhs.minutes
                                       : lhs.categoryID < rhs.categoryID
        }
        return TimeDayBrief(totalMinutes: totalSeconds / 60, topCategories: shares)
    }

    /// 区间内逐日按分类的分钟聚合（阶段报告「时间」域 + TimeView 近7/30 堆叠柱）
    /// key = DayKey，value = [categoryID: 分钟]。
    ///
    /// 语义 = lifttime time.js:280-305 chartHTML 的 byDay + 零填列：
    /// - 归属 = start 所在日，且 start 日须落在区间内（含首尾）；
    /// - **区间内每一天都会出现**（无数据的天为全 0 列），近 7/30 堆叠柱直接可用
    ///   （lifttime `dayKeys.map(k => cats.map(...0))` 的等价物）；
    /// - 列 = 分类表中的**未归档**分类（归档分类不占列；其历史块在归档动作时已迁移
    ///   到兜底分类，见 archiveCategory）；
    /// - 块引用未知分类 → 计入兜底分类列（resolveCategory）；
    /// - span 非法（start > end）或分类表为空 → [:]；
    /// - 防御上限：区间超过 400 天（report 契约 ≤366）时退化为「只含有数据的天」，
    ///   不做零填，避免病态区间拖垮调用方。
    public static func dailyBreakdown(_ blocks: [TimeBlock], in span: DateSpan,
                                      categories: [TimeCategory], calendar: DayCalendar) -> [DayKey: [String: Double]] {
        let columns = categories.filter { !$0.isArchived }
        guard span.isValid, !columns.isEmpty else { return [:] }

        // 零填列模板 + 区间逐日（addingDays 跨月/跨年正确）
        let zero: [String: Double] = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, 0.0) })
        let fillCap = 400
        var result: [DayKey: [String: Double]] = [:]
        var cursor = span.startDay
        var filled = 0
        while filled <= fillCap, span.contains(cursor) {
            result[cursor] = zero
            filled += 1
            guard let next = calendar.addingDays(1, to: cursor), next.rawValue > cursor.rawValue else { break }
            cursor = next
        }
        if filled > fillCap {   // 病态长区间：退化为只含有数据的天
            result.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            let day = calendar.dayKey(for: block.start)
            guard span.contains(day),
                  let category = resolveCategory(block.categoryID, in: categories)
            else { continue }
            let minutes = block.end.timeIntervalSince(block.start) / 60
            guard minutes > 0 else { continue }
            var perDay = result[day] ?? [:]
            perDay[category.id, default: 0] += minutes
            result[day] = perDay
        }
        return result
    }

    /// 当日健身相关时间块合计（RecoveryContext.fitnessTimeMinutes 的来源；FITNESS_CATS）
    ///
    /// 语义 = lifttime workout.js:338-343 fitnessTimeToday（ms → 本 API 为分钟）：
    /// start 落在该日 且 categoryID ∈ FITNESS_CATS 的块时长之和。不查分类表
    /// （lifttime 同样直接按 cat 字符串比对；兜底分类 other 不在集合内）。
    public static func fitnessMinutes(_ blocks: [TimeBlock], day: DayKey, calendar: DayCalendar) -> Double {
        var seconds = 0.0
        for block in blocks where calendar.dayKey(for: block.start) == day
            && FITNESS_CATS.contains(block.categoryID) {
            seconds += block.end.timeIntervalSince(block.start)
        }
        return seconds / 60
    }

    // MARK: - 分类解析（lifttime catOf 的显式化）

    /// 按分类 id 解析；查不到 → `isFallback` 兜底分类。
    /// 语义等价 lifttime store.js:221-223 `catOf`（找不到归最后一个 = 默认表末位
    /// 「其他」），但用显式 isFallback 标志替代隐式末位（§3.1）。
    /// 兜底分类也不存在（异常数据，净化管线会补位）→ nil。
    public static func resolveCategory(_ id: String, in categories: [TimeCategory]) -> TimeCategory? {
        categories.first { $0.id == id }
            ?? categories.first { $0.isFallback }
    }

    // MARK: - 单槽计时器（日常/睡眠互斥，落盘崩溃恢复态由 DataStore active.json 承担）

    /// 启动计时的结果。
    public enum TimerStartOutcome: Equatable, Sendable {
        /// 单槽空闲：新计时已占用（调用方落盘 ActiveTimer）。
        case started(ActiveTimer)
        /// 单槽已被占用：互斥拒绝，原槽不动（lifttime time.js:86 睡眠计时中
        /// 「睡完再记这段时间」/ sleep.js:107「已有计时在进行」——双向互斥）。
        case rejected(occupiedBy: ActiveTimer)
    }

    /// 启动一段计时。单槽：已有任何进行中计时（无论 general / sleep）→ 拒绝。
    /// 崩溃恢复语义（§11 风险 8）：计时器只存 `startedAt` 时刻，不依赖后台 tick；
    /// 落盘由调用方经 `DataStore.save(active:)` 完成。
    public static func startTimer(kind: ActiveTimer.TimerKind, at startedAt: Date,
                                  current: ActiveTimer?) -> TimerStartOutcome {
        guard let current else { return .started(ActiveTimer(startedAt: startedAt, kind: kind)) }
        return .rejected(occupiedBy: current)
    }

    /// 停止计时并选分类保存（lifttime time.js:97-140 stopSheet 的 Core 部分：
    /// 保存 → push timeBlock + timer 置空；丢弃 = 调用方直接清槽，不走本函数）。
    /// 校验同 makeBlock：end ≤ startedAt 或分类表无法解析（无兜底）→ nil，不产块。
    public static func stopTimer(_ timer: ActiveTimer, at end: Date, categoryID: String,
                                 note: String?, categories: [TimeCategory]) -> TimeBlock? {
        makeBlock(start: timer.startedAt, end: end,
                  categoryID: categoryID, note: note, categories: categories)
    }

    // MARK: - 时间块补记 / 编辑（end > start 校验）

    /// 构造时间块（补记 manualSheet 与编辑 editSheet 共用落点）。
    /// - `end ≤ start` → nil（lifttime time.js:250「结束时间要晚于开始时间」；
    ///   结构性非法与净化管线 end>start 剔除同口径）；
    /// - categoryID 不在分类表 → 归兜底分类（catOf 语义；无兜底 → nil）；
    /// - note 去首尾空白，空串归 nil。
    public static func makeBlock(start: Date, end: Date, categoryID: String,
                                 note: String?, categories: [TimeCategory]) -> TimeBlock? {
        guard end > start,
              let resolved = resolveCategory(categoryID, in: categories)
        else { return nil }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TimeBlock(start: start,
                         end: end,
                         categoryID: resolved.id,
                         note: (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote)
    }

    /// 引用完整性收敛（§3.1 测试清单「块的 categoryID 必须能在分类表中解析」）：
    /// 把引用已不存在分类的块改挂兜底分类。导入备份后 / 外部数据喂入前调用
    /// （净化管线只校验 id 白名单正则，不校验分类表成员资格——成员资格只能由
    /// 本模块在分类表上下文里判断）。引用可解析的块原样保留（含 id / note）。
    public static func repairingOrphanedBlocks(_ blocks: [TimeBlock],
                                               categories: [TimeCategory]) -> [TimeBlock] {
        guard let fallback = categories.first(where: \.isFallback) else { return blocks }
        let known = Set(categories.map(\.id))
        return blocks.map { block in
            guard !known.contains(block.categoryID) else { return block }
            var fixed = block
            fixed.categoryID = fallback.id
            return fixed
        }
    }

    // MARK: - 分类管理（删除/归档 → 历史块归兜底；兜底不可删）

    /// 删除 / 归档分类的结果。
    public enum CategoryMutationOutcome: Equatable, Sendable {
        /// 已应用：返回新的 (categories, blocks)（历史块已改挂兜底分类）。
        case applied(categories: [TimeCategory], blocks: [TimeBlock])
        /// 目标是兜底分类：不可删 / 不可归档（§4 TimeCategory.isFallback 注释）。
        case rejectedFallback
        /// 分类表中无此 id。
        case notFound
    }

    /// 删除分类：历史块全部改挂兜底分类（§3.1；块不随分类消失，数据不丢）。
    public static func deleteCategory(id: String, categories: [TimeCategory],
                                      blocks: [TimeBlock]) -> CategoryMutationOutcome {
        guard let target = categories.first(where: { $0.id == id }) else { return .notFound }
        guard !target.isFallback else { return .rejectedFallback }
        let migrated = migrateBlocks(from: id, blocks: blocks, categories: categories)
        return .applied(categories: categories.filter { $0.id != id }, blocks: migrated)
    }

    /// 归档分类：分类保留在表中（isArchived = true，UI 不再提供选择），
    /// 其历史块同样改挂兜底分类（§3.1「删除/归档时历史块归 isFallback 兜底分类」）。
    public static func archiveCategory(id: String, categories: [TimeCategory],
                                       blocks: [TimeBlock]) -> CategoryMutationOutcome {
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return .notFound }
        guard !categories[index].isFallback else { return .rejectedFallback }
        var updated = categories
        updated[index].isArchived = true
        let migrated = migrateBlocks(from: id, blocks: blocks, categories: categories)
        return .applied(categories: updated, blocks: migrated)
    }

    private static func migrateBlocks(from removedID: String, blocks: [TimeBlock],
                                      categories: [TimeCategory]) -> [TimeBlock] {
        guard let fallback = categories.first(where: \.isFallback) else { return blocks }
        return blocks.map { block in
            guard block.categoryID == removedID else { return block }
            var fixed = block
            fixed.categoryID = fallback.id
            return fixed
        }
    }

    /// 新建自定义分类（§4.1 取色口径）：
    /// - id 过白名单正则（复用净化管线 `SanitizeLimits.isValidCategoryID`）且不与现有冲突；
    /// - label 去空白后非空；
    /// - hue 限 8 个彩色档——`neutral` 为兜底分类专属档，自建不得使用（UI 不提供
    ///   选择，Core 层再守一道）；默认 9 分类是骨架冻结物，不受本函数管辖。
    /// 不合法 → nil（categories 原样）。
    public static func addCategory(id: String, label: String, hue: ChartHue,
                                   to categories: [TimeCategory]) -> [TimeCategory]? {
        guard SanitizeLimits.isValidCategoryID(id),
              !categories.contains(where: { $0.id == id }),
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              hue != .neutral
        else { return nil }
        var clippedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if clippedLabel.count > SanitizeLimits.labelMaxLength {
            clippedLabel = String(clippedLabel.prefix(SanitizeLimits.labelMaxLength))
        }
        return categories + [TimeCategory(id: id, label: clippedLabel, hue: hue)]
    }
}
