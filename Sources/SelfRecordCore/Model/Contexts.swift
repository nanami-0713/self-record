import Foundation

// MARK: - 跨域注入上下文（design.md §4 末「跨域注入上下文」；骨架冻结物，签名见 §2）

/// workout 分析引擎的恢复建议上下文
/// （lifttime workout.js:331-343 dayIntakeToday + fitnessTimeToday；
///   analysis.js:190-193/:211/:263 消费；nil 语义走通用建议分支）
public struct RecoveryContext: Codable, Sendable, Equatable {
    public var bodyweightKg: Double?
    public var dayIntake: DayIntake?
    public var fitnessTimeMinutes: Double?

    public init(bodyweightKg: Double? = nil,
                dayIntake: DayIntake? = nil,
                fitnessTimeMinutes: Double? = nil) {
        self.bodyweightKg = bodyweightKg
        self.dayIntake = dayIntake
        self.fitnessTimeMinutes = fitnessTimeMinutes
    }
}

public struct DayIntake: Codable, Sendable, Equatable {
    public var proteinG: Double
    public var kcal: Double
    public var itemCount: Int
    public var hasPostMeal: Bool                  // meal == .postworkout 且 ts ≥ 训练开始（§3.4 练后判定）

    public init(proteinG: Double,
                kcal: Double,
                itemCount: Int,
                hasPostMeal: Bool) {
        self.proteinG = proteinG
        self.kcal = kcal
        self.itemCount = itemCount
        self.hasPostMeal = hasPostMeal
    }
}
