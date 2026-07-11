//
//  Category.swift
//  GoodToNote
//
//  GN-002 — @Model Category. Single-level, emoji-iconed, expense/income kind,
//  user-customizable. Preset categories are only a first-launch seed.
//  Deleting a Category nullifies its transactions' category (never deletes ledger rows).
//

import Foundation
import SwiftData

@Model
final class Category {
    /// 稳定标识，便于外部接口（GN-004 URL scheme / App Intent）按 id 引用分类。
    var id: UUID
    var name: String
    /// emoji 图标字符串，如 "🍜"。
    var icon: String
    /// 支出 / 收入。存 rawValue，用 computed 包装。
    var kindRaw: String
    /// 列表展示顺序。
    var sortOrder: Int
    /// 是否为系统预置（用户自建为 false）。预置不建议删除，仅用于区分。
    var isPreset: Bool
    var createdAt: Date

    /// 反向关系：属于该分类的交易。删除分类时置空交易的 category，不删交易。
    @Relationship(deleteRule: .nullify, inverse: \Transaction.category)
    var transactions: [Transaction] = []

    var kind: CategoryKind {
        get { CategoryKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        kind: CategoryKind,
        sortOrder: Int = 0,
        isPreset: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.kindRaw = kind.rawValue
        self.sortOrder = sortOrder
        self.isPreset = isPreset
        self.createdAt = createdAt
    }
}
