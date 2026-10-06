import Foundation

// MARK: - diet 模块实现（design.md §3.4）
//
// 职责：中文自然语言记餐解析（中文数字、市制两=50g、克/毫升/升、量词、尾部写法、
// 多分隔符）→ 三层估算兜底（①库命中（内置 326 项 + 自学习库，长名优先）
// → ②8 大类猜测 + 类别均值预填（ManualFoodItem，可改可整项不计入）
// → ③AI 估算后置（接缝 = 三层结构与 ManualFoodItem.guessSource 概念，§9-7））
// → 营养目标 / 日建议 / 日与区间总结 / dayIntake 快照 / 餐次推断与练后预选。
//
// lifttime 对应：js/foods.js + js/nutrition.js（:24-89 解析、:145-149 guessFor、
// :171-179 learnFood、:239-243 练后判定）；餐次预选 js/diet.js:374-387 guessMeal。
//
// 口径锁定（与 lifttime 一字不差）：
// - 餐次六档 nutrition.js:5-12 MEALS；练后判定 nutrition.js:239-243；
// - tags 10 档 foods.js:2-3，挂库命中项；手估项无 tags、不参与 tags 聚合
//   （日汇总只算 items，nutrition.js:206-208 同口径）；
// - proteinHitDays/daysTracked（全记录日达标率）是 budgetAdvice 的
//   proteinHitRate 注入口径（B1）；trainingDayHitRate 是另一产物（报告用）。
//
// 实现说明：解析为手写 tokenizer（非正则），语义逐条对照 lifttime 正则
// （数量在前、单位可选可缺省；尾部写法仅接受重量/容量单位；「两」同时是
// 中文数字与市制单位，数量优先消费——「两碗米饭」=2 碗、「二两白酒」=2×50g）。

// MARK: - 返回类型

/// 营养目标（lifttime nutrition.js:182-194 targets）。默认值 = 无体重通用默认
/// （cal 2000 / 蛋白 80–110），保证「空数据日」与 `NutritionTargets()` 相等。
public struct NutritionTargets: Codable, Sendable, Equatable {
    public var kcal: Int = 2000                 // 体重×30，无体重 2000
    public var proteinLo: Int = 80              // 1.6 g/kg 下限，无体重 80
    public var proteinHi: Int = 110             // 2.2 g/kg 上限，无体重 110
    public var proteinTarget: Int = 95          // (lo+hi)/2
    public var carbsG: Int = 250                // cal×50%/4
    public var fatG: Int = 60                   // cal×27%/9
    public var trainedToday: Bool = false

    public init(kcal: Int = 2000,
                proteinLo: Int = 80,
                proteinHi: Int = 110,
                proteinTarget: Int = 95,
                carbsG: Int = 250,
                fatG: Int = 60,
                trainedToday: Bool = false) {
        self.kcal = kcal
        self.proteinLo = proteinLo
        self.proteinHi = proteinHi
        self.proteinTarget = proteinTarget
        self.carbsG = carbsG
        self.fatG = fatG
        self.trainedToday = trainedToday
    }
}

/// 单餐次聚合（lifttime summarize 的 byMeal 值：{kcal, count}）
public struct MealAggregate: Codable, Sendable, Equatable {
    public var kcal: Double = 0
    public var count: Int = 0

    public init(kcal: Double = 0, count: Int = 0) {
        self.kcal = kcal
        self.count = count
    }
}

/// summarize 产物（lifttime nutrition.js:197-215）：宏量合计 + 计数 + 按餐次 + 标签。
/// tags 只聚合库命中项（items）；手估项（manualItems）无标签不参与——口径 §3.4。
public struct DietDayTotals: Codable, Sendable, Equatable {
    public var totals: MacroTotals = MacroTotals()
    public var itemCount: Int = 0
    public var unmatchedCount: Int = 0
    public var byMeal: [MealSlot: MealAggregate] = [:]
    public var tagCounts: [FoodTag: Int] = [:]

    public init(totals: MacroTotals = MacroTotals(),
                itemCount: Int = 0,
                unmatchedCount: Int = 0,
                byMeal: [MealSlot: MealAggregate] = [:],
                tagCounts: [FoodTag: Int] = [:]) {
        self.totals = totals
        self.itemCount = itemCount
        self.unmatchedCount = unmatchedCount
        self.byMeal = byMeal
        self.tagCounts = tagCounts
    }
}

/// dailySummary 返回类型（§2.1 冻结签名的产物；字段语义 = lifttime dailyAdvice 的
/// {summary, targets, advice}）。默认值 = 空数据日，供占位契约与 UI 空态复用。
public struct DietDaySummary: Codable, Sendable, Equatable {
    public var totals: DietDayTotals = DietDayTotals()
    public var targets: NutritionTargets = NutritionTargets()
    public var advice: [String] = [DietEngine.noEntryDayAdvice]

    public init(totals: DietDayTotals = DietDayTotals(),
                targets: NutritionTargets = NutritionTargets(),
                advice: [String] = [DietEngine.noEntryDayAdvice]) {
        self.totals = totals
        self.targets = targets
        self.advice = advice
    }
}

/// 高频食物（lifttime periodDiet 的 topFoods 元素）
public struct FoodFrequency: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

/// 训练×饮食联动（lifttime nutrition.js:310-322 trainingLink）+ B1 双口径的
/// trainingDayHitRate（训练日达标/训练日有记录数；无训练日记录 → nil）。
public struct TrainingDietLink: Codable, Sendable, Equatable {
    public var trainedDays: Int = 0
    public var trackedTrainedDays: Int = 0
    public var proteinHitOnTrainedDays: Int = 0
    public var trainingDayHitRate: Double?

    public init(trainedDays: Int = 0,
                trackedTrainedDays: Int = 0,
                proteinHitOnTrainedDays: Int = 0,
                trainingDayHitRate: Double? = nil) {
        self.trainedDays = trainedDays
        self.trackedTrainedDays = trackedTrainedDays
        self.proteinHitOnTrainedDays = proteinHitOnTrainedDays
        self.trainingDayHitRate = trainingDayHitRate
    }
}

