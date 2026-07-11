//
//  RecurringRule.swift
//  GoodToNote
//
//  GN-002 — @Model RecurringRule. Fields only; the "settle due rules on app open"
//  generation logic is GN-006. Defined now so the schema is complete (no later migration).
//

import Foundation
import SwiftData

/// 周期性重复交易规则。GN-006 才实现"打开 app 时结算到期规则生成 Transaction"的逻辑。
/// 本任务只定义字段，使数据模型完整、不需后期迁移。
@Model
final class RecurringRule {
    var id: UUID
    var typeRaw: String
    var amount: Decimal
    var currencyCode: String
    var note: String
    var merchant: String?
    /// 重复周期。
    var periodRaw: String
    /// 下次应生成交易的日期。
    var nextDate: Date
    /// 上次生成日期（catch-up 结算用；尚未生成则为 nil）。
    var lastGeneratedDate: Date?
    /// 规则是否启用。
    var isActive: Bool
    var createdAt: Date

    /// 该规则使用的分类。删分类时置空。
    var category: Category?

    var type: TransactionType {
        get { TransactionType(rawValue: typeRaw) ?? .expense }
        set { typeRaw = newValue.rawValue }
    }
    var period: RecurrencePeriod {
        get { RecurrencePeriod(rawValue: periodRaw) ?? .monthly }
        set { periodRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        type: TransactionType,
        amount: Decimal,
        currencyCode: String = "SGD",
        note: String = "",
        merchant: String? = nil,
        period: RecurrencePeriod,
        nextDate: Date,
        lastGeneratedDate: Date? = nil,
        isActive: Bool = true,
        category: Category? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.typeRaw = type.rawValue
        self.amount = amount
        self.currencyCode = currencyCode
        self.note = note
        self.merchant = merchant
        self.periodRaw = period.rawValue
        self.nextDate = nextDate
        self.lastGeneratedDate = lastGeneratedDate
        self.isActive = isActive
        self.category = category
        self.createdAt = createdAt
    }
}
