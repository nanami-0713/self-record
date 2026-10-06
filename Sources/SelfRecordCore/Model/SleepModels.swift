import Foundation

// MARK: - 睡眠（design.md §4）

public struct SleepSession: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var start: Date
    public var end: Date                          // 净化：end > start 且 ≤24h（结构性非法剔除）
    public var feel: Int?                         // 1–5，可空=未填（越界归 nil）
    public var wakeCount: Int?                    // 0–3（越界归 nil）
    public var latency: SleepLatency?             // 入睡快慢，可空（非法归 nil）
    public var note: String?                      // ≤2000
    public var dayOverride: DayKey?               // 手动归属，优先于 -4h 规则（非法归 nil）

    public init(id: UUID = UUID(),
                start: Date,
                end: Date,
                feel: Int? = nil,
                wakeCount: Int? = nil,
                latency: SleepLatency? = nil,
                note: String? = nil,
                dayOverride: DayKey? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.feel = feel
        self.wakeCount = wakeCount
        self.latency = latency
        self.note = note
        self.dayOverride = dayOverride
    }

    enum CodingKeys: String, CodingKey {
        case id, start, end, feel, wakeCount, latency, note, dayOverride
    }

    /// 字段级宽容解码（§4 管线 2 的核心落地，验收 = store.test.mjs
    /// 「非法睡眠会话剔除后好条目存活、越界字段归 nil」语义）：
    /// - 必填（id/start/end）解码失败 → 抛错，由**元素级**管线丢整条（结构性）；
    /// - 可恢复字段（feel/wakeCount/latency/note/dayOverride）类型错或格式非法
    ///   → 归 nil，**保留整条**（lifttime store.js:137 dayOverride 同语义）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        feel = (try? c.decodeIfPresent(Int.self, forKey: .feel)) ?? nil
        wakeCount = (try? c.decodeIfPresent(Int.self, forKey: .wakeCount)) ?? nil
        latency = (try? c.decodeIfPresent(String.self, forKey: .latency))
            .flatMap { raw in SleepLatency(rawValue: raw) }
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
        // 构造侧校验入口把关：格式非法的 dayOverride（如 "2026/09/06"）直接归 nil
        dayOverride = (try? c.decodeIfPresent(String.self, forKey: .dayOverride))
            .flatMap { raw in DayKey(rawValue: raw) }
    }
}

public enum SleepLatency: String, Codable, Sendable {
    case fast, ok, slow
}
