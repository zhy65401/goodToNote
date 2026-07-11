//
//  DuplicateDetector.swift
//  GoodToNote
//
//  GN-036 / GN-039 — Pure de-dup detection for the three capture paths that can record the SAME
//  purchase: Apple Pay (IngestWalletTransactionIntent, source=="applePay", straight into the
//  ledger), bank SMS (IngestUOBMessageIntent, source=="sms", a pending draft), and bank EMAIL
//  (IngestEmailIntent, source=="email", a pending draft). One tap-to-pay can fire ALL THREE, so a
//  single purchase may be recorded/drafted up to three times. The pending inbox runs this over each
//  pending draft to FLAG the ones that look like an already-captured purchase, so the user can
//  reject the redundant one (or accept it if it really is a distinct purchase). It NEVER auto-drops
//  anything — flagging only (user decision 2026-06-14): the accept/reject buttons are unchanged.
//
//  GN-036 (original): de-dup was ONE-DIRECTIONAL — only Apple Pay LEDGER rows anchored a match, an
//  SMS draft was flagged iff a source=="applePay" ledger row had the same amount+currency within
//  ±15 min. `isSuspectedDuplicate(draft:against:window:)` (the GN-036 signature) is PRESERVED
//  verbatim below (GN-036_dedup_test pins it) and still does exactly that.
//
//  GN-039 (three-way) — `isSuspectedDuplicateThreeWay(...)` GENERALIZES it for the email path:
//    • ANCHORS expand from "only applePay" to "applePay OR sms OR email":
//        – an ALREADY-LEDGERED row (any of the three sources) anchors a pending draft, AND
//        – another PENDING draft of a DIFFERENT source (sms ⇄ email) can anchor too, so the user
//          isn't asked to confirm the same purchase twice (once for the SMS draft, once for email).
//    • SYMMETRY without DOUBLE-FLAGGING: when two PENDING drafts (sms + email) are the same
//        purchase we must flag EXACTLY ONE (flagging both is confusing — the user can't tell which
//        to keep). We define a strict "arrived later" order (date, tie-broken by a stable key) and
//        flag ONLY the later-arriving draft; the earlier one stays clean as the canonical row. A
//        LEDGERED anchor always wins (a pending draft duplicating an accepted row is always the
//        "later" one → flagged), matching GN-036.
//    • WINDOW: email arrives later + more variably than SMS, so any comparison INVOLVING an email
//        row uses the wider `emailWindow` (±60 min); applePay ⇄ sms keeps the tighter
//        `defaultWindow` (±15 min). Both are parameters.
//  We compare ORIGINAL amount + currencyCode (a single purchase's original-currency amount is
//  identical on every path), NOT the base-converted sgdAmount (FX rounding could differ slightly).
//
//  Why pure value tuples (no SwiftData): keeps the rule trivially unit-testable
//  (GN-036_dedup_test + GN-039_dedup3_test) and keeps the @Model/UI concerns in PendingInboxView.
//  The caller maps its Transaction rows to these tuples.
//

import Foundation

enum DuplicateDetector {
    /// Default time window: ±15 minutes (applePay ⇄ sms). The Apple Pay automation fires at tap
    /// time and the bank SMS typically arrives within a couple of minutes; 15 min absorbs delivery
    /// lag + the occasional iOS 18 automation timeout without colliding unrelated same-amount buys.
    static let defaultWindow: TimeInterval = 900

    /// GN-039 wider window: ±60 minutes for any comparison INVOLVING an email row. Transaction
    /// emails (statements, receipts) can land minutes-to-much-later than the SMS/tap; ±15 min is
    /// too tight for them. The cost (a same-amount unrelated purchase within an hour being flagged)
    /// is bounded by "flag only, never auto-drop" — the user makes the final call.
    static let emailWindow: TimeInterval = 3600

    /// The three machine-capture sources that can record the same purchase (and thus anchor a
    /// duplicate). manual / recurring are NEVER anchors (a hand-entered or scheduled txn is not an
    /// automatic capture of a card swipe).
    static let anchorSources: Set<String> = ["applePay", "sms", "email"]

    // MARK: - GN-036 (PRESERVED VERBATIM — pinned by GN-036_dedup_test)

