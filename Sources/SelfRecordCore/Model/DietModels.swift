import Foundation

// MARK: - 饮食（design.md §4）

/// 餐次六档（口径 = lifttime nutrition.js:5-12 MEALS，按训练关系而非纯时段）：
/// snack 为通用加餐；「晚 9 点后加餐」判定 = hour≥21 且 meal == .snack。
/// guessMeal 依时段推断，练后 2.5h 窗口预选 .postworkout；未知餐次回退 .snack。
public enum MealSlot: String, Codable, Sendable {
    case breakfast, lunch, dinner, snack, preworkout, postworkout

    /// 宽松解码（§4 管线 2）：非法值 → `.snack`——对齐 `mealOf` 未知回退 MEALS[3]
    /// 的读取语义；实测语义依据 §13 v3（`meal:"brunch"` 场景 2/3 好条目存活）。
    public init(from decoder: Decoder) throws {
        let container = try? decoder.singleValueContainer()
        self = (try? container?.decode(String.self)).flatMap(MealSlot.init(rawValue:)) ?? .snack
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 食物标签（lifttime foods.js:2-3，10 档）。挂库命中项；「无蔬果」「junk≥3」
/// 等日建议靠它聚合（nutrition.js:206-208，只算 items，不含手估项）。
public enum FoodTag: String, Codable, Sendable {
    case protein, carb, veg, fruit, dairy, fat, junk, drink, supp, custom
}

/// 每 100g 营养 + 常用份（自学习库存的就是这个形状）
public struct Per100g: Codable, Sendable, Equatable {
    public var kcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var portionGrams: Double?              // 常用份克数（如「碗」=200g）
    public var portionUnit: String?               // 份单位名（个/碗/杯…）

    public init(kcal: Double,
                proteinG: Double,
                carbsG: Double,
                fatG: Double,
                portionGrams: Double? = nil,
                portionUnit: String? = nil) {
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.portionGrams = portionGrams
        self.portionUnit = portionUnit
    }
}

/// 食物库命中项（内置库或自学习库）。tags 来自库条目（lifttime guessFor 无标签，
/// 手估项不参与 tags 聚合——口径见 §3.4）。
public struct FoodMatch: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var grams: Double
    public var per100g: Per100g
    public var tags: [FoodTag]

    public init(name: String, grams: Double, per100g: Per100g, tags: [FoodTag] = []) {
        self.name = name
        self.grams = grams
        self.per100g = per100g
        self.tags = tags
    }
}

/// 手估项：三层兜底第②层的预填，可改、可整项不计入
public struct ManualFoodItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var grams: Double
    public var per100g: Per100g
    public var isExcluded: Bool                   // true = 整项不计入
    public var guessCategory: String?             // 8 大类猜测的类别名

    public init(id: UUID = UUID(),
                name: String,
                grams: Double,
                per100g: Per100g,
                isExcluded: Bool = false,
                guessCategory: String? = nil) {
        self.id = id
        self.name = name
        self.grams = grams
        self.per100g = per100g
        self.isExcluded = isExcluded
        self.guessCategory = guessCategory
    }

    enum CodingKeys: String, CodingKey {
        case id, name, grams, per100g, isExcluded, guessCategory
    }

    /// 宽松解码（§4 管线 2）：isExcluded 缺 key 归 false（旧数据兼容）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        grams = try c.decode(Double.self, forKey: .grams)
        per100g = try c.decode(Per100g.self, forKey: .per100g)
        isExcluded = (try? c.decodeIfPresent(Bool.self, forKey: .isExcluded)) ?? false
        guessCategory = (try? c.decodeIfPresent(String.self, forKey: .guessCategory)) ?? nil
    }
}

public struct MacroTotals: Codable, Sendable, Equatable {
    public var kcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double

    public init(kcal: Double = 0, proteinG: Double = 0, carbsG: Double = 0, fatG: Double = 0) {
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
    }
}

public struct DietEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var date: Date
    public var meal: MealSlot
    public var rawText: String                    // ≤2000（净化截断）
    public var items: [FoodMatch]                 // 库命中
    public var manualItems: [ManualFoodItem]      // 手估
    public var unmatched: [String]                // 未识别，不计入
    public var totals: MacroTotals                // 保存时缓存（items+未排除 manualItems）
    public var costYuan: Double?                  // 联动预算：>0 派生 auto 开销

    public init(id: UUID = UUID(),
                date: Date,
                meal: MealSlot,
                rawText: String,
                items: [FoodMatch] = [],
                manualItems: [ManualFoodItem] = [],
                unmatched: [String] = [],
                totals: MacroTotals = MacroTotals(),
                costYuan: Double? = nil) {
        self.id = id
        self.date = date
        self.meal = meal
        self.rawText = rawText
        self.items = items
        self.manualItems = manualItems
        self.unmatched = unmatched
        self.totals = totals
        self.costYuan = costYuan
    }

    enum CodingKeys: String, CodingKey {
        case id, date, meal, rawText, items, manualItems, unmatched, totals, costYuan
    }

    /// 宽松解码（§4 管线 2）：meal 非法由 MealSlot 宽松 init 归 `.snack`；
    /// costYuan 类型错归 nil；数组缺 key/类型错归空（骨架裁决：记录内嵌数组的
    /// 元素级递归宽容不展开，坏数组整组归空，totals 缓存字段仍在，损失可控）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        meal = (try? c.decodeIfPresent(MealSlot.self, forKey: .meal)) ?? .snack
        rawText = try c.decode(String.self, forKey: .rawText)
        items = (try? c.decodeIfPresent([FoodMatch].self, forKey: .items)) ?? []
        manualItems = (try? c.decodeIfPresent([ManualFoodItem].self, forKey: .manualItems)) ?? []
        unmatched = (try? c.decodeIfPresent([String].self, forKey: .unmatched)) ?? []
        totals = (try? c.decodeIfPresent(MacroTotals.self, forKey: .totals)) ?? MacroTotals()
        costYuan = (try? c.decodeIfPresent(Double.self, forKey: .costYuan)) ?? nil
    }
}

/// 自学习食物库条目（每 100g 归一 + 使用计数；learnFood 产物默认打 .custom 标签）
public struct CustomFood: Codable, Sendable, Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    public var per100g: Per100g
    public var tags: [FoodTag] = [.custom]
    public var useCount: Int

    public init(name: String,
                per100g: Per100g,
                tags: [FoodTag] = [.custom],
                useCount: Int = 0) {
        self.name = name
        self.per100g = per100g
        self.tags = tags
        self.useCount = useCount
    }

    enum CodingKeys: String, CodingKey { case name, per100g, tags, useCount }

    /// 宽松解码（§4 管线 2）：tags/useCount 缺 key 归默认（learnFood 旧数据兼容）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        per100g = try c.decode(Per100g.self, forKey: .per100g)
        tags = (try? c.decodeIfPresent([FoodTag].self, forKey: .tags)) ?? [.custom]
        useCount = (try? c.decodeIfPresent(Int.self, forKey: .useCount)) ?? 0
    }
}