/// periodDiet 返回类型（§2.1 冻结签名的产物）。双达标率口径并存（B1）：
/// • trainingDayHitRate（TrainingDietLink 内）——训练日口径，报告/日简报用；
/// • proteinHitDays / daysTracked——全记录日达标率，budgetAdvice 的
///   proteinHitRate 注入用（lifttime budget.js:423-424 动态计算）。
public struct DietPeriodSummary: Codable, Sendable, Equatable {
    public var daysTracked: Int = 0
    public var avg: MacroTotals = MacroTotals()
    public var proteinHitDays: Int = 0
    public var topFoods: [FoodFrequency] = []
    public var lateDays: Int = 0
    public var trainingLink: TrainingDietLink = TrainingDietLink()
    public var targets: NutritionTargets = NutritionTargets()
    public var advice: [String] = [DietEngine.noRecordPeriodAdvice]
    /// 有记录的日键（升序；lifttime daySums 的键序列等价物）
    public var trackedDayKeys: [DayKey] = []

    public init(daysTracked: Int = 0,
                avg: MacroTotals = MacroTotals(),
                proteinHitDays: Int = 0,
                topFoods: [FoodFrequency] = [],
                lateDays: Int = 0,
                trainingLink: TrainingDietLink = TrainingDietLink(),
                targets: NutritionTargets = NutritionTargets(),
                advice: [String] = [DietEngine.noRecordPeriodAdvice],
                trackedDayKeys: [DayKey] = []) {
        self.daysTracked = daysTracked
        self.avg = avg
        self.proteinHitDays = proteinHitDays
        self.topFoods = topFoods
        self.lateDays = lateDays
        self.trainingLink = trainingLink
        self.targets = targets
        self.advice = advice
        self.trackedDayKeys = trackedDayKeys
    }
}

/// parseMealText 产物：命中项 + 未识别 + 解析合计（lifttime :74-89）
public struct ParsedMeal: Codable, Sendable, Equatable {
    public var items: [FoodMatch] = []
    public var unmatched: [String] = []
    public var totals: MacroTotals = MacroTotals()

    public init(items: [FoodMatch] = [],
                unmatched: [String] = [],
                totals: MacroTotals = MacroTotals()) {
        self.items = items
        self.unmatched = unmatched
        self.totals = totals
    }
}

/// 三层兜底第②层的类别均值（lifttime nutrition.js:94-103 ESTIMATE_CATS，8 大类）
public struct EstimateCategory: Codable, Sendable, Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var label: String
    public var per100g: Per100g
    public var defaultGrams: Double             // 类别默认份克数（预填可改）

    public init(key: String, label: String, per100g: Per100g, defaultGrams: Double) {
        self.key = key
        self.label = label
        self.per100g = per100g
        self.defaultGrams = defaultGrams
    }
}

// MARK: - 引擎

/// 饮食引擎（§3.4）。dailySummary / periodDiet / dayIntake 三个签名 = 骨架
/// 冻结物 B（§2.1），一字不改；其余为模块内 API（解析/兜底/学习/目标/汇总）。
public enum DietEngine {

    /// 空日文案（lifttime nutrition.js:232）
    public static let noEntryDayAdvice = "今天还没记饮食，点「记一餐」开始。"
    /// 空区间文案（lifttime nutrition.js:329）
    public static let noRecordPeriodAdvice = "这个时间段还没有饮食记录。"

    // MARK: 8 大类估算表（lifttime ESTIMATE_CATS 同值）

    public static let estimateCategories: [EstimateCategory] = [
        EstimateCategory(key: "meat", label: "肉菜/荤菜",
                         per100g: Per100g(kcal: 190, proteinG: 17, carbsG: 3, fatG: 12),
                         defaultGrams: 200),
        EstimateCategory(key: "staple", label: "主食",
                         per100g: Per100g(kcal: 150, proteinG: 4, carbsG: 30, fatG: 1.5),
                         defaultGrams: 250),
        EstimateCategory(key: "veg", label: "素菜/蔬菜",
                         per100g: Per100g(kcal: 50, proteinG: 2.5, carbsG: 6, fatG: 2.5),
                         defaultGrams: 200),
        EstimateCategory(key: "soup", label: "汤/羹",
                         per100g: Per100g(kcal: 45, proteinG: 2.5, carbsG: 5, fatG: 1.5),
                         defaultGrams: 300),
        EstimateCategory(key: "snack", label: "零食/甜点",
                         per100g: Per100g(kcal: 420, proteinG: 6, carbsG: 58, fatG: 18),
                         defaultGrams: 100),
        EstimateCategory(key: "drink", label: "饮品",
                         per100g: Per100g(kcal: 45, proteinG: 1, carbsG: 9, fatG: 1.5),
                         defaultGrams: 300),
        EstimateCategory(key: "mixed", label: "混合菜/盖饭",
                         per100g: Per100g(kcal: 150, proteinG: 7, carbsG: 18, fatG: 6),
                         defaultGrams: 350),
        EstimateCategory(key: "other", label: "其他",
                         per100g: Per100g(kcal: 200, proteinG: 8, carbsG: 20, fatG: 9),
                         defaultGrams: 200),
    ]

    /// estCatOf 端口：未知 key 回退最后一个类别（other）
    public static func estimateCategory(for key: String) -> EstimateCategory {
        estimateCategories.first { $0.key == key } ?? estimateCategories[estimateCategories.count - 1]
    }

    // MARK: 解析（lifttime nutrition.js:24-89）

    /// 中文数字（lifttime CN_NUM）。「两」既是数字（=2）又是市制单位（=50g），
    /// 数量优先消费：段首「两」先按数字解析，其后再匹配单位。
    private static let cnNumerals: [Character: Double] = [
        "半": 0.5, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
    ]

