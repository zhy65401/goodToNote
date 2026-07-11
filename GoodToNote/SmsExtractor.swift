//
//  SmsExtractor.swift
//  GoodToNote
//
//  GN-025 (Phase A) — Heuristic extractor: raw SMS text → candidate spans for
//  currency / amount / merchant + a best guess for each. Offline, no ML, language-
//  agnostic (per GN-021 §1): iOS has no money extractor (NSDataDetector / NLTagger
//  don't emit currency), so we scan with a number-run regex + a symbol/ISO/native-word
//  currency dictionary + merchant anchor words. Correctness is backstopped by the
//  user's point-select confirmation UI (Phase C) — the extractor only proposes.
//

import Foundation

/// A character-range span of the original text plus its substring.
struct ExtractedSpan: Equatable { let range: Range<String.Index>; let text: String }

/// Candidates + best guesses produced from one SMS.
struct ExtractionResult {
    let amountCandidates: [ExtractedSpan]
    let currencyCandidates: [(span: ExtractedSpan, code: String)]
    let merchantCandidates: [ExtractedSpan]
    let bestAmount: Decimal?
    let bestCurrency: String?
    let bestMerchant: String?
    /// GN-028: date-shaped spans found in the text (in order of appearance).
    let dateCandidates: [ExtractedSpan]
    /// GN-028: the first date-shaped span whose text DateParser can parse (the C1 editor's
    /// pre-fill for the optional 日期 field); nil if none parse.
    let bestDateText: String?
}

enum SmsExtractor {
    /// Symbol / native-word → ISO. Extend as needed. Order matters: longer/more-specific
    /// tokens (e.g. "S$", "US$", "人民币") are listed before the bare "$" / "元" so the
    /// specific match wins when scanning.
    static let currencyTokens: [(token: String, code: String)] = [
        ("S$", "SGD"), ("US$", "USD"), ("RM", "MYR"), ("HK$", "HKD"), ("A$", "AUD"),
        ("€", "EUR"), ("£", "GBP"), ("¥", "JPY"), ("₩", "KRW"), ("฿", "THB"), ("$", "USD"),
        ("人民币", "CNY"), ("美元", "USD"), ("令吉", "MYR"), ("新币", "SGD"), ("元", "CNY"),
    ]
    static let isoSet: Set<String> = Set(CurrencyCatalog.all)
    static let merchantAnchors = ["at ", "到", "@", "在", "merchant", "商户"]

