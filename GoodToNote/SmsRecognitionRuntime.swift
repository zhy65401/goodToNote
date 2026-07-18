//
//  SmsRecognitionRuntime.swift
//  GoodToNote
//
//  GN-052 — THE single recognition path. Everything that asks "does a template recognize this
//  text, and what does it extract?" goes through here.
//
//  ★ WHY THIS FILE EXISTS (the GN-052 root cause): the app had TWO recognition engines. Building
//  a template previewed its result with the `SmsExtractor.extract` HEURISTIC, while the runtime
//  actually matched with the compiled REGEX (`SmsTemplateMatcher.matchOne`). The two could — and
//  did — disagree, so a template could look perfect in the editor and never fire on the same
//  SMS afterwards. Every new matching/validation/test surface added by GN-052 (the post-save
//  inbox rescan, the in-app "test with my own text" entry, the migration self-check) is required
//  to reuse `SmsTemplateMatcher.matchDetailed` + `SmsTemplateMatcher.decodeSlotMap`, and they all
//  do it by calling into this file. Do NOT add a second judgement anywhere.
//
//  Contents:
//    • scan(_:templates:)          — try templates in order, first hit with a usable amount wins,
//                                    and record WHY each loser lost (GN-052 Task 3 diagnostics).
//    • resolveDraft(...)/apply(...)— turn a match into the persisted draft fields, ONCE, shared by
//                                    the ingest Intents and the inbox rescan (no second parser).
//    • rescanUnrecognizedDrafts(...) — GN-052 Task 2: after a template is saved, re-run it over
//                                    the unrecognized drafts already sitting in the inbox.
//

import Foundation
import SwiftData

enum SmsRecognitionRuntime {

    // MARK: - Scan (which template wins, and why the others lost)

    /// Why a template did not produce a draft for this text.
    enum SkipReason: Equatable {
        /// The regex itself said no — with the distinguishable reason (GN-052 Task 3).
        case failed(MatchFailure)
        /// The regex matched, but no usable amount came out. The runtime deliberately treats
        /// this as "not recognized" rather than writing a zero-amount "recognized" draft.
        case matchedButNoAmount
    }

    struct Attempt {
        let template: SmsTemplate
        let reason: SkipReason
    }

    struct ScanResult {
        /// The winning template and its extracted fields, if any.
        var hitTemplate: SmsTemplate?
        var hitFields: MatchedFields?
        /// Every template tried before/without a win, with the reason it lost. (Templates after
        /// the winner are not tried at all — first-match semantics — so they don't appear.)
        var attempts: [Attempt]

        var matched: Bool { hitTemplate != nil }
    }

    /// Fetch the templates the runtime would try for `kind` ("sms" / "email"): enabled only,
    /// ascending orderIndex. Same predicate the ingest Intents have always used.
    @MainActor
    static func enabledTemplates(kind: String, in ctx: ModelContext) -> [SmsTemplate] {
        var d = FetchDescriptor<SmsTemplate>(
            predicate: #Predicate { $0.isEnabled == true && $0.inputKind == kind },
            sortBy: [SortDescriptor(\.orderIndex, order: .forward)]
        )
        d.propertiesToFetch = []   // fetch full objects (small table)
        return (try? ctx.fetch(d)) ?? []
    }

    /// Try each template in order; the FIRST one that matches AND yields a usable amount wins.
    /// Identical semantics to the loop the Intents used before GN-052 — it just also records the
    /// losers' reasons so the in-app test entry can explain itself.
    static func scan(_ text: String, templates: [SmsTemplate], now: Date = Date()) -> ScanResult {
        var attempts: [Attempt] = []
        for template in templates {
            let slotMap = SmsTemplateMatcher.decodeSlotMap(template.slotMapJSON)
            switch SmsTemplateMatcher.matchDetailed(text, pattern: template.compiledPattern,
                                                    slotMap: slotMap, now: now) {
            case .failed(let why):
                attempts.append(Attempt(template: template, reason: .failed(why)))
            case .matched(let fields):
                guard fields.amount != nil else {
                    attempts.append(Attempt(template: template, reason: .matchedButNoAmount))
                    continue
                }
                return ScanResult(hitTemplate: template, hitFields: fields, attempts: attempts)
            }
        }
        return ScanResult(hitTemplate: nil, hitFields: nil, attempts: attempts)
    }

    // MARK: - Recognized-draft fields (ONE writer, shared by ingest + rescan)

    /// The fully-resolved contents of a recognized draft: currency validated, FX applied,
    /// category chosen. Produced once and applied either to a NEW Transaction (the ingest
    /// Intents) or ONTO AN EXISTING unrecognized draft (the inbox rescan).
    struct ResolvedDraft {
        var type: TransactionType
        var amount: Decimal
        var currency: String
        var fxRateToBase: Decimal
        var needsFxRate: Bool
        var date: Date
        var merchant: String?
        var note: String
        var category: Category?
    }