    /// 中国市制单位：两 = 50g（「二两白酒」）
    private static let unitGrams: [String: Double] = ["两": 50]

    /// 段首量词表（lifttime :29 正则的 unit 组，约 35 种；ASCII 大小写不敏感）
    private static let leadUnits: [(unit: String, chars: [Character])] = [
        "kg", "克", "毫升", "ml", "升", "l",
        "个", "只", "杯", "碗", "份", "根", "片", "块", "勺", "把", "罐", "瓶", "包",
        "盒", "球", "串", "角", "条", "颗", "粒", "盘", "屉", "袋", "套", "餐", "瓣",
        "段", "卷", "听", "两", "g",
    ].map { ($0, Array($0)) }

    /// 尾部写法与抠克数共用的重量单位（kg 必须排在 g 前）；仅这些单位支持段尾写法。
    private static let weightUnits: [(unit: String, chars: [Character], isKg: Bool)] = [
        ("kg", Array("kg"), true), ("克", Array("克"), false),
        ("毫升", Array("毫升"), false), ("ml", Array("ml"), false),
        ("g", Array("g"), false),
    ]

    /// 解析整段描述（顿号/逗号/分号/加号/换行分隔，lifttime :74-89）。
    /// 未识别段进 unmatched，不强估——三层兜底由调用方对 unmatched 走 guessFor。
    public static func parseMealText(_ text: String, customFoods: [CustomFood] = []) -> ParsedMeal {
        var items: [FoodMatch] = []
        var unmatched: [String] = []
        for segment in splitSegments(text) {
            switch parseSegment(segment, customFoods: customFoods) {
            case .none:
                continue                                    // 空段跳过
            case .unmatched(let raw):
                unmatched.append(raw)
            case .matched(let match):
                items.append(match)
            }
        }
        var totals = MacroTotals()
        for item in items {
            let m = item.macros
            totals.kcal += m.kcal
            totals.proteinG += m.proteinG
            totals.carbsG += m.carbsG
            totals.fatG += m.fatG
        }
        totals.proteinG = round1(totals.proteinG)
        totals.carbsG = round1(totals.carbsG)
        totals.fatG = round1(totals.fatG)
        return ParsedMeal(items: items, unmatched: unmatched, totals: totals)
    }

    private enum SegmentParse {
        case matched(FoodMatch)
        case unmatched(String)
    }

    /// 解析单个食物段（lifttime parseSegment :24-67）。空段 → nil（调用方跳过）。
    private static func parseSegment(_ segment: String, customFoods: [CustomFood]) -> SegmentParse? {
        let text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var qty: Double?
        var unit = ""
        var rest = text
        if let lead = parseLead(text) {
            qty = lead.qty
            unit = lead.unit
            rest = lead.rest
        } else if let tail = parseTail(text) {
            qty = tail.qty
            unit = tail.unit
            rest = tail.rest
        }

        guard let food = findFood(rest, customFoods: customFoods) else {
            return .unmatched(text)                          // 未识别不强行估算
        }

        // 克数换算（lifttime :47-53）：显式重量/容量 > 市制两 > 按份数
        let grams: Double
        if let weight = weightUnitGrams(unit) {
            grams = (qty ?? 0) * weight
        } else {
            grams = (qty ?? 1) * (food.per100g.portionGrams ?? 100)
        }
        // 克数四舍五入后入库；条目宏量由 `FoodMatch.macros` 按入库克数换算
        //（整克锚点用例与 lifttime 无差异）
        return .matched(FoodMatch(name: food.name,
                                  grams: grams.rounded(),
                                  per100g: food.per100g,
                                  tags: food.tags))
    }

    /// 单位 → 每单位克数（g/克=1、kg/升=1000、ml/毫升≈1 液体密度、两=50）；
    /// 非重量单位返回 nil（走按份数分支）。
    private static func weightUnitGrams(_ unit: String) -> Double? {
        switch unit {
        case "g", "克", "ml", "毫升": return 1
        case "kg", "l", "升": return 1000
        default: return unitGrams[unit]
        }
    }

    /// 段首「数量+可选单位」（lifttime :29 前导正则的手写等价）。
    /// 数量 = `[0-9]+(\.[0-9]+)?` 或单个中文数字；单位可缺省。
    private static func parseLead(_ text: String) -> (qty: Double, qtyText: String, unit: String, rest: String)? {
        let chars = Array(text)
        guard let first = chars.first else { return nil }
        var qtyText = ""
        var qty: Double?
        var index = 0
        if isASCIIDigit(first) {
            var end = 0
            while end < chars.count, isASCIIDigit(chars[end]) { end += 1 }
            if end < chars.count, chars[end] == "." {
                var frac = end + 1
                while frac < chars.count, isASCIIDigit(chars[frac]) { frac += 1 }
                if frac > end + 1 { end = frac }             // 有小数位才消费点
            }
            qtyText = String(chars[0..<end])
            qty = Double(qtyText)
            index = end
        } else if let cn = cnNumerals[first] {
            qtyText = String(first)
            qty = cn
            index = 1
        } else {
            return nil
        }
        guard let value = qty else { return nil }
        let unit = matchLeadUnit(chars, at: index) ?? ""
        return (value, qtyText, unit, String(chars[(index + unit.count)...]))
    }

