import Foundation

// MARK: - 时间分配（design.md §4）

public struct TimeCategory: Codable, Sendable, Identifiable, Equatable {
    public var id: String                         // ^[A-Za-z0-9_-]{1,40}（净化把关）
    public var label: String                      // ≤64 字符（净化截断）
    public var hue: ChartHue
    public var isArchived: Bool = false
    public var isFallback: Bool = false           // 兜底分类（默认「其他」）：恰好一个、不可删，
                                                  // 删除/归档其它分类时其历史块归它（§3.1）

    public init(id: String,
                label: String,
                hue: ChartHue,
                isArchived: Bool = false,
                isFallback: Bool = false) {
        self.id = id
        self.label = label
        self.hue = hue
        self.isArchived = isArchived
        self.isFallback = isFallback
    }

    enum CodingKeys: String, CodingKey {
        case id, label, hue, isArchived, isFallback
    }

    /// 宽松解码（§4 管线 2）：布尔缺 key 归 false；hue 非法归 `.neutral`。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        hue = (try? c.decodeIfPresent(ChartHue.self, forKey: .hue)) ?? .neutral
        isArchived = (try? c.decodeIfPresent(Bool.self, forKey: .isArchived)) ?? false
        isFallback = (try? c.decodeIfPresent(Bool.self, forKey: .isFallback)) ?? false
    }

    /// 默认 9 分类（§4.1 冻结表；清单 = lifttime store.js:15-25 DEFAULT_CATEGORIES，
    /// 语义不变；取色为 ChartHue 白名单档位）。「其他」是唯一 isFallback。
    public static let defaults: [TimeCategory] = [
        TimeCategory(id: "warmup", label: "热身激活", hue: .ochre),
        TimeCategory(id: "strength", label: "力量训练", hue: .rose),
        TimeCategory(id: "cardio", label: "有氧", hue: .rust),
        TimeCategory(id: "stretch", label: "拉伸放松", hue: .green),
        TimeCategory(id: "commute", label: "通勤往返", hue: .blue),
        TimeCategory(id: "meal", label: "备餐加餐", hue: .violet),
        TimeCategory(id: "supplement", label: "补剂", hue: .teal),
        TimeCategory(id: "shower", label: "洗漱整理", hue: .cyan),
        TimeCategory(id: "other", label: "其他", hue: .neutral, isFallback: true),
    ]
}

/// 单槽计时器：同一时刻只允许一个进行中事项（日常/睡眠互斥）。落盘，崩溃恢复用。
public struct ActiveTimer: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var kind: TimerKind

    public enum TimerKind: String, Codable, Sendable {
        case general, sleep

        /// 宽松解码：非法值 → `.general`。
        public init(from decoder: Decoder) throws {
            let container = try? decoder.singleValueContainer()
            self = (try? container?.decode(String.self)).flatMap(TimerKind.init(rawValue:)) ?? .general
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public init(startedAt: Date, kind: TimerKind) {
        self.startedAt = startedAt
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case startedAt, kind }

    /// 宽松解码（§3.1 测试清单「旧数据无 kind 归 general」——lifttime timer 向后兼容，
    /// store.test.mjs 语义）：kind 缺 key / 非法 → `.general`。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        kind = (try? c.decodeIfPresent(TimerKind.self, forKey: .kind)) ?? .general
    }
}

/// 已完成时间段（进行中不落 TimeBlock，走 ActiveTimer）。
public struct TimeBlock: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var start: Date
    public var end: Date                          // 净化要求 end > start（结构性非法剔除）
    public var categoryID: String                 // 必须能在分类表中解析（§3.1 引用完整性）
    public var note: String?                      // ≤2000（净化截断）

    public init(id: UUID = UUID(),
                start: Date,
                end: Date,
                categoryID: String,
                note: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.categoryID = categoryID
        self.note = note
    }
}
