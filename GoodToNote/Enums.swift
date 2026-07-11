//
//  Enums.swift
//  GoodToNote
//
//  GN-002 — String-raw Codable enums backing the data model.
//  Purpose: stable, migration-friendly enums for transaction/category kind and
//  recurrence period. Stored as rawValue Strings on the @Model types.
//

import Foundation

/// 交易类型：支出 / 收入。
enum TransactionType: String, Codable, CaseIterable, Identifiable {
    case expense
    case income
    var id: String { rawValue }
}

/// 分类种类：决定该分类出现在支出还是收入选择列表。
enum CategoryKind: String, Codable, CaseIterable, Identifiable {
    case expense
    case income
    var id: String { rawValue }
}

/// 周期性规则的重复周期（GN-006 才会用它生成交易；此处仅定义）。
enum RecurrencePeriod: String, Codable, CaseIterable, Identifiable {
    case daily
    case weekly
    case monthly
    case yearly
    var id: String { rawValue }
}
