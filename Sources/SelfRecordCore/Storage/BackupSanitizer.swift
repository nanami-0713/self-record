import Foundation

// MARK: - 净化管线（design.md §4「净化管线语义」；骨架冻结物 A 的一部分）

/// 不可信输入统一过 `BackupSanitizer`——导入备份与本地读盘走**同一条**管线（§1 原则 3）。
///
/// 三步元素级容错（§4，验收 = store.test.mjs「非法睡眠会话剔除后好条目存活、
/// 越界字段归 nil」语义；Swift Codable 默认整组抛错的行为已被 §13 实测否决）：
///
/// 1. **数组级元素容错**（`lenientArray`）：`JSONSerialization` 拆元素逐条 decode，
///    单条失败只丢该条不丢整组；
/// 2. **字段级宽容解码**：由各类型的宽松 `init(from:)` 承担
///    （`DayKey` / `MealSlot`→`.snack` / `SleepLatency`→nil / `feel` 类型错→nil 等，
///    见 Model/ 各文件）；
/// 3. **解码后值上重跑业务校验**（本文件各 `sanitize` 域函数）：
///    结构性非法（end≤start、时长>24h、非法分类 id）整条剔除；
///    越界数值收敛或归 nil；字符串截断；恰一个 isFallback。
///
/// 净化细节中设计文档未逐条写死的，按本文件的「骨架裁决」注释执行；
/// 要改走修复工程师（§12）。
public enum SanitizeLimits {
    public static let stringMaxLength = 2000
    public static let labelMaxLength = 64
    public static let collectionMax = 100_000
    public static let maxDepth = 6
    public static let importMaxBytes = 50_000_000

    public static let bodyweightRange: ClosedRange<Double> = 0...2000
    public static let sleepGoalRange: ClosedRange<Int> = 240...720
    public static let amountRange: ClosedRange<Double> = 0...10_000_000

    /// 时间分类 id 白名单校验（§4 TimeCategory.id 注释）：`^[A-Za-z0-9_-]{1,40}$`。
    /// （不用 static Regex：Regex 非 Sendable，Swift 6 严格并发下静态存储不过检；
    ///  语义等价的逐字符校验，无共享状态。）
    public static func isValidCategoryID(_ id: String) -> Bool {
        guard (1...40).contains(id.count) else { return false }
        return id.utf8.allSatisfy { c in
            (c >= 0x41 && c <= 0x5A)     // A-Z
                || (c >= 0x61 && c <= 0x7A)  // a-z
                || (c >= 0x30 && c <= 0x39)  // 0-9
                || c == 0x5F                 // _
                || c == 0x2D                 // -
        }
    }
}

public enum SanitizeError: Error, Equatable, Sendable {
    case tooLarge          // > 50MB（§5 导入上限）
    case notJSON           // 格式预检失败
    case tooDeep           // 解码深度 > 6
    case notObject         // 顶层不是 JSON 对象
}

// MARK: - 管线实现

public enum BackupSanitizer {

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: 步骤 1+2：元素级容错解码