    static func extract(_ text: String) -> ExtractionResult {
        let full = NSRange(text.startIndex..., in: text)

        // 1) Number-runs.
        let numRe = try! NSRegularExpression(pattern: #"[0-9][0-9.,]*[0-9]|[0-9]"#)
        var amountSpans: [ExtractedSpan] = []
        for m in numRe.matches(in: text, range: full) {
            if let r = Range(m.range, in: text) {
                amountSpans.append(ExtractedSpan(range: r, text: String(text[r])))
            }
        }

        // 2) Currency candidates: ISO three-letter (in the known set) or symbol/native word.
        var curCands: [(span: ExtractedSpan, code: String)] = []
        // 2a ISO: uppercase three letters within the known set.
        let isoRe = try! NSRegularExpression(pattern: #"[A-Z]{3}"#)
        for m in isoRe.matches(in: text, range: full) {
            if let r = Range(m.range, in: text) {
                let tok = String(text[r])
                if isoSet.contains(tok) {
                    curCands.append((ExtractedSpan(range: r, text: tok), tok))
                }
            }
        }
        // 2b Symbol / native word.
        for (token, code) in currencyTokens {
            var searchStart = text.startIndex
            while let rr = text.range(of: token, range: searchStart..<text.endIndex) {
                curCands.append((ExtractedSpan(range: rr, text: token), code))
                searchStart = rr.upperBound
            }
        }

        // 3) Best amount: among parseable number-runs, prefer one adjacent to a currency
        //    token (largest such); else the largest overall. AmountParser filters illegals.
        let parsed: [(span: ExtractedSpan, val: Decimal)] = amountSpans.compactMap {
            guard let v = AmountParser.parse($0.text) else { return nil }
            return ($0, v)
        }
        func adjacent(_ a: ExtractedSpan) -> Bool {
            curCands.contains { c in
                // currency token within ≤ 3 chars of the number-run (allows one space/punct).
                let between1 = text.distance(from: c.span.range.upperBound, to: a.range.lowerBound)
                let between2 = text.distance(from: a.range.upperBound, to: c.span.range.lowerBound)
                return (between1 >= 0 && between1 <= 3) || (between2 >= 0 && between2 <= 3)
            }
        }
        // A currency token sits IMMEDIATELY TO THE LEFT (a *leading* currency: "SGD 36.34",
        // "人民币36.34", "S$88.00"). This is the strongest transaction-amount signal and the
        // one that separates the txn amount from a trailing balance ("余额1,234.56元": the
        // balance is only followed by the unit "元" and is preceded by "余额", NOT a currency
        // token). Per GN-021 §1.2 / §7 worked example.
        func precededByCurrency(_ a: ExtractedSpan) -> Bool {
            curCands.contains { c in
                let gap = text.distance(from: c.span.range.upperBound, to: a.range.lowerBound)
                return gap >= 0 && gap <= 3
            }
        }
        // Preference order: (1) earliest amount with a leading currency token; else
        // (2) earliest amount merely adjacent to a currency token; else (3) the largest
        // parseable run overall. "Earliest" beats "largest" because the transaction amount
        // is the sentence subject and precedes any trailing balance. The user-confirm UI
        // (Phase C) is the ultimate backstop, so a sensible best-guess suffices.
        func earliest(_ xs: [(span: ExtractedSpan, val: Decimal)]) -> (span: ExtractedSpan, val: Decimal)? {
            xs.min(by: { $0.span.range.lowerBound < $1.span.range.lowerBound })
        }
        let bestAmtSpan = earliest(parsed.filter { precededByCurrency($0.span) })
                          ?? earliest(parsed.filter { adjacent($0.span) })
                          ?? parsed.max(by: { $0.val < $1.val })

        // 4) Best currency: the one nearest bestAmount; else the first.
        var bestCur: String? = curCands.first?.code
        if let amt = bestAmtSpan {
            if let near = curCands.min(by: { lhs, rhs in
                func gap(_ c: ExtractedSpan) -> Int {
                    abs(text.distance(from: c.range.lowerBound, to: amt.span.range.lowerBound))
                }
                return gap(lhs.span) < gap(rhs.span)
            }) { bestCur = near.code }
        }

        // 5) Merchant: after an anchor word, up to the next structural punctuation / EOL.
        var merchCands: [ExtractedSpan] = []
        for anchor in merchantAnchors {
            if let ar = text.range(of: anchor) {
                let afterStart = ar.upperBound
                let stopChars = CharacterSet(charactersIn: ".,;。，\n")
                var end = afterStart
                while end < text.endIndex,
                      !String(text[end]).unicodeScalars.allSatisfy({ stopChars.contains($0) }) {
                    end = text.index(after: end)
                }
                let mr = afterStart..<end
                let mt = String(text[mr]).trimmingCharacters(in: .whitespaces)
                if !mt.isEmpty { merchCands.append(ExtractedSpan(range: mr, text: mt)) }
            }
        }
        // Chinese "在X消费" pattern: take between "在" and "消费" if present (preferred).
        if let zai = text.range(of: "在"), let xiaofei = text.range(of: "消费"),
           zai.upperBound < xiaofei.lowerBound {
            let mr = zai.upperBound..<xiaofei.lowerBound
            let mt = String(text[mr]).trimmingCharacters(in: .whitespaces)
            if !mt.isEmpty { merchCands.insert(ExtractedSpan(range: mr, text: mt), at: 0) }
        }

        // 6) Date candidates (GN-028): scan for date-SHAPED spans (numeric DD/MM[/YY[YY]] &
        //    YYYY-MM-DD, Chinese M月D日, textual "30 May[ 2026]" / "May 30[, 2026]"). best =
        //    the first whose text DateParser actually parses (shape ≠ valid date). The C1 UI
        //    pre-fills its optional 日期 field from bestDateText; the matcher uses DateParser
        //    at runtime. The shape mirrors the compiler's .date sub-pattern.
        let dateShape = try! NSRegularExpression(pattern:
            #"(?:\d{1,4}(?:[/\-]\d{1,2}){2})|(?:\d{1,2}月\d{1,2}日)|(?:\d{1,2}\s[A-Za-z]{3,}(?:\s\d{2,4})?)|(?:[A-Za-z]{3,}\s\d{1,2}(?:,?\s\d{2,4})?)"#)
        var dateSpans: [ExtractedSpan] = []
        for m in dateShape.matches(in: text, range: full) {
            if let r = Range(m.range, in: text) {
                dateSpans.append(ExtractedSpan(range: r, text: String(text[r])))
            }
        }
        let bestDate = dateSpans.first(where: { DateParser.parse($0.text) != nil })

        return ExtractionResult(
            amountCandidates: amountSpans,
            currencyCandidates: curCands,
            merchantCandidates: merchCands,
            bestAmount: bestAmtSpan?.val,
            bestCurrency: bestCur,
            bestMerchant: merchCands.first?.text,
            dateCandidates: dateSpans,
            bestDateText: bestDate?.text)
    }
}