    /// 段尾克数写法「米饭300g」（lifttime :36 尾部正则的手写等价）：
    /// 数字 + 重量单位收尾，前缀至少一个字符；无则 nil。
    private static func parseTail(_ text: String) -> (qty: Double, unit: String, rest: String)? {
        let chars = Array(text)
        for token in weightUnits {
            let unitCount = token.chars.count
            let unitStart = chars.count - unitCount
            guard unitStart >= 1, matchesCaseInsensitive(chars, at: unitStart, token.chars) else { continue }
            // 从单位前向前抠 `[0-9]+(\.[0-9]+)?`
            var start = unitStart
            while start > 0, isASCIIDigit(chars[start - 1]) { start -= 1 }
            if start > 0, chars[start - 1] == "." {
                var dot = start - 1
                while dot > 0, isASCIIDigit(chars[dot - 1]) { dot -= 1 }
                if dot < start - 1 { start = dot }           // 点前有数字才并入小数
            }
            guard start >= 1, start < unitStart,
                  let qty = Double(String(chars[start..<unitStart]))
            else { continue }
            return (qty, token.unit, String(chars[0..<start]))
        }
        return nil
    }

    /// 分隔符切分（lifttime :75 `split(/[，,、；;+\n]+/)`：连续分隔符合并）
    private static func splitSegments(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            if "，,、；;+\n".contains(ch) {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// 文本归一（lifttime foods.js:344 norm）：去空白 + 小写
    private static func norm(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace }.lowercased())
    }

    private static func isASCIIDigit(_ c: Character) -> Bool {
        guard let a = c.asciiValue else { return false }
        return a >= 48 && a <= 57
    }

    private static func matchLeadUnit(_ chars: [Character], at index: Int) -> String? {
        for token in leadUnits where matchesCaseInsensitive(chars, at: index, token.chars) {
            return token.unit
        }
        return nil
    }

    private static func matchesCaseInsensitive(_ chars: [Character], at index: Int, _ unit: [Character]) -> Bool {
        guard index >= 0, index + unit.count <= chars.count else { return false }
        for offset in unit.indices {
            if chars[index + offset].lowercased() != unit[offset].lowercased() { return false }
        }
        return true
    }

    /// 长度降序 + 原序破平的稳定排序（JS `sort` 稳定语义的等价物）
    private static func stableSortedByLengthDesc<T>(_ items: [T], name: (T) -> String) -> [T] {
        items.enumerated()
            .sorted { lhs, rhs in
                let l = name(lhs.element).count, r = name(rhs.element).count
                if l != r { return l > r }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: 食物库查找（lifttime foods.js:348-371）

    /// 按名称/别名查找（长名优先，防「酸奶」截胡「希腊酸奶」）。
    /// customFoods 自学习库优先于内置库：完全匹配 → 包含匹配（双向）。
    public static func findFood(_ text: String, customFoods: [CustomFood] = []) -> FoodLibraryEntry? {
        let q = norm(text)
        guard !q.isEmpty else { return nil }
        if !customFoods.isEmpty {
            if let exact = customFoods.first(where: { norm($0.name) == q }) {
                return libraryEntry(from: exact)
            }
            let byLength = stableSortedByLengthDesc(customFoods, name: \.name)
            if let hit = byLength.first(where: { q.contains(norm($0.name)) || norm($0.name).contains(q) }) {
                return libraryEntry(from: hit)
            }
        }
        let sorted = FoodLibrary.sortedByNameDesc
        if let exact = sorted.first(where: { norm($0.name) == q || $0.aliases.contains { norm($0) == q } }) {
            return exact
        }
        return sorted.first { q.contains(norm($0.name)) || $0.aliases.contains { q.contains(norm($0)) } }
    }

    /// CustomFood → 统一条目（lifttime customToFood：g 缺省 100、u 缺省「份」、tags 用条目自带）
    private static func libraryEntry(from custom: CustomFood) -> FoodLibraryEntry {
        var per100 = custom.per100g
        per100.portionGrams = per100.portionGrams ?? 100
        per100.portionUnit = per100.portionUnit ?? "份"
        return FoodLibraryEntry(name: custom.name,
                                aliases: [],
                                per100g: per100,
                                tags: custom.tags.isEmpty ? [.custom] : custom.tags)
    }

    // MARK: 未识别食物的估算助手（lifttime :106-149）

    /// 从文本里抠克数：「佛跳墙300g」→300、「大杯奶茶500毫升」→500、「1.5kg西瓜」→1500（lifttime :116-121）
    public static func extractGrams(_ text: String) -> Double? {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard isASCIIDigit(chars[i]) else { i += 1; continue }
            var end = i
            while end < chars.count, isASCIIDigit(chars[end]) { end += 1 }
            if end < chars.count, chars[end] == "." {
                var frac = end + 1
                while frac < chars.count, isASCIIDigit(chars[frac]) { frac += 1 }
                if frac > end + 1 { end = frac }
            }
            guard let value = Double(String(chars[i..<end])) else { return nil }
            var unitAt = end
            while unitAt < chars.count, chars[unitAt].isWhitespace { unitAt += 1 }   // \s*
            for token in weightUnits where matchesCaseInsensitive(chars, at: unitAt, token.chars) {
                return (token.isKg ? value * 1000 : value).rounded()
            }
            i = end
        }
        return nil
    }

    /// 按关键词猜类别（lifttime GUESS_RULES :106-130，规则顺序即优先级：
    /// 汤 → 饮品 → 零食 → 主食 → 肉菜 → 素菜，兜底 other）。
    /// 返回类别 key（与 ManualFoodItem.guessCategory / estimateCategory(for:) 对齐）。
    public static func guessCategory(_ text: String) -> String {
        if text.contains("汤") || text.contains("羹") { return "soup" }
        if containsAny(text, ["奶茶", "果汁", "咖啡", "可乐", "雪碧", "啤", "红酒", "白酒",
                              "豆浆", "酸奶", "鲜奶", "柠檬茶", "饮"])
            || text.hasSuffix("茶") || text.hasSuffix("汁") { return "drink" }
        if containsAny(text, ["蛋糕", "糖果", "饼干", "薯片", "巧克力", "冰淇淋", "雪糕",
                              "甜甜圈", "布丁", "蛋挞", "麻花", "辣条", "爆米花"]) { return "snack" }
        if containsAny(text, ["炒饭", "炒面", "饭", "面条", "米线", "米粉", "馒头", "包子",
                              "饺", "馄饨", "馍", "寿司", "三明治", "汉堡", "意面", "拉面",
                              "河粉", "粥"])
            || containsBingNotFollowedByGan(text) { return "staple" }   // 饼(?!干)
        if containsAny(text, ["鸡", "鸭", "鹅", "牛", "羊", "猪", "鱼", "虾", "蟹", "肉",
                              "排骨", "肘", "蹄", "香肠", "火腿", "丸", "翅", "扒"]) { return "meat" }
        if containsAny(text, ["菜", "沙拉", "蔬", "菌", "菇", "木耳", "海带"]) { return "veg" }
        return "other"
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.first(where: text.contains) != nil
    }

    /// 「饼(?!干)」：存在不被「干」紧跟的「饼」（lifttime staple 规则的负向前瞻）
    private static func containsBingNotFollowedByGan(_ text: String) -> Bool {
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: "饼", range: range) {
            if !text[found.upperBound...].hasPrefix("干") { return true }
            range = found.upperBound..<text.endIndex
        }
        return false
    }

