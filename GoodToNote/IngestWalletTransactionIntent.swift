//
//  IngestWalletTransactionIntent.swift
//  GoodToNote
//
//  GN-036 — SILENT App Intent for the Apple Pay /「钱包」 path. The user builds a Shortcuts
//  "Transaction"(交易, iOS26「钱包/Wallet」)personal automation that fires at tap-to-pay time
//  and feeds the payment's fields to this Intent, which writes ONE transaction STRAIGHT INTO THE
//  LEDGER (source=="applePay", isPending=false) — fully automatic, ZERO taps, NOT a pending
//  draft. This is the "怎么花钱都近乎自动入账" headline path (GN-035 §A2): no keyword, no per-bank
//  template, no parsing of free text — the data arrives structured.
//
//  openAppWhenRun=false → runs on the lock screen, silently, like IngestUOBMessageIntent.
//
//  ── Transaction-trigger field research (GN-035 §A2 + GN-036 spec Task 2 Step 1) ──
//  The Shortcuts "Transaction" trigger exposes Merchant / Amount / Card / Name / Date as TEXT
//  (selected individually off the Shortcut Input — there is NO single rich object). Two facts
//  drive this Intent's parameter design:
//    1. Amount is a FORMATTED STRING (locale formatting, may carry a leading sign like "–10.50"),
//       and Shortcuts' coercion of it to a number is UNRELIABLE (developers report it silently
//       arriving as 0). → we take `amount: String` and parse it ourselves with AmountParser
//       (which strips grouping + sign and yields a positive Decimal), instead of `amount: Double`.
//    2. There is NO dedicated Currency field. → `currencyCode` is optional; absent/invalid falls
//       back to AppSettings.baseCurrencyCode (the configured base). Foreign codes go through the
//       shared CurrencyConverter (downgrade + flag needsFxRate on failure, never lose the txn).
//  Merchant can also arrive empty (early iOS17 even crashed reading it; iOS18 times out) → it is
//  optional and every field is treated defensively. (Sources: MoneyCoach/TravelSpend/Graham Haley
//  help docs + Apple dev forums 773797/797233 — see GN-036_apple-pay-note.md.)
//
//  De-dup: because a Wallet payment ALSO produces a bank SMS, the SMS path may capture the same
//  purchase as a pending draft. We do NOT dedupe here (Apple Pay records immediately, silently);
//  the pending inbox flags the matching SMS draft via DuplicateDetector (source=="applePay" is the
//  anchor) so the user can reject the redundant one. We NEVER auto-drop.
//
//  Free Apple ID: App Intents need no paid entitlement. Writes to the SHARED store
//  (AppModelContainer) so it lands in the SAME ledger the app reads.
//

import Foundation
import AppIntents
import SwiftData

struct IngestWalletTransactionIntent: AppIntent {
    static var title: LocalizedStringResource = "Record Wallet transaction"
    static var description = IntentDescription(
        "把一笔「钱包」交易(商户+金额)直接记入 5分钱 流水,全自动、无需确认。外币自动换算成本位币。")
    /// Stay silent in the background — must work on the lock screen, no UI.
    static var openAppWhenRun: Bool = false

    /// Merchant name from the Transaction trigger. Optional — the trigger can drop it.
    @Parameter(title: "商户")
    var merchant: String?

    /// Amount as the trigger provides it: a FORMATTED STRING (may carry a sign / grouping). Taken
    /// as text on purpose — Shortcuts' numeric coercion of this field is unreliable. Parsed with
    /// AmountParser inside `ingest`.
    @Parameter(title: "金额")
    var amount: String

    /// Optional ISO 4217 currency code. The trigger has no dedicated currency field, so this is
    /// usually empty → falls back to the configured base currency.
    @Parameter(title: "币种")
    var currencyCode: String?

    static var parameterSummary: some ParameterSummary {
        Summary("把「钱包」交易 \(\.$amount) \(\.$merchant) 记入流水")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // SHARED store — same on-disk store as the main app (cross-process). The whole
        // parse→FX→persist chain lives in `Self.ingest` so any in-app caller exercises the
        // IDENTICAL path without duplicating logic (mirrors IngestUOBMessageIntent).
        let ctx = try AppModelContainer.shared().mainContext
        let outcome = await Self.ingest(merchant: merchant, amount: amount,
                                        currencyCode: currencyCode, into: ctx)
        return .result(dialog: IntentDialog(stringLiteral: outcome.dialogLine))
    }

