//
//  SmsTemplate.swift
//  GoodToNote
//
//  GN-025 (Phase A) — Example-driven SMS recognition template. Replaces the hardcoded
//  UOBMessageParser: a user pastes ONE of their bank's transaction SMS, confirms the
//  highlighted amount/currency/merchant spans, and the engine compiles that single
//  example into ONE NSRegularExpression (literal anchors + typed slots). Users never
//  see regex. Runtime matches templates first-match by ascending orderIndex.
//
//  Migration safety (per GN-021 §5 / mirrors GN-024 AppSettings): SmsTemplate is a NEW
//  relation-free @Model entity → purely ADDITIVE lightweight migration. It holds NO
//  cross-entity relationship (defaultCategoryID is a UUID scalar, NOT a Category?
//  relation) so it cannot touch Category's inverse-relationship definition. The existing
//  321-transaction store opens unchanged and simply gains an empty SmsTemplate table.
//  Restoring an OLD backup whose store has no SmsTemplate entity is fine: the table is
//  empty (built-in UOB preset re-seeds on first launch — Phase B).
//

import Foundation
import SwiftData

/// A single-example-derived SMS recognition template. Runtime tries templates
/// first-match in ascending `orderIndex`.
@Model
final class SmsTemplate {
    var id: UUID
    /// Display / management name, e.g. "UOB 消费".
    var name: String
    /// First-match try order (smaller first); user can drag-reorder.
    var orderIndex: Int
    /// Disabled (rather than deleted) templates stay around for debugging.
    var isEnabled: Bool = true

    // —— Compiled matching rule (NOT shown to the user) ——
    /// The NSRegularExpression pattern compiled from anchors + slots.
    var compiledPattern: String
    /// JSON array mapping capture-group order → slot role, e.g. ["currency","amount","merchant"].
    var slotMapJSON: String

    // —— Per-template output settings ——
    /// "expense" / "income" (mirrors TransactionType raw value).
    var transactionTypeRaw: String
    /// Optional; the fallback pre-selected category when MerchantMemory misses on a
    /// landed draft. Stored as a UUID SCALAR (no relation) so a deleted category just
    /// leaves a harmless dangling id (same tolerance as MerchantMemory).
    var defaultCategoryID: UUID?
    /// Used when the SMS carries no currency token, e.g. "SGD".
    var currencyFallback: String
    /// = the longest literal anchor; exported for GN-026 ("信息包含" shortcut filter).
    var suggestedTriggerKeyword: String?
    /// Built-in UOB preset = true (user can edit / disable but the source is marked).
    var isBuiltInPreset: Bool = false

    /// GN-039: which input path this template recognizes — "sms" (default) or "email". The
    /// runtime tries SMS templates only for incoming SMS (IngestUOBMessageIntent fetches
    /// inputKind=="sms") and email templates only for incoming email (IngestEmailIntent fetches
    /// inputKind=="email"), so the two paths never cross-contaminate. DEFAULT "sms" → every
    /// template created before GN-039 migrates to "sms" (they ARE SMS templates), so this is a
    /// purely ADDITIVE lightweight migration (a scalar String with a default value, no relation
    /// — same class as `exampleText` GN-032 / `source` GN-036): the existing store opens unchanged
    /// and old rows get "sms". Email templates store the PREPROCESSED key segment (not the full
    /// HTML) in exampleText, because EmailPreprocessor.process runs identically at build time and
    /// at runtime — the rule's literal anchors must be built on the same stable plain text the
    /// matcher will see.
    var inputKind: String = "sms"

    var createdAt: Date

    /// GN-032: 建模版时粘贴的原始短信原文(用于在模版页回显"当时怎么设的",高亮各槽位)。
    /// 带默认值的新属性 → SwiftData 加性轻量迁移;老模版(GN-032 前建)此字段为 ""(页内显
    /// fallback 提示)。高亮 span 不另存,由 metadata sheet 对此原文跑 compiledPattern
    /// (SmsTemplateMatcher.matchSpans)恢复。This is the FIRST field added to SmsTemplate since
    /// GN-025; it is a scalar String with a default value and NO relation → purely additive,
    /// so the existing store (321 txns + existing templates) opens unchanged and old rows get "".
    var exampleText: String = ""

    init(id: UUID = UUID(), name: String, orderIndex: Int, isEnabled: Bool = true,
         compiledPattern: String, slotMapJSON: String, transactionTypeRaw: String = "expense",
         defaultCategoryID: UUID? = nil, currencyFallback: String = "SGD",
         suggestedTriggerKeyword: String? = nil, isBuiltInPreset: Bool = false,
         exampleText: String = "", inputKind: String = "sms", createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.orderIndex = orderIndex
        self.isEnabled = isEnabled
        self.compiledPattern = compiledPattern
        self.slotMapJSON = slotMapJSON
        self.transactionTypeRaw = transactionTypeRaw
        self.defaultCategoryID = defaultCategoryID
        self.currencyFallback = currencyFallback
        self.suggestedTriggerKeyword = suggestedTriggerKeyword
        self.isBuiltInPreset = isBuiltInPreset
        self.exampleText = exampleText
        self.inputKind = inputKind
        self.createdAt = createdAt
    }
}
