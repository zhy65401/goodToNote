//
//  SmsTemplateMatcher.swift
//  GoodToNote
//
//  GN-025 (Phase A) — Runs a compiled template against SMS text and, on a match,
//  extracts the typed fields (amount via AmountParser, currency normalized to ISO),
//  else returns nil. First-match semantics; the pattern is compiled with
//  .dotMatchesLineSeparators (SMS may be multi-line) and merchant (.+?) is non-greedy
//  to the next anchor. The runtime (Phase B) iterates enabled templates by orderIndex
//  and takes the first hit.
//

import Foundation

struct MatchedFields: Equatable {
    var currency: String?
    var amount: Decimal?
    var merchantRaw: String?
    /// GN-028: the transaction date parsed from the SMS body (via DateParser). nil when the
    /// template has no .date slot OR the captured text doesn't parse → the runtime falls back
    /// to .now (the SMS arrival time) and never drops the txn.
    var date: Date?
}

/// GN-052 (Task 3) — WHY a template did not match. `matchOne` used to collapse all three of
/// these into a bare `nil`, with no logging, so a user staring at "没识别到" had no way to tell a
/// broken rule from a genuinely different message — and neither did anyone debugging it. The
/// in-app test entry (ShortcutSetupView) renders these; the ingest runtime still treats every
/// one of them the same way (→ unrecognized draft), so runtime behavior is unchanged.
enum MatchFailure: Equatable {
    /// The stored `compiledPattern` is not a valid NSRegularExpression at all — the template can
    /// NEVER match anything. (Corrupt/hand-edited rule.)
    case invalidPattern
    /// The pattern is valid but this text simply doesn't fit it. The ordinary "not my message".
    case noMatch
    /// The regex matched but produced a different number of capture groups than `slotMap`
    /// expects. Means rule and slotMap have drifted apart — classically a `slotMapJSON` that
    /// degraded to "[]", or a date sub-pattern that gained a stray capturing paren (see
    /// SmsTemplateCompiler's "exactly ONE outer capturing paren" contract). Silent-forever bug:
    /// the regex keeps matching while the guard keeps rejecting.
    case groupCountMismatch(expected: Int, actual: Int)
}

/// GN-052 — the result of ONE template try. `.matched` carries the extracted fields; `.failed`
/// carries a distinguishable reason instead of the old undifferentiated `nil`.
enum MatchOutcome: Equatable {
    case matched(MatchedFields)
    case failed(MatchFailure)
}

enum SmsTemplateMatcher {
    /// Single-template try: on a hit return the extracted fields (amount via AmountParser;
    /// currency normalized to uppercase ISO; date via DateParser), else nil. `now` is the
    /// reference for year-less dates (injected for deterministic tests; defaults to Date()).
    ///
    /// GN-052: now a thin wrapper over `matchDetailed` so there is exactly ONE matching
    /// implementation. Behavior for every existing call site is byte-for-byte unchanged —
    /// all three failure modes still come back as `nil`.
    static func matchOne(_ text: String, pattern: String, slotMap: [SlotRole],
                         now: Date = Date()) -> MatchedFields? {
        if case .matched(let f) = matchDetailed(text, pattern: pattern, slotMap: slotMap, now: now) {
            return f
        }
        return nil
    }

    /// GN-052 — the SAME match as `matchOne`, but reporting WHY it failed. This is the single
    /// matching implementation; `matchOne` delegates to it.
    static func matchDetailed(_ text: String, pattern: String, slotMap: [SlotRole],
                              now: Date = Date()) -> MatchOutcome {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return .failed(.invalidPattern) }
        let full = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: full) else { return .failed(.noMatch) }
        guard m.numberOfRanges == slotMap.count + 1 else {
            return .failed(.groupCountMismatch(expected: slotMap.count + 1,
                                               actual: m.numberOfRanges))
        }
        var f = MatchedFields()
        for (i, role) in slotMap.enumerated() {
            guard let r = Range(m.range(at: i + 1), in: text) else { continue }
            let val = String(text[r]).trimmingCharacters(in: .whitespaces)
            switch role {
            case .amount:   f.amount = AmountParser.parse(val)
            case .currency: f.currency = normalizeCurrency(val)
            case .merchant: f.merchantRaw = val
            case .date:     f.date = DateParser.parse(val, now: now)   // GN-028: was `break`
            case .cardMask: break
            }
        }
        return .matched(f)
    }

    /// GN-032: run `pattern` over `text` and return each CAPTURE group's `Range<String.Index>`
    /// mapped to its slotMap role (no parsing/normalization — just the ranges). Same first-match
    /// structure as `matchOne`, but used by the template metadata sheet to RECOVER the highlight
    /// spans (amount/currency/merchant/date) from the stored exampleText without persisting them.
    /// No match (or an uncompilable pattern / wrong group count) → empty map. cardMask is
    /// non-capturing, so it never appears in slotMap and is never highlighted (acceptable).
    static func matchSpans(_ text: String, pattern: String,
                           slotMap: [SlotRole]) -> [SlotRole: Range<String.Index>] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return [:] }
        let full = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: full),
              m.numberOfRanges == slotMap.count + 1 else { return [:] }
        var out: [SlotRole: Range<String.Index>] = [:]
        for (i, role) in slotMap.enumerated() {
            if let r = Range(m.range(at: i + 1), in: text) { out[role] = r }
        }
        return out
    }

    // MARK: - GN-052: the ONE slotMap codec (persisted JSON ⇄ runtime [SlotRole])

    /// Decode `SmsTemplate.slotMapJSON` (e.g. `["currency","amount","merchant"]`) into
    /// [SlotRole], dropping any unknown role string. Empty/garbage JSON → [].
    ///
    /// GN-052 moved this here from `IngestUOBMessageIntent` (where it was private) so that
    /// EVERY consumer of a persisted rule decodes it identically — the ingest runtime, the
    /// post-save inbox rescan, the compiler migration, the editor's edit-mode load, and the
    /// in-app diagnostic. The GN-052 root cause was two divergent recognition paths ("build a
    /// template" previewed via the SmsExtractor heuristic while the runtime matched via regex);
    /// `matchOne` + `decodeSlotMap` is now the single路径 and lives in one place so it cannot
    /// drift again. NOTE the dropping behavior is load-bearing: an unknown role would otherwise
    /// shift capture-group indices and make `numberOfRanges == slotMap.count + 1` fail forever.
    static func decodeSlotMap(_ json: String) -> [SlotRole] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return raw.compactMap { SlotRole(rawValue: $0) }
    }

    /// Encode a compiled slotMap back to the persisted JSON form. Mirror of `decodeSlotMap`;
    /// on the (impossible) encode failure it yields "[]" — the same degradation the editor and
    /// the preset seeder already used.
    static func encodeSlotMap(_ roles: [SlotRole]) -> String {
        (try? JSONEncoder().encode(roles.map { $0.rawValue }))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func normalizeCurrency(_ tok: String) -> String {
        // ISO short-circuit must require 3 ASCII A–Z letters. A bare `count == 3 &&
        // uppercased == self` test wrongly accepts the 3-CHARACTER Chinese token "人民币"
        // (it has no cased chars, so uppercased() == self) and skips the symbol/native-word
        // table → "人民币" leaks through instead of normalizing to CNY.
        if tok.count == 3, tok.allSatisfy({ $0.isASCII && $0.isLetter }) {
            return tok.uppercased()
        }
        return SmsExtractor.currencyTokens.first { $0.token == tok }?.code ?? tok.uppercased()
    }
}
