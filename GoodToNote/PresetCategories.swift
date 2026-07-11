//
//  PresetCategories.swift
//  GoodToNote
//
//  GN-002 — Preset category seed data (16 expense + 2 income, with emoji) plus an
//  idempotent first-launch seeder. Seeds only when the Category table is empty so a
//  relaunch never duplicates presets (and a user-deleted preset is not re-inserted).
//

import Foundation
import SwiftData

enum PresetCategories {
    // GN-023: (localizationKey, icon)，顺序即 sortOrder。
    // key 复用 catalog 里的分类名键（= 中文字面量）；seedIfNeeded 落库时用 String(localized:)
    // 取「首启语言」的名字写入 SwiftData。分类名属用户数据 → 落库后定格、不随系统语言变、可手改。
    static let expense: [(String.LocalizationValue, String)] = [
        ("餐饮", "🍜"), ("交通", "🚌"), ("咖啡", "☕️"), ("线上购物", "🛒"),
        ("线下购物", "🏬"), ("游戏", "🎮"), ("app订阅", "📱"), ("住房", "🏠"),
        ("水电气", "💡"), ("通讯", "📡"), ("旅行", "✈️"), ("运动", "🏃"),
        ("医疗", "🏥"), ("学习", "📚"), ("礼物", "🎁"), ("其他", "📦"),
    ]
    static let income: [(String.LocalizationValue, String)] = [
        ("工资", "💰"), ("其他收入", "➕"),
    ]

    /// 幂等首启种入：仅当库中一个 Category 都没有时种入预置分类。
    /// 防重复种入（用户可能删过某些预置分类，不应被重新塞回）。
    /// GN-023 取舍：仅库空时跑 → 老库（已 321 笔）不重播，既有中文分类名保留；
    /// 新用户首启按当前语言落库（en 环境得 Food/Transport/…）。
    static func seedIfNeeded(_ context: ModelContext) {
        let existing = try? context.fetchCount(FetchDescriptor<Category>())
        guard (existing ?? 0) == 0 else { return }

        var order = 0
        for (name, icon) in expense {
            context.insert(Category(name: String(localized: name), icon: icon, kind: .expense,
                                    sortOrder: order, isPreset: true))
            order += 1
        }
        order = 0
        for (name, icon) in income {
            context.insert(Category(name: String(localized: name), icon: icon, kind: .income,
                                    sortOrder: order, isPreset: true))
            order += 1
        }
        try? context.save()
    }
}
