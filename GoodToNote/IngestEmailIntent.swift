//
//  IngestEmailIntent.swift
//  GoodToNote
//
//  GN-039 — SILENT App Intent for the EMAIL path, structurally identical to IngestUOBMessageIntent
//  (the SMS path) but with one extra front step: an email body is long + usually HTML, so it is run
//  through EmailPreprocessor.process (HTML→plain text + key-segment extraction) BEFORE the shared
//  template engine. The user builds an iOS「邮件 / Email」personal automation (filtered by SENDER —
//  the bank's domain — because email triggers can't match body keywords, GN-038 §Q1) whose Shortcut
//  does "Get Text from Input" on the email file and passes the text to this Intent. openAppWhenRun
//  =false → runs silently on the lock screen, like the other two ingest Intents.
//
//  ── Email-body delivery-form research (GN-038 §Q1.3 + GN-039 spec Task 3) ──
//  When an「邮件」automation fires, the Shortcut Input is the email as a FILE: the file NAME is the
//  subject and the file CONTENTS are the body (usually .html, sometimes .txt). The user's Shortcut
//  must "Get Text from Input" to turn that file into a text string before handing it to this Intent.
//  Apple has NO first-party doc stating this verbatim — the strongest evidence is a 2023 hands-on
//  post + the AppIntents Email type carrying a `Content` field (GN-038 §Q1.3). So, exactly like
//  GN-036 treated the Apple Pay Amount as a defensive String, this Intent treats the body
//  DEFENSIVELY: `rawEmail` is a plain String, an empty/blank body lands nothing (recorded=false,
//  never a 0-row), and the preprocessor tolerates non-HTML / no-money-signal input (truncated
//  fallback). `subject` is optional and informational only (used for the unrecognized-draft note);
//  amount extraction depends only on the body. This delivery form is the ONE真机待验 item (it can't
//  be exercised in this build env) — see the GN-039 note §未验项.
//
//  Flow (mirrors IngestUOBMessageIntent.ingest):
//    EmailPreprocessor.process(rawEmail) → key segment → fetch enabled SmsTemplates with
//    inputKind=="email" by ascending orderIndex → SmsTemplateMatcher.matchOne on the KEY SEGMENT,
//    take the FIRST hit with a non-nil amount → CurrencyConverter (failure flags needsFxRate, never
//    loses the txn) → MerchantMemory / template.defaultCategoryID prefill → write ONE isPending=true
//    draft with source=="email". NO match → write an ORIGINAL-TEXT draft (the KEY SEGMENT, or the
//    subject if the segment is empty) so the email is NEVER dropped; the pending inbox surfaces it
//    as "unrecognized" and offers "build a template from this" (the SAME B3 rendering as SMS).
//
//  De-dup: an email about a purchase may overlap an Apple Pay row AND/OR an SMS draft of the same
//  purchase. We do NOT dedupe here; the pending inbox flags it via DuplicateDetector (GN-039 三路
//  扩展: applePay/sms/email anchors, ±60min for email). We NEVER auto-drop.
//
//  Free Apple ID: App Intents need no paid entitlement. Writes to the SHARED store (AppModelContainer).
//

import Foundation
import AppIntents
import SwiftData

struct IngestEmailIntent: AppIntent {
    static var title: LocalizedStringResource = "Ingest bank email"
    static var description = IntentDescription(
        "把一封交易邮件的正文喂给 5分钱，静默按你的邮件模版识别并落盘成一笔待确认草稿（无匹配模版则落关键段待识别，绝不丢弃）。先在「快捷指令」里用「从输入获取文本」取出邮件正文再传入。")
    /// Stay silent in the background — must work on the lock screen, no UI (same as the SMS Intent).
    static var openAppWhenRun: Bool = false

    /// The email BODY text (the user's Shortcut runs "Get Text from Input" on the email file first).
    /// Taken as a plain String + treated defensively (see header: empty/blank lands nothing).
    @Parameter(title: "邮件正文")
    var rawEmail: String

    /// Optional subject line (the email file's NAME). Informational only — used for the
    /// unrecognized-draft note when the body has no key segment; amount extraction ignores it.
    @Parameter(title: "邮件主题")
    var subject: String?

    static var parameterSummary: some ParameterSummary {
        Summary("把邮件 \(\.$rawEmail) 落盘成待确认草稿")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // SHARED store — same on-disk store as the main app (cross-process). The whole
        // preprocess→parse→FX→persist chain lives in `Self.ingest` so the onboarding 发送测试 (and
        // any in-app caller) exercises the IDENTICAL path without duplicating logic (mirrors the
        // SMS / Apple Pay Intents).
        let ctx = try AppModelContainer.shared().mainContext
        let outcome = await Self.ingest(rawEmail: rawEmail, subject: subject, into: ctx)
        return .result(dialog: IntentDialog(stringLiteral: outcome.dialogLine))
    }

