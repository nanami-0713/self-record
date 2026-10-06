import SelfRecordCore
import SwiftUI

// MARK: - 训练分组展示格式化（design.md §6 训练三页共用）
//
// 只做「值 → 展示串 / 徽标 tone」的展示层映射；一切计算（容量、e1RM、DOMS 计分、
// 分析文案）都在 SelfRecordCore 的 WorkoutEngine，本类型不重复实现任何口径。
//
// 重量展示口径对齐 Core 内 WorkoutEngine.fmtLoad（0.1 精度、去尾 0；该函数为
// Core internal，UI 侧按同一规则展示；换算到 lb 走设置的单位，用 Formatting.weight）。

enum WorkoutDisplay {

    /// kg 数值 → 紧凑串：`5432` / `62.5`（不带单位，配合 SRStatCard suffix 用）。
    static func kg(_ value: Double) -> String {
        let v = (value * 10).rounded() / 10
        return v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }

    /// 一组的摘要行：`62.5kg × 8` / `自重 × 12`（0 = 自重，Model 注释口径）。
    static func setSummary(_ set: WorkoutSet) -> String {
        set.weightKg > 0 ? "\(kg(set.weightKg))kg × \(set.reps)" : "自重 × \(set.reps)"
    }

    /// 流逝时长 `mm:ss`（≥1h 出 `h:mm:ss`），进行中训练头部/恢复条用。
    static func elapsed(_ from: Date, now: Date) -> String {
        let t = Swift.max(0, Int(now.timeIntervalSince(from).rounded()))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    // MARK: 徽标文案与 tone（语气档 = design.md §3.3 的四档口径）

    static func domsText(_ level: DOMSLevel) -> String {
        switch level {
        case .severe: return "DOMS 强烈"
        case .noticeable: return "DOMS 明显"
        case .moderate: return "DOMS 中度"
        case .mild: return "DOMS 轻微"
        }
    }

    static func domsTone(_ level: DOMSLevel) -> SRBadge.Tone {
        switch level {
        case .severe: return .danger
        case .noticeable: return .warning
        case .moderate: return .info
        case .mild: return .neutral
        }
    }

    static func intensityText(_ band: IntensityBand) -> String {
        switch band {
        case .high: return "高强度"
        case .moderatelyHigh: return "中高强度"
        case .moderate: return "中等强度"
        case .light: return "轻负荷"
        }
    }

    static func intensityTone(_ band: IntensityBand) -> SRBadge.Tone {
        switch band {
        case .high: return .warning
        case .moderatelyHigh: return .info
        case .moderate: return .neutral
        case .light: return .neutral
        }
    }
}