    /// 类别 + 克数 → 估算宏量（lifttime estimateFor :133-142；克数非正回退类别默认份）
    public static func estimateFor(_ category: EstimateCategory, grams: Double) -> MacroTotals {
        let ratio = (grams > 0 ? grams : category.defaultGrams) / 100
        return macros(per100g: category.per100g, ratio: ratio)
    }

    public static func estimateFor(categoryKey: String, grams: Double) -> MacroTotals {
        estimateFor(estimateCategory(for: categoryKey), grams: grams)
    }

    /// 对一段未识别文本给出完整猜测（lifttime guessFor :145-149）：
    /// 类别 + 克数（抠文本克数，无则类别默认份）+ 类别均值预填。
    /// 产物 = 三层兜底第②层的手估预填，可改克数、可整项不计入；无 tags（§3.4 口径）。
    public static func guessFor(_ text: String) -> ManualFoodItem {
        let key = guessCategory(text)
        let category = estimateCategory(for: key)
        let grams = extractGrams(text) ?? category.defaultGrams
        return ManualFoodItem(name: text,
                              grams: grams,
                              per100g: category.per100g,
                              isExcluded: false,
                              guessCategory: key)
    }

    // MARK: 自学习库（lifttime :163-179）

    /// 从原始文本提取干净食物名（去前导数量与单位、去尾部克数；lifttime cleanFoodName）
    public static func cleanFoodName(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = trimmed
        if let lead = parseLead(s) {
            s = String(s.dropFirst(lead.qtyText.count + lead.unit.count))
        }
        if let tail = parseTail(s) { s = tail.rest }
        let result = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? trimmed : result
    }

    /// 把一条手估条目学进自学习库（归一为每 100g，lifttime learnFood :171-179）。
    /// 拒绝零值（无克数 / 无热量）、空名与超长名（>20 字符）；默认打 `custom` 标签。
    public static func learnFood(_ item: ManualFoodItem) -> CustomFood? {
        guard item.grams > 0 else { return nil }
        let absoluteKcal = item.per100g.kcal * item.grams / 100   // 这一份的实际热量
        guard absoluteKcal > 0 else { return nil }
        let name = cleanFoodName(item.name)
        guard !name.isEmpty, name.count <= 20 else { return nil }
        let r = 100.0 / item.grams
        return CustomFood(
            name: name,
            per100g: Per100g(
                kcal: (absoluteKcal * r).rounded(),
                proteinG: round1(item.per100g.proteinG * item.grams / 100 * r),
                carbsG: round1(item.per100g.carbsG * item.grams / 100 * r),
                fatG: round1(item.per100g.fatG * item.grams / 100 * r),
                portionGrams: item.grams.rounded(),
                portionUnit: "份"),
            tags: [.custom],
            useCount: 0)
    }

    // MARK: 目标 / 合计（lifttime :151-161、:182-194、:197-215）

    /// 营养目标（lifttime targets：体重×30 kcal、蛋白 1.6–2.2 g/kg、碳水 50%、脂肪 27%；
    /// 无体重给通用默认。trainedToday 只入产物字段不改数值——lifttime 同口径）
    public static func targets(bodyweightKg: Double?, trainedToday: Bool) -> NutritionTargets {
        let bw: Double? = {
            guard let v = bodyweightKg, v > 0 else { return nil }
            return v
        }()
        let proteinLo = bw.map { Int(($0 * 1.6).rounded()) } ?? 80
        let proteinHi = bw.map { Int(($0 * 2.2).rounded()) } ?? 110
        let kcal = bw.map { Int(($0 * 30).rounded()) } ?? 2000
        return NutritionTargets(
            kcal: kcal,
            proteinLo: proteinLo,
            proteinHi: proteinHi,
            proteinTarget: Int((Double(proteinLo + proteinHi) / 2).rounded()),
            carbsG: Int((Double(kcal) * 0.5 / 4).rounded()),
            fatG: Int((Double(kcal) * 0.27 / 9).rounded()),
            trainedToday: trainedToday)
    }

    /// 解析结果 + 手估条目 → 这一餐总宏量（lifttime entryTotals :151-161）。
    /// isExcluded 的手估项不计入（Swift 模型的「整项不计入」语义）。
    public static func entryTotals(parsed: MacroTotals, manualItems: [ManualFoodItem]) -> MacroTotals {
        var t = parsed
        for m in manualItems where !m.isExcluded {
            let macros = m.macros
            t.kcal += macros.kcal
            t.proteinG += macros.proteinG
            t.carbsG += macros.carbsG
            t.fatG += macros.fatG
        }
        t.proteinG = round1(t.proteinG)
        t.carbsG = round1(t.carbsG)
        t.fatG = round1(t.fatG)
        return t
    }