    /// Result of one email ingest: how many pending drafts were written (1 on a non-empty body —
    /// recognized OR original-text fallback; 0 only when the body is empty/blank), whether a template
    /// matched, and a user-facing dialog line (shown if the Shortcut is run manually; reused as the
    /// onboarding send-test confirmation source).
    struct IngestOutcome {
        var draftsCreated: Int
        var matched: Bool
        var dialogLine: String
    }

    /// The single source of truth for "feed one email body → write one pending draft". Pass the
    /// SHARED ModelContext. Never throws on parse/FX failure — an unrecognized email still lands an
    /// original-text draft so nothing is dropped. An empty/blank body (defensive: the trigger could
    /// deliver nothing) writes NOTHING (draftsCreated 0) rather than a junk 0-row.
    @MainActor
    static func ingest(rawEmail: String, subject: String?, into ctx: ModelContext) async -> IngestOutcome {
        // 0) Defensive: empty/blank body → nothing to do (don't pollute the inbox with a 0-row).
        let rawTrimmed = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTrimmed.isEmpty else {
            return IngestOutcome(draftsCreated: 0, matched: false,
                                 dialogLine: String(localized: "邮件正文为空，未记录。"))
        }

        // 1) Preprocess: HTML→plain text + key-segment extraction. The SAME call template-build
        //    uses (SmsTemplateEditorView email mode), so the literal anchors line up with this text.
        let segment = EmailPreprocessor.process(rawEmail)

        let base = AppSettings.current(in: ctx).baseCurrencyCode

        // 2) Fetch enabled EMAIL templates in ascending orderIndex; take the FIRST that matches with
        //    a usable (non-nil) amount. inputKind=="email" keeps the email path separate from SMS.
        //    GN-052: the fetch + first-match loop + draft-field writing are the ONE shared
        //    implementation (SmsRecognitionRuntime) the SMS path uses, instead of a second copy.
        //    Semantics unchanged; matched on the PREPROCESSED key segment.
        let templates = SmsRecognitionRuntime.enabledTemplates(kind: "email", in: ctx)
        let scan = SmsRecognitionRuntime.scan(segment, templates: templates)

        // 3) MATCH → recognized pending draft (source=="email").
        if let template = scan.hitTemplate, let fields = scan.hitFields,
           let resolved = await SmsRecognitionRuntime.resolveDraft(
               template: template, fields: fields, base: base, in: ctx) {
            let txn = Transaction(type: resolved.type, originalAmount: resolved.amount,
                                  isPending: true,
                                  source: "email")   // GN-039: 录入来源 = 邮件(匹配草稿)— 去重锚点
            SmsRecognitionRuntime.apply(resolved, to: txn)
            ctx.insert(txn)
            try? ctx.save()

            let amt = formatBase(resolved.amount, code: resolved.currency)
            let merchantDisplay = resolved.merchant.map { UOBMessageParser.displayName(from: $0) } ?? template.name
            var line = String(localized: "已收到待确认：\(amt) \(merchantDisplay)")
            if resolved.needsFxRate { line += String(localized: "（汇率待补）") }
            return IngestOutcome(draftsCreated: 1, matched: true, dialogLine: line)
        }

        // 4) NO MATCH → ORIGINAL-TEXT draft so the email is NEVER dropped. We store the KEY SEGMENT
        //    (already HTML-stripped + shortened) rather than the raw HTML, so the inbox's
        //    "build a template from this" prefill is the same readable text the engine will see.
        //    If the segment is somehow empty, fall back to the subject (defensive) so note ≠ "".
        let segForNote = segment.isEmpty
            ? (subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : segment
        let draft = Transaction(
            type: .expense,
            originalAmount: 0,
            currencyCode: base,
            fxRateToSGD: 1,
            date: .now,
            note: segForNote.isEmpty ? rawTrimmed : segForNote,   // never empty
            isPending: true,
            source: "email"                       // GN-039: 录入来源 = 邮件(原文待识别草稿)
        )
        ctx.insert(draft)
        try? ctx.save()

        return IngestOutcome(draftsCreated: 1, matched: false,
                             dialogLine: String(localized: "已收到，待在 app 内识别。"))
    }

    // GN-052: the per-Intent `decodeSlotMap` / `fetchCategory` copies are gone — both paths now
    // use SmsTemplateMatcher.decodeSlotMap / SmsRecognitionRuntime.fetchCategory.
}
