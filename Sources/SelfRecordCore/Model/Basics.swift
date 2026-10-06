import Foundation

// MARK: - 枚举与基础值（design.md §4）

/// 显示单位；内部存储一律 kg（换算只在展示层，见 TimeKit/Formatting.swift）。
public enum WeightUnit: String, Codable, Sendable {
    case kilogram, pound

    /// 宽松解码（§4 管线 2）：缺 key 由字段层默认，非法值 → `.kilogram`。
    public init(from decoder: Decoder) throws {
        let container = try? decoder.singleValueContainer()
        self = (try? container?.decode(String.self)).flatMap(WeightUnit.init(rawValue:)) ?? .kilogram
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ThemeMode: String, Codable, Sendable {
    case system, light, dark

    /// 宽松解码：非法值 → `.system`。
    public init(from decoder: Decoder) throws {
        let container = try? decoder.singleValueContainer()
        self = (try? container?.decode(String.self)).flatMap(ThemeMode.init(rawValue:)) ?? .system
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 图表八色（Ely HUE_NAMES）+ 1 个中性档：时间分类取色用——天然白名单，
/// 等价 lifttime safeColor 防注入的思想（不允许任意色值进数据）。
/// neutral 非 Ely 源色，取 fg_muted 同值（#605D5A / #AFADAB），供「其他」这类
/// 无倾向分类使用（9 个默认分类对 8 hue 的补位）。
public enum ChartHue: String, Codable, Sendable, CaseIterable {
    case blue, teal, ochre, rose, violet, green, rust, cyan, neutral

    /// 宽松解码：非法值 → `.neutral`（兜底档，§4.1「neutral 为兜底分类专属」）。
    public init(from decoder: Decoder) throws {
        let container = try? decoder.singleValueContainer()
        self = (try? container?.decode(String.self)).flatMap(ChartHue.init(rawValue:)) ?? .neutral
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