    /// 汇总一批记录（lifttime summarize :197-215）。tags 只聚合库命中项
    /// （nutrition.js:206-208 同口径——手估项无标签，不参与「无蔬果/junk」判定）。
    public static func summarize(_ entries: [DietEntry]) -> DietDayTotals {
        var t = DietDayTotals()
        for e in entries {
            t.totals.kcal += e.totals.kcal
            t.totals.proteinG += e.totals.proteinG
            t.totals.carbsG += e.totals.carbsG
            t.totals.fatG += e.totals.fatG
            t.itemCount += e.items.count
            t.unmatchedCount += e.unmatched.count
            var slice = t.byMeal[e.meal] ?? MealAggregate()
            slice.kcal += e.totals.kcal
            slice.count += 1
            t.byMeal[e.meal] = slice
            for item in e.items {
                for tag in item.tags { t.tagCounts[tag, default: 0] += 1 }
            }
        }
        t.totals.proteinG = round1(t.totals.proteinG)
        t.totals.carbsG = round1(t.totals.carbsG)
        t.totals.fatG = round1(t.totals.fatG)
        return t
    }

    /// 某日的记录（升序；lifttime entriesOfDay :217-220）
    public static func entriesOfDay(_ entries: [DietEntry], day: DayKey, calendar: DayCalendar) -> [DietEntry] {
        entries.filter { DayKey($0.date, calendar: calendar) == day }
            .sorted { $0.date < $1.date }
    }

    // MARK: 冻结物 B 签名（§2.1）

    /// 当日宏量汇总 + 目标 + 日建议（≤4 条）。workouts 同日训练记录——驱动
    /// ①练后 2.5h 窗口判定（nutrition.js:239-243）②训练日蛋白缺口文案
    /// ③训练日目标提升 targets(bodyweight, trained:)（nutrition.js:229）。
    public static func dailySummary(_ entries: [DietEntry], day: DayKey, workouts: [Workout],
                                    bodyweightKg: Double?, calendar: DayCalendar, now: Date) -> DietDaySummary {
        let dayEntries = entriesOfDay(entries, day: day, calendar: calendar)
        let s = summarize(dayEntries)
        let dayWorkouts = workouts
            .filter { DayKey($0.startedAt, calendar: calendar) == day }
            .sorted { $0.startedAt < $1.startedAt }
        let tg = targets(bodyweightKg: bodyweightKg, trainedToday: !dayWorkouts.isEmpty)

        guard !dayEntries.isEmpty else {
            return DietDaySummary(totals: s, targets: tg, advice: [noEntryDayAdvice])
        }

        var advice: [String] = []
        let hour = calendar.hour(of: now)
        let protein = s.totals.proteinG
        let kcal = s.totals.kcal

        // —— 训练联动（lifttime :234-252）——
        if let lastWo = dayWorkouts.last {
            let sinceEnd = now.timeIntervalSince(lastWo.endedAt)
            // 练后判定：meal == .postworkout 且 ts ≥ 训练开始，或训练结束
            // (-10min, +2.5h) 窗口内的非 preworkout 餐（nutrition.js:239-243）
            let postEaten = dayEntries.contains { e in
                (e.meal == .postworkout && e.date >= lastWo.startedAt)
                    || (e.date >= lastWo.endedAt - 10 * 60
                        && e.date <= lastWo.endedAt + 2.5 * 3600
                        && e.meal != .preworkout)
            }
            let labels = primaryLabels(of: lastWo)
            if postEaten {
                advice.append("练后餐已经吃上了 ✓ 蛋白质到位的话，今晚恢复会顺很多。")
            } else if sinceEnd < 2.5 * 3600 {
                let scope = labels.isEmpty ? "" : "（\(labels)）"
                advice.append("刚练完\(scope)，练后 2 小时是补充窗口：来一餐 30–40g 蛋白质 + 碳水，比如蛋白粉+香蕉，或鸡胸+米饭。")
            }
            if protein < Double(tg.proteinLo) {
                advice.append("今天练了\(labels.isEmpty ? "力量" : labels)，蛋白质目前约 \(Int(protein.rounded()))g，离目标 \(tg.proteinLo)–\(tg.proteinHi)g 还差不少，下一餐优先补蛋白。")
            }
        }

        // —— 目标进度（lifttime :254-271）——
        if dayWorkouts.isEmpty && protein < Double(tg.proteinLo) * 0.6 && hour >= 17 {
            advice.append("今天蛋白质偏少（约 \(Int(protein.rounded()))g / 目标 \(tg.proteinLo)g 起），晚餐加个蛋、鸡胸或一杯希腊酸奶。")
        }
        if kcal > 0 && kcal < Double(tg.kcal) * 0.5 && hour >= 19 {
            advice.append("到今天晚上热量还不到目标一半，除非在刻意减脂，否则建议正常吃晚餐——吃太少会影响恢复和训练状态。")
        }
        if kcal > Double(tg.kcal) * 1.35 {
            advice.append("今天热量约为目标的 \(Int((kcal / Double(tg.kcal) * 100).rounded()))%，如果近阶段目标是减脂，明天适当收一收；在增肌的话就安心吃。")
        }
        if (s.tagCounts[.veg] ?? 0) == 0 && (s.tagCounts[.fruit] ?? 0) == 0 && hour >= 15 {
            advice.append("今天还没吃蔬菜水果，加一份西兰花/番茄或一个苹果，微量营养素和纤维对恢复同样重要。")
        }
        // 晚 9 点后加餐：hour ≥ 21 且 meal == .snack（§3.4 口径）
        if dayEntries.contains(where: { calendar.hour(of: $0.date) >= 21 && $0.meal == .snack }) {
            advice.append("晚上 9 点后有加餐记录，偶尔无妨；如果经常睡前饿，可以把晚餐蛋白比例抬高一点。")
        }
        let junkCount = s.tagCounts[.junk] ?? 0
        if junkCount >= 3 {
            advice.append("今天高油糖食物有点多（\(junkCount) 项），明天让天然食物唱主角。")
        }
        if s.unmatchedCount > 0 {
            advice.append("有 \(s.unmatchedCount) 项食物没识别出来，热量为估算下限；可以改写成「2个鸡蛋」这种带数量的说法提高准确度。")
        }
        if advice.isEmpty { advice.append("今天吃得不错，结构均衡，继续保持。") }

        return DietDaySummary(totals: s, targets: tg, advice: Array(advice.prefix(4)))
    }

