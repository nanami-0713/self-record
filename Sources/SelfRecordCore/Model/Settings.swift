import Foundation

// MARK: - 设置（design.md §4）

/// AI 配置（第一版仅占位与净化校验，网络层后置，§9-5）。
/// apiKey 属 Keychain，永不落盘、永不进备份（lifttime 明文教训的修正）——
/// 本结构因此**没有** apiKey 字段。
public struct AIConfig: Codable, Sendable, Equatable {
    public var baseURLString: String?             // 净化要求 http(s)，BackupSanitizer 把关
    public var model: String = "glm-5.3-flash"
    public var effort: AIEffort = .max

    public init(baseURLString: String? = nil,
                model: String = "glm-5.3-flash",
                effort: AIEffort = .max) {
        self.baseURLString = baseURLString
        self.model = model
        self.effort = effort
    }

    enum CodingKeys: String, CodingKey {
        case baseURLString, model, effort
    }

    /// 宽松解码（§4 管线 2）：AI 配置净化后不丢（store.test 语义）——
    /// 单字段坏不抛错，字段归默认、整条保留。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURLString = (try? c.decodeIfPresent(String.self, forKey: .baseURLString)) ?? nil
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? "glm-5.3-flash"
        effort = (try? c.decodeIfPresent(AIEffort.self, forKey: .effort)) ?? .max
    }
}

/// lifttime 白名单三档（ai.js:6），无 medium。
public enum AIEffort: String, Codable, Sendable {
    case low, high, max

    /// 宽松解码：非法值 → `.max`（AIConfig.effort 非 Optional）。
    public init(from decoder: Decoder) throws {
        let container = try? decoder.singleValueContainer()
        self = (try? container?.decode(String.self)).flatMap(AIEffort.init(rawValue:)) ?? .max
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var unit: WeightUnit = .kilogram
    public var bodyweightKg: Double?              // 净化域 0–2000（越界归 nil）
    public var theme: ThemeMode = .system
    public var sleepGoalMinutes: Int = 480        // 净化域 240–720（越界收敛）
    public var weeklyBudgetYuan: Double?          // 净化域 0–1e7
    public var monthlyBudgetYuan: Double?
    public var aiConfig = AIConfig()

    public init(unit: WeightUnit = .kilogram,
                bodyweightKg: Double? = nil,
                theme: ThemeMode = .system,
                sleepGoalMinutes: Int = 480,
                weeklyBudgetYuan: Double? = nil,
                monthlyBudgetYuan: Double? = nil,
                aiConfig: AIConfig = AIConfig()) {
        self.unit = unit
        self.bodyweightKg = bodyweightKg
        self.theme = theme
        self.sleepGoalMinutes = sleepGoalMinutes
        self.weeklyBudgetYuan = weeklyBudgetYuan
        self.monthlyBudgetYuan = monthlyBudgetYuan
        self.aiConfig = aiConfig
    }

    enum CodingKeys: String, CodingKey {
        case unit, bodyweightKg, theme, sleepGoalMinutes
        case weeklyBudgetYuan, monthlyBudgetYuan, aiConfig
    }

    /// 宽松解码（§4 管线 2）：settings 是单值文档，一条字段类型错不能把整份
    /// 设置打成默认——坏字段归默认/nil，整条保留。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = (try? c.decodeIfPresent(WeightUnit.self, forKey: .unit)) ?? .kilogram
        bodyweightKg = (try? c.decodeIfPresent(Double.self, forKey: .bodyweightKg)) ?? nil
        theme = (try? c.decodeIfPresent(ThemeMode.self, forKey: .theme)) ?? .system
        sleepGoalMinutes = (try? c.decodeIfPresent(Int.self, forKey: .sleepGoalMinutes)) ?? 480
        weeklyBudgetYuan = (try? c.decodeIfPresent(Double.self, forKey: .weeklyBudgetYuan)) ?? nil
        monthlyBudgetYuan = (try? c.decodeIfPresent(Double.self, forKey: .monthlyBudgetYuan)) ?? nil
        aiConfig = (try? c.decodeIfPresent(AIConfig.self, forKey: .aiConfig)) ?? AIConfig()
    }
}
