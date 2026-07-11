//
//  AppSettings.swift
//  GoodToNote
//
//  GN-024 — Global singleton settings. v1 only stores the base currency code; more
//  can be added later. Read via current(in:) which is fetch-or-create so BOTH the
//  existing 321-txn store (no AppSettings row yet) and a fresh store always get a
//  value back (default "SGD").
//
//  Migration safety: AppSettings is a NEW relation-free @Model entity → purely
//  additive lightweight migration (same shape as GN-021's planned SmsTemplate);
//  the 321 existing transactions are untouched. Restoring an OLD backup whose store
//  has no AppSettings entity is fine: current(in:) finds none → creates the default.
//

import Foundation
import SwiftData

@Model
final class AppSettings {
    /// ISO 4217 code of the configured base currency. Default "SGD" (the original
    /// hardcoded base). Changing it triggers BaseCurrencyService.changeBase, which
    /// recomputes every transaction's base amount at CURRENT rates.
    var baseCurrencyCode: String
    var createdAt: Date

    init(baseCurrencyCode: String = "SGD", createdAt: Date = .now) {
        self.baseCurrencyCode = baseCurrencyCode
        self.createdAt = createdAt
    }

    /// Fetch the single settings row; create one (default SGD) if absent, persisting it.
    /// Guarantees old store / new store / restored-old-backup all get a value.
    static func current(in context: ModelContext) -> AppSettings {
        if let existing = try? context.fetch(FetchDescriptor<AppSettings>()).first {
            return existing
        }
        let s = AppSettings()
        context.insert(s)
        try? context.save()
        return s
    }
}
