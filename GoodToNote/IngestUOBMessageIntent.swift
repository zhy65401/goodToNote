//
//  IngestUOBMessageIntent.swift
//  GoodToNote
//
//  GN-005 / GN-025 (Phase B, Task B2) — SILENT App Intent fed the full SMS text by an
//  iOS Messages automation + Shortcut. openAppWhenRun=false, no interaction → runs on
//  the lock screen and many messages in a row never collide or get lost (the whole
//  point of the "pending inbox" design).
//
//  IMPORTANT — the class name `IngestUOBMessageIntent` AND the Intent type identifier are
//  PRESERVED on purpose (renaming the struct breaks the user's already-configured
//  Messages-automation Shortcut, GN-021 R4). It is no longer UOB-specific: it drives the
//  example-driven template engine (GN-025) and recognizes ANY bank/language SMS the user has
//  a template for. GN-030: only the user-VISIBLE `title` was de-branded to a neutral
//  "处理银行短信 / Ingest bank SMS" (a display string — changing it does NOT break automations;
//  the identifier stays the struct name).
//
//  Flow (GN-025):
//    fetch enabled SmsTemplates by ascending orderIndex → try SmsTemplateMatcher.matchOne
//    on each, take the FIRST hit (with a non-nil amount) → convert foreign→base
//    (CurrencyConverter; failure flags needsFxRate, never loses the txn) → write ONE
//    isPending=true draft (date = matched.date ?? .now — GN-028 extracts the transaction
//    date from the SMS body when the template carries a .date slot, falling back to the SMS
//    arrival time when absent/unparseable; merchant=merchantRaw, category prefilled from
//    MerchantMemory else the template's defaultCategoryID, note=template.name so the
//    inbox shows which template caught it) into the SHARED store (AppModelContainer).
//  NO match (or a matched amount that is nil) → write an ORIGINAL-TEXT draft
//    (originalAmount 0, full SMS in note, isPending) so the SMS is NEVER dropped; the
//    pending inbox surfaces it as "unrecognized" and offers "build a template from this"
//    (that inbox rendering is Phase B3 — not this dispatch).
//  Confirmation/accept/reject all happen later in the app's pending inbox, not here.
//  Free Apple ID: App Intents need no paid entitlement.
//

import Foundation
import AppIntents
import SwiftData

