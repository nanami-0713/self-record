import Foundation

// MARK: - 预算（design.md §4）

/// 开销分类（口径 = lifttime finance.js:5-13 EXP_CATS，健身饮食向）。
/// meals 仅由记餐 cost 派生的 auto 项使用，手动记账 UI 不提供该档；
/// 「外卖聚餐占比」「补剂占比」诊断依赖本口径（§3.5）。
public enum ExpenseCategory: String, Codable, Sendable, CaseIterable {
    case meals       // 记餐开销（auto 派生专用）
    case groceries   // 食材采购
    case takeout     // 外卖外食
    case social      // 聚餐
    case supplement  // 补剂
    case fitness     // 健身相关
    case other       // 其他
}

public struct Expense: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var date: Date
    public var amountYuan: Double                 // 净化域 0–1e7（越界收敛）
    public var category: ExpenseCategory?         // 非法归 nil
    public var note: String?                      // ≤2000
    public var isOutOfPlan: Bool                  // 计总账、不占周期额度

    public init(id: UUID = UUID(),
                date: Date,
                amountYuan: Double,
                category: ExpenseCategory? = nil,
                note: String? = nil,
                isOutOfPlan: Bool = false) {
        self.id = id
        self.date = date
        self.amountYuan = amountYuan
        self.category = category
        self.note = note
        self.isOutOfPlan = isOutOfPlan
    }

    enum CodingKeys: String, CodingKey {
        case id, date, amountYuan, category, note, isOutOfPlan
    }

    /// 宽松解码（§4 管线 2）：category 非法（如通用记账的 "shopping"）归 nil、
    /// isOutOfPlan 缺 key 归 false——整条保留。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        amountYuan = try c.decode(Double.self, forKey: .amountYuan)
        category = (try? c.decodeIfPresent(String.self, forKey: .category))
            .flatMap { raw in ExpenseCategory(rawValue: raw) }
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
        isOutOfPlan = (try? c.decodeIfPresent(Bool.self, forKey: .isOutOfPlan)) ?? false
    }
}
