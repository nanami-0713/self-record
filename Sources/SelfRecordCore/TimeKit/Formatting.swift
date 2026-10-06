import Foundation

/// 展示层格式化与单位换算（design.md §3.0 TimeKit 职责：时长/宏量格式化、kg↔lb）。
///
/// 约定：内部存储一律 kg、金额一律元、时长字段名带单位——本类型只做「值 → 展示串」。
/// 格式细节为骨架裁决（中文 UI、整数展示为主）；需要调整走修复工程师，模块不私改。
public enum Formatting {
    // MARK: - 时长

    /// 分钟数 → 中文人读时长：`90` → "1 小时 30 分"；`45.5` → "46 分"；`0` → "0 分"。
    public static func duration(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 60 { return "\(total) 分" }
        return "\(total / 60) 小时 \(total % 60) 分"
    }

    /// 分钟数 → 紧凑小时表示：`480` → "8.0 h"（统计卡场景）。
    public static func hours(minutes: Double) -> String {
        String(format: "%.1f h", minutes / 60)
    }

    // MARK: - 宏量

    /// 克数 → 整数展示：`86.43` → "86 g"。
    public static func grams(_ value: Double) -> String {
        "\(Int(value.rounded())) g"
    }

    /// 千卡 → 整数展示：`1830.2` → "1830 kcal"。
    public static func kcal(_ value: Double) -> String {
        "\(Int(value.rounded())) kcal"
    }

    /// 金额（元）→ 两位小数以内：`23` → "¥23"；`23.5` → "¥23.5"。
    public static func yuan(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "¥\(Int(rounded))"
        }
        return String(format: "¥%.1f", rounded)
    }

    // MARK: - 重量换算（内部恒 kg，换算只在展示层，design.md §4 WeightUnit 注释）

    /// 国际磅精确定义 1 lb = 0.45359237 kg。
    private static let poundsPerKilogram = 1 / 0.45359237

    public static func kgToLb(_ kg: Double) -> Double {
        kg * poundsPerKilogram
    }

    public static func lbToKg(_ lb: Double) -> Double {
        lb * 0.45359237
    }

    /// 按用户显示单位格式化：`72.5 kg` / `159.8 lb`。
    public static func weight(_ kg: Double, unit: WeightUnit) -> String {
        switch unit {
        case .kilogram: return "\(String(format: "%.1f", kg)) kg"
        case .pound: return "\(String(format: "%.1f", kgToLb(kg))) lb"
        }
    }
}