struct IngestUOBMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Ingest bank SMS"
    static var description = IntentDescription(
        "把一条交易短信全文喂给 5分钱，静默按你的短信模版识别并落盘成一笔待确认草稿（无匹配模版则落原文待识别，绝不丢弃）。")
    /// Stay silent in the background — must work on the lock screen, no UI.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "短信全文")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("把短信 \(\.$message) 落盘成待确认草稿")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // SHARED store — same on-disk store as the main app (cross-process), so the seeded
        // templates + AppSettings here are the SAME the app reads/writes. The whole
        // parse→FX→persist chain lives in `Self.ingest` so the in-app 发送测试 (GN-026
        // ShortcutSetupView 段3) runs the IDENTICAL path without duplicating any logic.
        let ctx = try AppModelContainer.shared().mainContext
        let outcome = await Self.ingest(message: message, into: ctx)
        return .result(dialog: IntentDialog(stringLiteral: outcome.dialogLine))
    }

    /// Result of one ingest: how many pending drafts were written (always 1 — either a
    /// recognized draft or an original-text fallback), whether it matched a template, and a
    /// user-facing dialog line (shown when the Shortcut is run manually; reused as the
    /// GN-026 send-test confirmation source).
    struct IngestOutcome {
        var draftsCreated: Int
        var matched: Bool
        var dialogLine: String
    }

    /// The single source of truth for "feed one SMS → write one pending draft". Called by
    /// `perform()` (the silent Messages-automation entry) AND by the GN-026 ShortcutSetupView
    /// 发送测试 button (in-app, NOT via Shortcuts) so both exercise the exact same
    /// parse→FX→persist chain (DRY). Pass the SHARED ModelContext (the app's main context or
    /// AppModelContainer.shared().mainContext). Never throws on parse/FX failure — an
    /// unrecognized SMS still lands an original-text draft so nothing is dropped.
    @MainActor
    static func ingest(message: String, into ctx: ModelContext) async -> IngestOutcome {
        let base = AppSettings.current(in: ctx).baseCurrencyCode

        // Fetch enabled SMS templates in ascending orderIndex; try each in order and take the
        // FIRST template that matches with a usable (non-nil) amount. GN-039: the predicate now
        // also requires inputKind == "sms" so the SMS path only ever tries SMS templates (email
        // templates — inputKind == "email" — are tried solely by IngestEmailIntent). Old templates
        // migrate to inputKind "sms" (the additive default), so existing SMS templates still match.
        var descriptor = FetchDescriptor<SmsTemplate>(
            predicate: #Predicate { $0.isEnabled == true && $0.inputKind == "sms" },
            sortBy: [SortDescriptor(\.orderIndex, order: .forward)]
        )
        descriptor.propertiesToFetch = []   // fetch full objects (small table)
        let templates = (try? ctx.fetch(descriptor)) ?? []

        var matchedTemplate: SmsTemplate?
        var matched: MatchedFields?
        for template in templates {
            let slotMap = decodeSlotMap(template.slotMapJSON)
            guard let fields = SmsTemplateMatcher.matchOne(
                message, pattern: template.compiledPattern, slotMap: slotMap) else { continue }
            // A "matched" draft must carry a real amount; a hit with no amount is treated
            // as unmatched below (don't write a zero-amount "matched" draft).
            guard fields.amount != nil else { continue }
            matchedTemplate = template
            matched = fields
            break
        }

        // MATCH → build a recognized pending draft.
        if let template = matchedTemplate, let fields = matched, let amount = fields.amount {
            // Currency: validate the matched 3-letter run against the known ISO catalog
            // (Reviewer carry-forward note) — a bogus 3-char run must NOT go into FX.
            let validCurrencies = Set(CurrencyCatalog.all)
            let currency: String = {
                if let c = fields.currency, validCurrencies.contains(c) { return c }
                return template.currencyFallback
            }()

            // Foreign → base. Never throws; on failure downgrades + flags needsFxRate.
            let conv = CurrencyConverter.live()
            let result = await conv.convert(amount: amount, currencyCode: currency, base: base)

            // Category: MerchantMemory (raw key) first; else the template's
            // defaultCategoryID resolved to a Category (UUID scalar → fetch); else nil.
            var category: Category? = nil
            if let merchantRaw = fields.merchantRaw {
                category = MerchantMemory.suggestedCategory(forRaw: merchantRaw, in: ctx)
            }
            if category == nil, let catID = template.defaultCategoryID {
                category = fetchCategory(id: catID, in: ctx)
            }

            let txn = Transaction(
                type: TransactionType(rawValue: template.transactionTypeRaw) ?? .expense,
                originalAmount: amount,
                currencyCode: currency,
                fxRateToSGD: result.fxRateToBase,   // @Model 字段保留名;语义 = 到本位币
                date: fields.date ?? .now,           // GN-028: 短信正文交易日期;抽不到/解析失败 → 到达时刻(不丢账)
                note: template.name,                 // 收件箱据此显示是哪条模版捕获
                merchant: fields.merchantRaw,
                needsFxRate: result.needsFxRate,
                isPending: true,
                source: "sms",                       // GN-036: 录入来源 = 短信(匹配草稿)
                category: category
            )
            ctx.insert(txn)
            try? ctx.save()

            // Confirmation dialog (shown only if the user runs the Shortcut manually).
            // GN-024: 金额走 formatBase（Decimal direct，显式币种前缀）。
            let amt = formatBase(amount, code: currency)
            let merchantDisplay = fields.merchantRaw.map { UOBMessageParser.displayName(from: $0) } ?? template.name
            var line = String(localized: "已收到待确认：\(amt) \(merchantDisplay)")
            if result.needsFxRate { line += String(localized: "（汇率待补）") }
            return IngestOutcome(draftsCreated: 1, matched: true, dialogLine: line)
        }

        // NO MATCH (or matched amount nil) → write an ORIGINAL-TEXT draft so the SMS is
        // NEVER dropped. originalAmount 0, full text in note, isPending. The pending inbox
        // renders this "unrecognized" draft + offers build-a-template (Phase B3).
        let draft = Transaction(
            type: .expense,
            originalAmount: 0,
            currencyCode: base,
            fxRateToSGD: 1,
            date: .now,
            note: message,            // full original SMS text
            isPending: true,
            source: "sms"             // GN-036: 录入来源 = 短信(原文待识别草稿)
        )
        ctx.insert(draft)
        try? ctx.save()

        return IngestOutcome(draftsCreated: 1, matched: false,
                             dialogLine: String(localized: "已收到，待在 app 内识别。"))
    }

    /// Decode SmsTemplate.slotMapJSON (e.g. ["currency","amount","merchant"]) into
    /// [SlotRole], dropping any unknown role string. Empty/garbage JSON → [].
    private static func decodeSlotMap(_ json: String) -> [SlotRole] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return raw.compactMap { SlotRole(rawValue: $0) }
    }

    /// Resolve a defaultCategoryID (UUID scalar, no relation) to its Category, or nil if
    /// the category was deleted (a harmless dangling id — same tolerance as MerchantMemory).
    @MainActor
    private static func fetchCategory(id: UUID, in ctx: ModelContext) -> Category? {
        var d = FetchDescriptor<Category>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? ctx.fetch(d))?.first
    }
}