    /// 区间饮食总结（lifttime periodDiet :280-350）。双达标率口径并存（B1）：
    /// trainingDayHitRate（训练日口径，报告用）与 proteinHitDays/daysTracked
    /// （全记录日口径，budget 的 proteinHitRate 注入用）均由本函数产出。
    public static func periodDiet(_ entries: [DietEntry], workouts: [Workout], in span: DateSpan,
                                  bodyweightKg: Double?, calendar: DayCalendar) -> DietPeriodSummary {
        // 区间日键序列（含首尾；非法区间 → 空序列）。区间上限的把关归 report（≤366）。
        var keys: [DayKey] = []
        var seen = Set<String>()
        if span.isValid {
            var cursor: DayKey? = span.startDay
            while let k = cursor, seen.insert(k.rawValue).inserted {
                keys.append(k)
                cursor = (k == span.endDay) ? nil : calendar.addingDays(1, to: k)
            }
        }
        let keySet = Set(keys)

        var byDay: [DayKey: [DietEntry]] = [:]
        for e in entries {
            let k = DayKey(e.date, calendar: calendar)
            if keySet.contains(k) { byDay[k, default: []].append(e) }
        }

        let trackedDays = keys.filter { !(byDay[$0] ?? []).isEmpty }
        var daySums: [DayKey: DietDayTotals] = [:]
        var sumKcal = 0.0, sumProtein = 0.0, sumCarbs = 0.0, sumFat = 0.0
        for k in trackedDays {
            let s = summarize(byDay[k] ?? [])
            daySums[k] = s
            sumKcal += s.totals.kcal
            sumProtein += s.totals.proteinG
            sumCarbs += s.totals.carbsG
            sumFat += s.totals.fatG
        }
        let n = Double(max(trackedDays.count, 1))
        let avg = MacroTotals(kcal: (sumKcal / n).rounded(),
                              proteinG: round1(sumProtein / n),
                              carbsG: round1(sumCarbs / n),
                              fatG: round1(sumFat / n))

        let tg = targets(bodyweightKg: bodyweightKg, trainedToday: false)
        let proteinHitDays = trackedDays
            .filter { (daySums[$0]?.totals.proteinG ?? 0) >= Double(tg.proteinLo) }
            .count

        // 高频食物 Top5（count 降序、首见序破平——JS 稳定排序语义）
        var freq: [String: (count: Int, first: Int)] = [:]
        var order = 0
        for k in trackedDays {
            for e in byDay[k] ?? [] {
                for item in e.items {
                    if freq[item.name] == nil {
                        freq[item.name] = (0, order)
                        order += 1
                    }
                    freq[item.name]!.count += 1
                }
            }
        }
        let topFoods = Array(freq
            .map { FoodFrequency(name: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return freq[$0.name]!.first < freq[$1.name]!.first
            }
            .prefix(5))

        // 训练×饮食联动（B1：trainingDayHitRate = 训练日达标/训练日有记录数）
        let trainedKeys = Set(workouts
            .map { DayKey($0.startedAt, calendar: calendar) }
            .filter { keySet.contains($0) })
        let trackedTrained = trainedKeys.filter { !(byDay[$0] ?? []).isEmpty }
        let trainedHit = trackedTrained
            .filter { (daySums[$0]?.totals.proteinG ?? 0) >= Double(tg.proteinLo) }
            .count
        let link = TrainingDietLink(
            trainedDays: trainedKeys.count,
            trackedTrainedDays: trackedTrained.count,
            proteinHitOnTrainedDays: trainedHit,
            trainingDayHitRate: trackedTrained.isEmpty
                ? nil : Double(trainedHit) / Double(trackedTrained.count))

        let lateDays = trackedDays
            .filter { k in (byDay[k] ?? []).contains { calendar.hour(of: $0.date) >= 21 && $0.meal == .snack } }
            .count

        // 建议（lifttime :327-343；阶段建议不设 4 条上限——上限是日建议的口径）
        var advice: [String] = []
        if trackedDays.isEmpty {
            advice.append(noRecordPeriodAdvice)
        } else {
            let dayCount = keys.count
            if Double(proteinHitDays) / Double(trackedDays.count) < 0.5 {
                advice.append("近 \(dayCount) 天只有 \(proteinHitDays)/\(trackedDays.count) 天蛋白质达标。最简单的做法：每餐先确定蛋白来源（蛋/奶/肉/豆制品/蛋白粉），再配主食和蔬菜。")
            }
            if avg.kcal > Double(tg.kcal) * 1.2 {
                advice.append("日均热量约为目标的 \(Int((avg.kcal / Double(tg.kcal) * 100).rounded()))%，如果近期训练量在涨可以保留，否则主食和零食各收一档。")
            }
            if avg.kcal > 0 && avg.kcal < Double(tg.kcal) * 0.7 {
                advice.append("日均热量只有目标的 \(Int((avg.kcal / Double(tg.kcal) * 100).rounded()))%，长期吃太少训练状态会掉，留意是否有乏力、恢复变慢。")
            }
            if link.trainedDays >= 2 && link.trackedTrainedDays > 0 {
                let rate = Int((Double(link.proteinHitOnTrainedDays) / Double(link.trackedTrainedDays) * 100).rounded())
                if rate < 60 {
                    advice.append("训练日蛋白质达标率只有 \(rate)%——训练日的恢复质量直接取决于这一天的吃，练后餐别省。")
                } else {
                    advice.append("训练日蛋白质达标率 \(rate)%，饮食在支撑训练，节奏不错。")
                }
            }
            if lateDays >= 2 {
                advice.append("有 \(lateDays) 天在晚上 9 点后加餐，可以尝试把更多热量匀到白天。")
            }
            if advice.isEmpty { advice.append("饮食结构稳定，继续保持当前的节奏。") }
        }

        return DietPeriodSummary(daysTracked: trackedDays.count,
                                 avg: avg,
                                 proteinHitDays: proteinHitDays,
                                 topFoods: topFoods,
                                 lateDays: lateDays,
                                 trainingLink: link,
                                 targets: tg,
                                 advice: advice,
                                 trackedDayKeys: trackedDays)
    }

    /// 当日摄入快照（RecoveryContext.dayIntake 的组装来源；
    /// workout.js:331-335 dayIntakeToday 同口径）。无记录 → nil（通用建议分支）。
    /// hasPostMeal = meal == .postworkout 且 ts ≥ 训练开始（woStartedAt 未知时
    /// 对齐 lifttime `(lastWo.startedAt || 0)` 语义：任意练后餐即算）。
    public static func dayIntake(_ entries: [DietEntry], day: DayKey, woStartedAt: Date?, calendar: DayCalendar) -> DayIntake? {
        let dayEntries = entriesOfDay(entries, day: day, calendar: calendar)
        guard !dayEntries.isEmpty else { return nil }
        let s = summarize(dayEntries)
        let threshold = woStartedAt ?? .distantPast
        let hasPostMeal = dayEntries.contains { $0.meal == .postworkout && $0.date >= threshold }
        return DayIntake(proteinG: s.totals.proteinG,
                         kcal: s.totals.kcal,
                         itemCount: s.itemCount,
                         hasPostMeal: hasPostMeal)
    }

    // MARK: 餐次（lifttime MEALS / mealOf / diet.js guessMeal）

    /// mealOf 端口（lifttime nutrition.js:13）：原始 key 串 → 中文标签；
    /// 未知回退 MEALS[3]（加餐）。
    public static func mealLabel(forRawKey key: String) -> String {
        (MealSlot(rawValue: key) ?? .snack).label
    }

    /// 餐次推断（记餐预选，lifttime diet.js:374-387）：
    /// 练后 2.5h 内且未记过练后餐 → .postworkout；否则按时段
    ///（<10 早餐 / <14 午餐 / <20 晚餐 / 其余加餐）。
    public static func guessMeal(now: Date, calendar: DayCalendar,
                                 workouts: [Workout], entries: [DietEntry]) -> MealSlot {
        let today = DayKey(now, calendar: calendar)
        let todaysWorkouts = workouts.filter { DayKey($0.startedAt, calendar: calendar) == today }
        if let last = todaysWorkouts.max(by: { $0.startedAt < $1.startedAt }) {
            let postEaten = entries.contains { e in
                DayKey(e.date, calendar: calendar) == today
                    && e.meal == .postworkout
                    && e.date >= last.startedAt
            }
            if !postEaten && now.timeIntervalSince(last.endedAt) < 2.5 * 3600 {
                return .postworkout
            }
        }
        let h = calendar.hour(of: now)
        if h < 10 { return .breakfast }
        if h < 14 { return .lunch }
        if h < 20 { return .dinner }
        return .snack
    }

    /// 训练主练标签（lifttime ctx.workoutsToday[].primaryLabels 的 Swift 推导：
    /// 取分析快照 primaryMuscles 前两个；无快照 → 空，文案走无括号分支）。
    private static func primaryLabels(of workout: Workout) -> String {
        let muscles = (workout.analysis?.primaryMuscles ?? []).prefix(2)
        return muscles.map(muscleLabel).joined(separator: "、")
    }

    private static func muscleLabel(_ muscle: MuscleGroup) -> String {
        switch muscle {
        case .chest: return "胸"
        case .shoulder: return "肩"
        case .triceps: return "肱三头"
        case .back: return "背"
        case .biceps: return "肱二头"
        case .forearm: return "前臂"
        case .quad: return "股四头"
        case .hamstring: return "腘绳肌"
        case .glute: return "臀"
        case .calf: return "小腿"
        case .core: return "核心"
        case .full: return "全身"
        }
    }

    // MARK: 换算小工具

    /// 一位小数四舍五入（lifttime `Math.round(v * 10) / 10`）
    static func round1(_ v: Double) -> Double {
        (v * 10).rounded() / 10
    }

    /// per100g × 倍率 → 条目宏量（kcal 取整、p/c/f 一位小数；lifttime parseSegment :55-63）
    static func macros(per100g: Per100g, ratio: Double) -> MacroTotals {
        MacroTotals(kcal: (per100g.kcal * ratio).rounded(),
                    proteinG: round1(per100g.proteinG * ratio),
                    carbsG: round1(per100g.carbsG * ratio),
                    fatG: round1(per100g.fatG * ratio))
    }
}

// MARK: - MealSlot 标签（lifttime nutrition.js:5-12 MEALS，一字不差）

extension MealSlot {
    /// 餐次中文标签
    public var label: String {
        switch self {
        case .breakfast: return "早餐"
        case .lunch: return "午餐"
        case .dinner: return "晚餐"
        case .snack: return "加餐"
        case .preworkout: return "练前餐"
        case .postworkout: return "练后餐"
        }
    }
}

// MARK: - 条目宏量（模型层只存 per100g + grams，宏量按需换算）

extension FoodMatch {
    /// 这一条命中项的宏量（按入库克数换算；lifttime parseSegment 的取整口径）
    public var macros: MacroTotals {
        DietEngine.macros(per100g: per100g, ratio: grams / 100)
    }
}

extension ManualFoodItem {
    /// 这一条手估项的宏量（per100g × grams/100，同取整口径）
    public var macros: MacroTotals {
        DietEngine.macros(per100g: per100g, ratio: grams / 100)
    }
}
