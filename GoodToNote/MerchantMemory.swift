//
//  MerchantMemory.swift
//  GoodToNote
//
//  GN-005 — Merchant → category memory over the existing MerchantMapping @Model.
//  Key is the RAW merchant string (merchantRaw, e.g. "fp*Food Panda") so lookups are
//  stable across the display-name prefix-stripping. Used two ways:
//    • suggestedCategory: when a UOB draft is ingested, prefill the suggested category.
//    • remember: ONLY on user-accept, upsert merchant→final category (hitCount++, lastUsedAt).
//  Reject does NOT call remember (per GN-005 ⑤).
//

import Foundation
import SwiftData

enum MerchantMemory {
    /// Look up the remembered category for a raw merchant string. nil if unseen.
    static func suggestedCategory(forRaw merchant: String, in ctx: ModelContext) -> Category? {
        mapping(forRaw: merchant, in: ctx)?.category
    }

    /// Upsert merchant→category on accept: create if new, else update category +
    /// bump hitCount + refresh lastUsedAt. Caller is responsible for ctx.save().
    static func remember(rawMerchant: String, category: Category?, in ctx: ModelContext) {
        let key = rawMerchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if let existing = mapping(forRaw: key, in: ctx) {
            existing.category = category
            existing.hitCount += 1
            existing.lastUsedAt = .now
        } else {
            let m = MerchantMapping(
                merchant: key,
                category: category,
                hitCount: 1,
                lastUsedAt: .now
            )
            ctx.insert(m)
        }
    }

    /// Find the MerchantMapping whose merchant == the raw key (exact match).
    private static func mapping(forRaw merchant: String, in ctx: ModelContext) -> MerchantMapping? {
        let key = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        // #Predicate over a captured String compares fine; fall back to in-memory filter
        // if the fetch ever returns broadly (mapping table is tiny).
        let descriptor = FetchDescriptor<MerchantMapping>(
            predicate: #Predicate { $0.merchant == key }
        )
        return (try? ctx.fetch(descriptor))?.first
    }
}
