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
        // FIRST template that matches with a usable (non-nil) amount. GN-039: the predicate also
        // requires inputKind == "sms" so the SMS path only ever tries SMS templates (email
        // templates — inputKind == "email" — are tried solely by IngestEmailIntent). Old templates
        // migrate to inputKind "sms" (the additive default), so existing SMS templates still match.
        // GN-052: the fetch + first-match loop + draft-field writing now live in
        // SmsRecognitionRuntime so the post-save inbox rescan and the in-app test entry run this
        // EXACT path instead of a second copy of it. Semantics are unchanged.
        let templates = SmsRecognitionRuntime.enabledTemplates(kind: "sms", in: ctx)
        let scan = SmsRecognitionRuntime.scan(message, templates: templates)

        // MATCH → build a recognized pending draft.
        if let template = scan.hitTemplate, let fields = scan.hitFields,
           let resolved = await SmsRecognitionRuntime.resolveDraft(
               template: template, fields: fields, base: base, in: ctx) {
            let txn = Transaction(type: resolved.type, originalAmount: resolved.amount,
                                  isPending: true,
                                  source: "sms")   // GN-036: 录入来源 = 短信(匹配草稿)
            SmsRecognitionRuntime.apply(resolved, to: txn)
            ctx.insert(txn)
            try? ctx.save()

            // Confirmation dialog (shown only if the user runs the Shortcut manually).
            // GN-024: 金额走 formatBase（Decimal direct，显式币种前缀）。
            let amt = formatBase(resolved.amount, code: resolved.currency)
            let merchantDisplay = resolved.merchant.map { UOBMessageParser.displayName(from: $0) } ?? template.name
            var line = String(localized: "已收到待确认：\(amt) \(merchantDisplay)")
            if resolved.needsFxRate { line += String(localized: "（汇率待补）") }
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

    // GN-052: `decodeSlotMap` and `fetchCategory` moved to the shared recognition path
    // (SmsTemplateMatcher.decodeSlotMap / SmsRecognitionRuntime.fetchCategory) so the ingest
    // runtime, the inbox rescan, the migration and the in-app test entry cannot drift apart.
}