    /// True iff `draft` looks like a purchase ALREADY recorded as an Apple Pay transaction in
    /// `ledger`. Only `source == "applePay"` rows can anchor a match (SMS never dedupes vs SMS /
    /// manual / recurring). `amount` uses exact Decimal value equality (so 36.340 == 36.34).
    ///
    /// GN-039 note: this is the ORIGINAL GN-036 entry point, kept byte-compatible for its tests and
    /// any caller that only wants the Apple-Pay-anchored behavior. The pending inbox now calls
    /// `isSuspectedDuplicateThreeWay` instead (which also anchors on sms/email and adds the email
    /// window), but this remains correct and is a strict subset of the three-way rule.
    static func isSuspectedDuplicate(
        draft: (amount: Decimal, currency: String, date: Date),
        against ledger: [(amount: Decimal, currency: String, date: Date, source: String)],
        window: TimeInterval = defaultWindow
    ) -> Bool {
        ledger.contains { row in
            row.source == "applePay"
                && row.currency == draft.currency
                && row.amount == draft.amount
                && abs(row.date.timeIntervalSince(draft.date)) <= window
        }
    }

    // MARK: - GN-039 three-way (applePay / sms / email; symmetric, no double-flag)

    /// A row participating in three-way de-dup. `key` is a STABLE per-row identifier (e.g. the
    /// Transaction's UUID string) used only as the deterministic tiebreaker when two pending drafts
    /// have the exact same `date` — so the "arrived later" order is total and exactly one of a
    /// same-instant sms/email pair is flagged. `isPending` distinguishes an accepted ledger row
    /// (anchor that always wins) from another pending draft (only a DIFFERENT-source, EARLIER one
    /// anchors).
    struct Row {
        var amount: Decimal
        var currency: String
        var date: Date
        var source: String
        var isPending: Bool
        var key: String
        init(amount: Decimal, currency: String, date: Date, source: String,
             isPending: Bool, key: String) {
            self.amount = amount; self.currency = currency; self.date = date
            self.source = source; self.isPending = isPending; self.key = key
        }
    }

    /// True iff the pending `draft` looks like the SAME purchase as some `other` row, under the
    /// three-way rule. Flags ONLY the later-arriving of a pending pair (no double-flag) while a
    /// ledgered anchor always flags the pending draft. `others` should be every OTHER candidate row
    /// (ledgered applePay/sms/email rows + the other pending drafts); the draft's own row may be
    /// included — it is skipped by `key` so a caller can pass one flat list.
    ///
    /// Rule for a candidate `o` to flag `draft`:
    ///   1) o.source ∈ {applePay, sms, email}  (manual/recurring never anchor), AND
    ///   2) o.currency == draft.currency AND o.amount == draft.amount (exact Decimal), AND
    ///   3) |o.date − draft.date| <= window, where window = emailWindow if EITHER row is email,
    ///      else defaultWindow, AND
    ///   4) one of:
    ///        • o is LEDGERED (o.isPending == false) → it always anchors (the pending draft is the
    ///          redundant/later capture of an accepted txn), OR
    ///        • o is PENDING, o.source != draft.source (sms ⇄ email only — two SMS drafts or two
    ///          email drafts are not cross-path duplicates), AND o is strictly EARLIER than the
    ///          draft by (date, then key) so EXACTLY ONE of the pair is flagged.
    static func isSuspectedDuplicateThreeWay(
        draft: Row,
        against others: [Row],
        defaultWindow: TimeInterval = defaultWindow,
        emailWindow: TimeInterval = emailWindow
    ) -> Bool {
        // A draft must itself be a real (amount-bearing) machine draft to be flag-eligible; the
        // caller already excludes amount-0 "unrecognized" drafts, but guard defensively.
        guard anchorSources.contains(draft.source) else { return false }

        for o in others {
            if o.key == draft.key { continue }                    // never compare a row to itself
            guard anchorSources.contains(o.source) else { continue }
            guard o.currency == draft.currency, o.amount == draft.amount else { continue }

            // Window widens if EITHER side is an email row (email arrives later + more variably).
            let window = (o.source == "email" || draft.source == "email") ? emailWindow : defaultWindow
            guard abs(o.date.timeIntervalSince(draft.date)) <= window else { continue }

            if !o.isPending {
                // Accepted ledger row of a capture source → always anchors this pending draft.
                return true
            }
            // Both pending: only a DIFFERENT-source, strictly-EARLIER draft anchors (so exactly one
            // of an sms/email pair is flagged — the later-arriving one).
            if o.source != draft.source, isEarlier(o, than: draft) {
                return true
            }
        }
        return false
    }

    /// Strict total "arrived earlier" order over pending rows: earlier `date` wins; on an exact
    /// date tie the lexicographically smaller `key` is "earlier". Total + antisymmetric, so for any
    /// two distinct rows exactly one is earlier → a same-purchase pending pair flags exactly once.
    private static func isEarlier(_ a: Row, than b: Row) -> Bool {
        if a.date != b.date { return a.date < b.date }
        return a.key < b.key
    }
}
