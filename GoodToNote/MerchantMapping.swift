//
//  MerchantMapping.swift
//  GoodToNote
//
//  GN-002 — @Model MerchantMapping. Fields only; the matching/learning logic is GN-005.
//  Stores a merchant → default category memory the entry flow will read and update.
//

import Foundation
import SwiftData

/// 商户 → 分类 的记忆表。GN-005 的"到达即确认"会查它预填分类、命中后更新。
/// 本任务只定义字段。
@Model
final class MerchantMapping {
    var id: UUID
    /// 商户标识（来自短信的商户名，规范化由 GN-005 处理；此处原样存）。
    var merchant: String
    var hitCount: Int
    var lastUsedAt: Date?
    var createdAt: Date

    /// 该商户默认归入的分类。删分类时置空。
    var category: Category?

    init(
        id: UUID = UUID(),
        merchant: String,
        category: Category? = nil,
        hitCount: Int = 0,
        lastUsedAt: Date? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.merchant = merchant
        self.category = category
        self.hitCount = hitCount
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
    }
}