    /// 本地读盘入口：文件顶层是数组——坏条丢弃、好条存活；文件整体不是数组 → []。
    public static func lenientArray<T: Decodable>(from data: Data,
                                                  decoder: JSONDecoder? = nil) -> [T] {
        let d = decoder ?? makeDecoder()
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []   // 半写/损坏 JSON：启动降级为空域（§10 存储测试语义）
        }
        return lenientArray(fromObject: object, decoder: d)
    }

    /// 文档内域数组入口（导入路径）：逐元素 decode。
    public static func lenientArray<T: Decodable>(fromObject object: Any,
                                                  decoder: JSONDecoder) -> [T] {
        guard let elements = object as? [Any] else { return [] }
        return elements.compactMap { lenientElement($0, decoder: decoder) }
    }

    /// 单元素（对象或标量）→ T；不可序列化或 decode 失败 → nil。
    public static func lenientElement<T: Decodable>(_ object: Any,
                                                    decoder: JSONDecoder) -> T? {
        guard JSONSerialization.isValidJSONObject(object) || object is NSNull,
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    // MARK: 步骤 3：值上业务校验（各域）

    /// 通用工具：截断 + 收敛 + 集合上限。
    static func clipped(_ s: String, to max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max))
    }

    static func clamp(_ v: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }

    static func orNil(_ v: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let v else { return nil }
        return range.contains(v) ? v : nil
    }

    static func bounded<T>(_ array: [T]) -> [T] {
        Array(array.prefix(SanitizeLimits.collectionMax))
    }

    public static func sanitize(_ settings: AppSettings) -> AppSettings {
        var s = settings
        s.bodyweightKg = orNil(s.bodyweightKg, in: SanitizeLimits.bodyweightRange)
        s.sleepGoalMinutes = min(max(s.sleepGoalMinutes, SanitizeLimits.sleepGoalRange.lowerBound),
                                 SanitizeLimits.sleepGoalRange.upperBound)
        s.weeklyBudgetYuan = orNil(s.weeklyBudgetYuan, in: SanitizeLimits.amountRange)
        s.monthlyBudgetYuan = orNil(s.monthlyBudgetYuan, in: SanitizeLimits.amountRange)
        // 净化要求 http(s)（§4 AIConfig.baseURLString 注释）
        if let url = s.aiConfig.baseURLString,
           let parsed = URL(string: url),
           let scheme = parsed.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            s.aiConfig.baseURLString = clipped(url, to: SanitizeLimits.stringMaxLength)
        } else {
            s.aiConfig.baseURLString = nil
        }
        s.aiConfig.model = clipped(s.aiConfig.model, to: SanitizeLimits.stringMaxLength)
        return s
    }

    public static func sanitize(_ categories: [TimeCategory]) -> [TimeCategory] {
        // 结构性非法：id 不在白名单正则内 → 剔除
        var kept = categories.filter { SanitizeLimits.isValidCategoryID($0.id) }
        kept = kept.map { c in
            var c = c
            c.label = clipped(c.label, to: SanitizeLimits.labelMaxLength)
            return c
        }
        // 恰一个 isFallback（§4 管线 3）：多则保首个清余，无则归位「other」
        let fallbacks = kept.filter(\.isFallback)
        if fallbacks.count > 1 {
            let firstID = fallbacks.first?.id
            for index in kept.indices {
                if kept[index].isFallback, kept[index].id != firstID {
                    kept[index].isFallback = false
                }
            }
        }
        if fallbacks.isEmpty {
            if let index = kept.firstIndex(where: { $0.id == "other" }) {
                kept[index].isFallback = true
            } else {
                kept.append(TimeCategory(id: "other", label: "其他", hue: .neutral, isFallback: true))
            }
        }
        return bounded(kept)
    }

    public static func sanitize(_ blocks: [TimeBlock]) -> [TimeBlock] {
        // 结构性非法：end ≤ start → 整条剔除（lifttime cleanRecords return null → filter）；
        // categoryID 不在白名单正则 → 整条剔除（分类 id 白名单，§4 管线 3；
        // 「categoryID 必须能在分类表中解析」的引用完整性由 time-tracking 模块兜底）
        var kept = blocks.filter {
            $0.end > $0.start && SanitizeLimits.isValidCategoryID($0.categoryID)
        }
        kept = kept.map { b in
            var b = b
            b.note = b.note.map { clipped($0, to: SanitizeLimits.stringMaxLength) }
            return b
        }
        return bounded(kept)
    }

    public static func sanitize(_ sessions: [SleepSession]) -> [SleepSession] {
        // 结构性非法：end ≤ start 或时长 > 24h → 整条剔除（cleanSleepSessions 语义）
        let daySeconds: Double = 24 * 60 * 60
        var kept = sessions.filter { $0.end > $0.start && $0.end.timeIntervalSince($0.start) <= daySeconds }
        kept = kept.map { s in
            var s = s
            // 越界字段归 nil（不丢整条）：feel 1–5、wakeCount 0–3、dayOverride 重跑构造校验
            if let feel = s.feel, !(1...5).contains(feel) { s.feel = nil }
            if let wakes = s.wakeCount, !(0...3).contains(wakes) { s.wakeCount = nil }
            s.note = s.note.map { clipped($0, to: SanitizeLimits.stringMaxLength) }
            if let override = s.dayOverride, !DayKey.isValid(override.rawValue) {
                s.dayOverride = nil
            }
            return s
        }
        return bounded(kept)
    }

    public static func sanitize(_ workouts: [Workout]) -> [Workout] {
        // 结构性非法：endedAt ≤ startedAt → 整条剔除
        var kept = workouts.filter { $0.endedAt > $0.startedAt }
        kept = kept.map { w in
            var w = w
            if let feeling = w.feeling, !(1...5).contains(feeling) { w.feeling = nil }
            w.notes = w.notes.map { clipped($0, to: SanitizeLimits.stringMaxLength) }
            // 数值收敛合法域：组数据非负（重量/次数）
            w.entries = w.entries.map { entry in
                var entry = entry
                entry.sets = entry.sets.map { set in
                    var set = set
                    set.weightKg = max(0, set.weightKg)
                    set.reps = max(0, set.reps)
                    return set
                }
                return entry
            }
            // analysis 快照为自产数据，整体保留（历史不随口径升级漂移，§3.3）
            return w
        }
        return bounded(kept)
    }

    public static func sanitize(_ exercises: [Exercise]) -> [Exercise] {
        // 结构性非法：id/name 为空 → 剔除
        var kept = exercises.filter { !$0.id.isEmpty && !$0.name.isEmpty }
        kept = kept.map { e in
            var e = e
            e.name = clipped(e.name, to: SanitizeLimits.stringMaxLength)
            e.aliases = e.aliases.map { clipped($0, to: SanitizeLimits.stringMaxLength) }
            return e
        }
        return bounded(kept)
    }

    public static func sanitize(_ entries: [DietEntry]) -> [DietEntry] {
        let sanitized = entries.map { e in
            var e = e
            e.rawText = clipped(e.rawText, to: SanitizeLimits.stringMaxLength)
            e.costYuan = orNil(e.costYuan, in: SanitizeLimits.amountRange)
            e.unmatched = e.unmatched.map { clipped($0, to: SanitizeLimits.stringMaxLength) }
            e.totals = MacroTotals(
                kcal: max(0, e.totals.kcal),
                proteinG: max(0, e.totals.proteinG),
                carbsG: max(0, e.totals.carbsG),
                fatG: max(0, e.totals.fatG))
            e.items = e.items.map { m in
                var m = m
                m.grams = max(0, m.grams)
                m.per100g = BackupSanitizer.converged(m.per100g)
                return m
            }
            e.manualItems = e.manualItems.map { m in
                var m = m
                m.grams = max(0, m.grams)
                m.per100g = BackupSanitizer.converged(m.per100g)
                return m
            }
            return e
        }
        return bounded(sanitized)
    }

    public static func sanitize(_ foods: [CustomFood]) -> [CustomFood] {
        var kept = foods.filter { !$0.name.isEmpty }
        kept = kept.map { f in
            var f = f
            f.name = clipped(f.name, to: SanitizeLimits.stringMaxLength)
            f.useCount = max(0, f.useCount)
            f.per100g = BackupSanitizer.converged(f.per100g)
            return f
        }
        return bounded(kept)
    }

    public static func sanitize(_ expenses: [Expense]) -> [Expense] {
        let sanitized = expenses.map { e in
            var e = e
            e.amountYuan = clamp(e.amountYuan, SanitizeLimits.amountRange)
            e.note = e.note.map { clipped($0, to: SanitizeLimits.stringMaxLength) }
            return e
        }
        return bounded(sanitized)
    }

    static func converged(_ p: Per100g) -> Per100g {
        Per100g(kcal: max(0, p.kcal),
                proteinG: max(0, p.proteinG),
                carbsG: max(0, p.carbsG),
                fatG: max(0, p.fatG),
                portionGrams: p.portionGrams.map { max(0, $0) },
                portionUnit: p.portionUnit.map { clipped($0, to: SanitizeLimits.stringMaxLength) })
    }

    // MARK: 文档级净化（导入路径：50MB 预检 + 深度限制 + 逐域）

    public static func sanitizeDocument(from data: Data) throws -> BackupDocument {
        guard data.count <= SanitizeLimits.importMaxBytes else { throw SanitizeError.tooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            throw SanitizeError.notJSON
        }
        guard depth(of: root) <= SanitizeLimits.maxDepth else { throw SanitizeError.tooDeep }
        guard let dict = root as? [String: Any] else { throw SanitizeError.notObject }

        let decoder = makeDecoder()

        func element<T: Decodable>(_ key: String) -> T? {
            guard let object = dict[key] else { return nil }
            return lenientElement(object, decoder: decoder)
        }
        func array<T: Decodable>(_ key: String) -> [T] {
            guard let object = dict[key] else { return [] }
            return lenientArray(fromObject: object, decoder: decoder)
        }

        // version 归一 currentVersion（骨架裁决：未知/未来版本号不透传，净化语义照跑）
        return BackupDocument(
            version: BackupDocument.currentVersion,
            exportedAt: element("exportedAt") ?? Date(),
            settings: sanitize(element("settings") ?? AppSettings()),
            categories: sanitize(array("categories")),
            timeBlocks: sanitize(array("timeBlocks")),
            sleepSessions: sanitize(array("sleepSessions")),
            workouts: sanitize(array("workouts")),
            customExercises: sanitize(array("customExercises")),
            dietEntries: sanitize(array("dietEntries")),
            expenses: sanitize(array("expenses")),
            customFoods: sanitize(array("customFoods")))
    }

    /// JSON 嵌套深度（对象/数组各计一层，标量 1）。
    static func depth(of value: Any) -> Int {
        switch value {
        case let dict as [String: Any]:
            return 1 + (dict.values.map(depth).max() ?? 0)
        case let array as [Any]:
            return 1 + (array.map(depth).max() ?? 0)
        default:
            return 1
        }
    }
}