    /// Resolve a match into persisted-draft fields. Byte-for-byte the logic
    /// IngestUOBMessageIntent.ingest used inline before GN-052 (currency validated against
    /// CurrencyCatalog else the template's fallback → CurrencyConverter, which never throws and
    /// flags needsFxRate on failure → MerchantMemory category, else the template's default).
    @MainActor
    static func resolveDraft(template: SmsTemplate, fields: MatchedFields,
                             base: String, in ctx: ModelContext) async -> ResolvedDraft? {
        guard let amount = fields.amount else { return nil }

        // Currency: a bogus 3-letter run must NOT go into FX — validate against the ISO catalog.
        let validCurrencies = Set(CurrencyCatalog.all)
        let currency: String = {
            if let c = fields.currency, validCurrencies.contains(c) { return c }
            return template.currencyFallback
        }()

        // Foreign → base. Never throws; on failure downgrades + flags needsFxRate.
        let result = await CurrencyConverter.live().convert(amount: amount,
                                                           currencyCode: currency, base: base)

        // Category: MerchantMemory (raw key) first; else the template's defaultCategoryID.
        var category: Category? = nil
        if let merchantRaw = fields.merchantRaw {
            category = MerchantMemory.suggestedCategory(forRaw: merchantRaw, in: ctx)
        }
        if category == nil, let catID = template.defaultCategoryID {
            category = fetchCategory(id: catID, in: ctx)
        }

        return ResolvedDraft(
            type: TransactionType(rawValue: template.transactionTypeRaw) ?? .expense,
            amount: amount,
            currency: currency,
            fxRateToBase: result.fxRateToBase,
            needsFxRate: result.needsFxRate,
            date: fields.date ?? .now,   // GN-028: SMS 正文交易日期;抽不到 → 到达时刻(不丢账)
            merchant: fields.merchantRaw,
            note: template.name,         // 收件箱据此显示是哪条模版捕获
            category: category
        )
    }

    /// Write resolved fields onto a Transaction. Used for a freshly-built draft AND to UPGRADE an
    /// existing unrecognized draft in place.
    ///
    /// ★ `recomputeSGDAmount()` is mandatory: `sgdAmount` is a REDUNDANT stored column that
    /// Transaction.init computes once. Mutating originalAmount/fxRateToSGD without recomputing
    /// would leave an upgraded draft summing as 0 in every report.
    /// ★ Never touches id / isPending / source / createdAt — an upgraded draft keeps its identity
    /// and stays pending for the user to confirm.
    @MainActor
    static func apply(_ r: ResolvedDraft, to txn: Transaction) {
        txn.type = r.type
        txn.originalAmount = r.amount
        txn.currencyCode = r.currency
        txn.fxRateToSGD = r.fxRateToBase   // @Model 字段保留名;语义 = 到本位币
        txn.date = r.date
        txn.note = r.note
        txn.merchant = r.merchant
        txn.needsFxRate = r.needsFxRate
        txn.category = r.category
        txn.recomputeSGDAmount()
    }

    // MARK: - GN-052 Task 2: re-run a just-saved template over the inbox's unrecognized drafts

    /// An "unrecognized" draft = the original-text draft the ingest path writes on no-match
    /// (amount 0, full text in `note`, still pending). Single definition — PendingInboxView's
    /// row rendering calls this too, so the inbox and the rescan can never disagree about which
    /// drafts are eligible.
    static func isUnrecognizedDraft(_ t: Transaction) -> Bool {
        t.isPending && t.originalAmount == 0 && (t.merchant == nil || t.merchant == "")
    }

    /// GN-052 Task 2 — after a template is saved (NEW **or** EDITED), re-run THAT template over
    /// every unrecognized draft already in the inbox and upgrade the ones it now recognizes.
    ///
    /// Before GN-052 the inbox explicitly did NOT do this ("下一条短信才会匹配"), so the user who
    /// built a template from an unrecognized SMS watched that very SMS stay unrecognized — which
    /// is exactly what "我建完模版,再放同一条短信仍说没识别到" was.
    ///
    /// ★ NEVER destructive. A draft that still doesn't match is left byte-for-byte alone; a draft
    /// that matches is UPGRADED IN PLACE (same row, same id, still `isPending`) rather than
    /// deleted-and-reinserted, so no transaction can be lost and none can be duplicated. Once
    /// upgraded, a draft no longer satisfies `isUnrecognizedDraft`, so a second save can't
    /// promote it twice.
    ///
    /// Matching runs through `scan` → `matchDetailed` → `decodeSlotMap` on the PERSISTED
    /// `slotMapJSON` (not the in-memory slotMap the editor just compiled), which also proves the
    /// JSON round-trip survived — the `"[]"` degradation would otherwise only surface much later
    /// as a permanently-unmatchable template.
    ///
    /// Returns how many drafts were upgraded.
    @MainActor
    @discardableResult
    static func rescanUnrecognizedDrafts(with template: SmsTemplate,
                                         in ctx: ModelContext) async -> Int {
        // Only drafts from the same capture path this template serves (GN-039 keeps SMS and
        // email templates from cross-matching; their drafts carry source "sms" / "email").
        let wantedSource = template.inputKind == "email" ? "email" : "sms"
        let pending = (try? ctx.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.isPending }))) ?? []
        let candidates = pending.filter { isUnrecognizedDraft($0) && $0.source == wantedSource }
        guard !candidates.isEmpty else { return 0 }

        let base = AppSettings.current(in: ctx).baseCurrencyCode
        var upgraded = 0
        for draft in candidates {
            // The unrecognized draft keeps the original text in `note` — that is what we match.
            let result = scan(draft.note, templates: [template])
            guard let hitTemplate = result.hitTemplate, let fields = result.hitFields,
                  let resolved = await resolveDraft(template: hitTemplate, fields: fields,
                                                    base: base, in: ctx) else {
                continue   // ★ untouched
            }
            apply(resolved, to: draft)
            upgraded += 1
        }
        if upgraded > 0 { try? ctx.save() }
        return upgraded
    }

    /// Resolve a defaultCategoryID (UUID scalar, no relation) to its Category, or nil if the
    /// category was deleted (a harmless dangling id — same tolerance as MerchantMemory).
    @MainActor
    static func fetchCategory(id: UUID, in ctx: ModelContext) -> Category? {
        var d = FetchDescriptor<Category>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? ctx.fetch(d))?.first
    }
}
