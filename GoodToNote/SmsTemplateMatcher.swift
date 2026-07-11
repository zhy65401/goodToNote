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

enum SmsTemplateMatcher {
    /// Single-template try: on a hit return the extracted fields (amount via AmountParser;
    /// currency normalized to uppercase ISO; date via DateParser), else nil. `now` is the
    /// reference for year-less dates (injected for deterministic tests; defaults to Date()).
    static func matchOne(_ text: String, pattern: String, slotMap: [SlotRole],
                         now: Date = Date()) -> MatchedFields? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: full),
              m.numberOfRanges == slotMap.count + 1 else { return nil }
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
        return f
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