    /// Result of one Apple Pay ingest: whether a transaction was recorded (false only when the
    /// amount is unparseable — we never write a zero/garbage row), and a user-facing dialog line
    /// (shown if the Shortcut is run manually).
    struct WalletIngestOutcome {
        var recorded: Bool
        var dialogLine: String
    }

    /// The single source of truth for "Apple Pay trigger fields → one applePay ledger row".
    /// Pass the SHARED ModelContext. Never throws: a foreign-FX failure still records (flagged
    /// needsFxRate); only a genuinely unparseable amount records nothing (recorded=false) — we
    /// won't pollute the ledger with a 0 row from a flaky trigger.
    @MainActor
    static func ingest(merchant: String?, amount: String, currencyCode: String?,
                       into ctx: ModelContext) async -> WalletIngestOutcome {
        // The trigger's Amount can carry a leading sign for debits (Apple shows e.g. "–10.50",
        // both ASCII '-' and the Unicode minus '−'). AmountParser only yields POSITIVE Decimals
        // and is shared with the SMS engine (must not change), so strip a leading sign HERE before
        // parsing. We always record the magnitude as an expense (Wallet taps are spends).
        let signless = stripLeadingSign(amount)
        // Parse the amount defensively (handles grouping; nil if no usable number).
        guard let amt = AmountParser.parse(signless) else {
            return WalletIngestOutcome(
                recorded: false,
                dialogLine: String(localized: "未能识别金额,这一笔未记录。"))
        }

        let base = AppSettings.current(in: ctx).baseCurrencyCode

        // Currency: validate against the known ISO catalog (a bogus run must NOT go into FX);
        // absent/invalid → base. Mirrors the SMS path's currency-validation guard.
        let validCurrencies = Set(CurrencyCatalog.all)
        let currency: String = {
            if let c = currencyCode?.trimmingCharacters(in: .whitespaces).uppercased(),
               !c.isEmpty, validCurrencies.contains(c) { return c }
            return base
        }()

        // Foreign → base. Never throws; on failure downgrades + flags needsFxRate (never loses
        // the txn — same contract as the SMS / manual / recurring paths).
        let conv = CurrencyConverter.live()
        let result = await conv.convert(amount: amt, currencyCode: currency, base: base)

        // Category prefill from MerchantMemory (raw merchant key). Unknown → nil (silent; the
        // user can categorize later in the ledger). NO UI here — this is a 0-tap path.
        let cleanMerchant = merchant?.trimmingCharacters(in: .whitespacesAndNewlines)
        let merchantForStore = (cleanMerchant?.isEmpty ?? true) ? nil : cleanMerchant
        var category: Category? = nil
        if let m = merchantForStore {
            category = MerchantMemory.suggestedCategory(forRaw: m, in: ctx)
        }

        let txn = Transaction(
            type: .expense,
            originalAmount: amt,
            currencyCode: currency,
            fxRateToSGD: result.fxRateToBase,   // @Model 字段保留名;语义 = 到本位币
            date: .now,                          // Apple Pay fires at tap time → now is the txn time
            note: "",
            merchant: merchantForStore,
            needsFxRate: result.needsFxRate,
            isPending: false,                    // DIRECT into the ledger — 0-tap, fully automatic
            source: "applePay",                  // de-dup anchor for the SMS path
            category: category
        )
        ctx.insert(txn)
        try? ctx.save()

        // Confirmation dialog (shown only if the Shortcut is run manually). GN-024: 金额走 formatBase
        // (Decimal direct, 显式币种前缀).
        let amtDisplay = formatBase(amt, code: currency)
        let merchantDisplay = merchantForStore.map { UOBMessageParser.displayName(from: $0) }
        var line: String
        if let md = merchantDisplay {
            line = String(localized: "已自动记录:\(amtDisplay) \(md)")
        } else {
            line = String(localized: "已自动记录:\(amtDisplay)")
        }
        if result.needsFxRate { line += String(localized: "（汇率待补）") }
        return WalletIngestOutcome(recorded: true, dialogLine: line)
    }

    /// Strip a single leading sign (ASCII '-' / '+' or the Unicode minus '−' U+2212) plus any
    /// surrounding whitespace, so a debit amount like "–10.50" parses to a positive Decimal.
    /// Only the LEADING sign is removed; interior characters are left for AmountParser.
    static func stripLeadingSign(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let first = t.first, first == "-" || first == "+" || first == "\u{2212}" {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}
