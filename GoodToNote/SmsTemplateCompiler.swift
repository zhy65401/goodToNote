//
//  SmsTemplateCompiler.swift
//  GoodToNote
//
//  GN-025 (Phase A) — Compiles (example + user-confirmed spans) into ONE
//  NSRegularExpression pattern + a slotMap + a suggestedTriggerKeyword. The example is
//  cut into an alternating sequence of literal anchors (escaped verbatim, NO word
//  boundaries → Chinese works like English) and typed slot sub-patterns. Card digits
//  are wildcarded (\d{4}, non-capturing) so a same-row SMS from another card still
//  matches (GN-021 R1). suggestedTriggerKeyword = the longest literal anchor (for the
//  GN-026 "信息包含" automation filter). Users never see the regex.
//

import Foundation

/// Roles a slot can carry. Capturing roles fill a capture group; cardMask does not.
enum SlotRole: String, Codable { case currency, amount, merchant, cardMask, date }

struct CompiledTemplate {
    let pattern: String
    /// In capture-group order — only "capturing" roles appear here.
    let slotMap: [SlotRole]
    let suggestedTriggerKeyword: String?
}

enum SmsTemplateCompiler {
    /// Slot sub-pattern (capturing roles get parentheses; cardMask does not).
    private static func subPattern(for role: SlotRole) -> (regex: String, capturing: Bool) {
        switch role {
        case .amount:   return (#"([0-9][0-9.,]*[0-9]|[0-9])"#, true)
        case .currency: return (#"([A-Z]{3}|S\$|US\$|HK\$|A\$|RM|[€£¥₩฿$]|人民币|美元|令吉|新币|元)"#, true)
        case .merchant: return (#"(.+?)"#, true)
        case .date:
            // GN-028: a date-SHAPED capturing group, NOT the old loose `(\S+)`. The loose form
            // over-grabbed on space-less Chinese (e.g. "05月30日12:36在…" → grabbed past the
            // date). Shapes: numeric DD/MM[/YY[YY]] & YYYY-MM-DD (1–4 / 1–2 / 1–2 digit segs),
            // Chinese M月D日, and textual "30 May[ 2026]" / "May 30[, 2026]". CRITICAL: exactly
            // ONE outer capturing paren; every inner group is non-capturing `(?:)` — otherwise
            // numberOfRanges == slotMap.count+1 in the matcher breaks (Gotcha #1).
            return (#"((?:\d{1,4}(?:[/\-]\d{1,2}){2})|(?:\d{1,2}月\d{1,2}日)|(?:\d{1,2}\s[A-Za-z]{3,}(?:\s\d{2,4})?)|(?:[A-Za-z]{3,}\s\d{1,2}(?:,?\s\d{2,4})?))"#, true)
        case .cardMask: return (#"\d{4}"#, false)   // wildcard, non-capturing (multi-card same row)
        }
    }

    /// Date shapes that commonly sit INSIDE a literal anchor (not selected as a slot) yet
    /// VARY across messages of the same template: "30/05/26", "30/05/2026", "2026-05-30",
    /// and Chinese "05月30日". Anchored verbatim they would break a second message with a
    /// different date — the same class of dynamic-content problem the card-digit mask solves
    /// (GN-021 R1/R7, §1.4 "日期若也随卡变同样遮罩"). We auto-replace them with a
    /// non-capturing wildcard so the anchor stays a stable literal everywhere else.
    private static let datePatterns: [String] = [
        #"\d{1,4}[/\-]\d{1,2}[/\-]\d{1,4}"#,   // 30/05/26, 30/05/2026, 2026-05-30, 5-30-26
        #"\d{1,2}月\d{1,2}日"#,                 // 05月30日
    ]

    /// A wildcard tolerant of the digit/separator shapes in `datePatterns` (slashes, dashes, 月/日).
    /// Hoisted so the tail anchor (GN-052) can reuse the exact same wildcard the inter-slot
    /// anchors use.
    private static let dateWildcard = #"(?:\d{1,4}[/\-月]){1,2}\d{1,4}日?"#

    /// GN-053 — the same idea as `dateWildcard`, for a BARE run of digits (a running balance, a
    /// transaction reference, a queue number). It still REQUIRES a number in that position, so it
    /// bounds the merchant exactly as the literal digits did — it just stops pinning WHICH number.
    private static let digitWildcard = #"\d+"#

    /// Escape `anchor` for literal matching, but substitute any embedded date shape with a
    /// non-capturing date wildcard. The non-date text around it stays literally anchored.
    private static func escapedAnchorWithDateWildcards(_ anchor: String) -> String {
        // Find date spans (earliest-longest, non-overlapping) and rebuild: literal-escape the
        // gaps, drop in `\d{1,4}(?:[/\-月]\d{1,4}日?)*`-style wildcard for each date span.
        var dateRanges: [Range<String.Index>] = []
        for pat in datePatterns {
            guard let re = try? NSRegularExpression(pattern: pat) else { continue }
            for m in re.matches(in: anchor, range: NSRange(anchor.startIndex..., in: anchor)) {
                if let r = Range(m.range, in: anchor),
                   !dateRanges.contains(where: { $0.overlaps(r) }) {
                    dateRanges.append(r)
                }
            }
        }
        guard !dateRanges.isEmpty else { return NSRegularExpression.escapedPattern(for: anchor) }
        dateRanges.sort { $0.lowerBound < $1.lowerBound }
        var out = ""
        var cursor = anchor.startIndex
        for r in dateRanges {
            if cursor < r.lowerBound {
                out += NSRegularExpression.escapedPattern(for: String(anchor[cursor..<r.lowerBound]))
            }
            out += dateWildcard
            cursor = r.upperBound
        }
        if cursor < anchor.endIndex {
            out += NSRegularExpression.escapedPattern(for: String(anchor[cursor...]))
        }
        return out
    }

    /// example + user-confirmed spans (role+range) + whether to wildcard card digits → compile.
    /// spans need NOT include cardMask; when cardMask=true and the example contains
    /// "(ending|尾号)\s?\d{4}", those 4 digits are turned into a cardMask slot.
    static func compile(example: String, spans rawSpans: [(role: SlotRole, range: Range<String.Index>)],
                        cardMask: Bool) -> CompiledTemplate {
        var spans = rawSpans.sorted { $0.range.lowerBound < $1.range.lowerBound }
        // cardMask: insert the "(ending|尾号)\s?(\d{4})" 4-digit group as a cardMask slot
        // (only if it doesn't overlap an already-selected span).
        if cardMask {
            let cmRe = try! NSRegularExpression(pattern: #"(?:ending|尾号)\s?(\d{4})"#)
            if let m = cmRe.firstMatch(in: example, range: NSRange(example.startIndex..., in: example)),
               let r = Range(m.range(at: 1), in: example),
               !spans.contains(where: { $0.range.overlaps(r) }) {
                spans.append((.cardMask, r)); spans.sort { $0.range.lowerBound < $1.range.lowerBound }
            }
        }
        var pattern = ""
        var slotMap: [SlotRole] = []
        var anchors: [String] = []
        var cursor = example.startIndex
        var lastConsumed: SlotRole? = nil   // role of the last span actually consumed (for the tail-anchor decision)
        for s in spans {
            // Robustness: the spans may overlap or be out-of-order after the cardMask/date
            // insertions, OR come straight from the extractor's best-guesses (Phase C pre-fill),
            // whose anchors can overlap (e.g. a "merchant-before-amount" SMS where the `at `
            // merchant span runs past the amount/currency spans). A span whose lowerBound sits
            // BEFORE the running cursor would invert the `cursor..<lowerBound` slice and trap
            // ("Range requires lowerBound <= upperBound"). Drop any such overlapping span so the
            // compiler NEVER crashes; the dropped slot just isn't captured (Phase-C user
            // re-selection is the backstop — not-crashing is the goal here, not completeness).
            guard s.range.lowerBound >= cursor else { continue }
            let anchor = String(example[cursor..<s.range.lowerBound])
            if !anchor.isEmpty {
                // Pattern gets date-wildcarded anchor; keyword list keeps the RAW literal
                // (the trigger keyword must be text the SMS literally contains).
                pattern += escapedAnchorWithDateWildcards(anchor); anchors.append(anchor)
            }
            let sub = subPattern(for: s.role)
            pattern += sub.regex
            if sub.capturing { slotMap.append(s.role) }
            cursor = s.range.upperBound
            lastConsumed = s.role
        }
        // Tail anchor — ONLY when the last span is the merchant. The merchant slot is the
        // sole non-greedy `(.+?)`; left un-anchored at the end it collapses to a single char,
        // so it needs SOMETHING to stop against. GN-052 replaced the old ".prefix(40) verbatim"
        // rule with a minimal BOUNDARY anchor — see `tailAnchorPattern`.
        // For any OTHER trailing slot type (amount/currency/date) we append NO tail anchor:
        // those sub-patterns are self-delimiting (a bounded char class), and a literal tail
        // would over-fit — e.g. a Chinese SMS ending "…36.34元，余额1,234.56元。" would bake
        // the specific balance into the pattern and fail to match a message with another
        // balance. (suggestedTriggerKeyword still comes from the inter-slot anchors.)
        // (Use lastConsumed, not spans.last: a trailing merchant span can be DROPPED by the
        // overlap guard above, in which case the real trailing slot is an earlier role.)
        if lastConsumed == .merchant {
            pattern += tailAnchorPattern(after: String(example[cursor...]))
        }
        // GN-052: the tail anchor is deliberately NOT appended to `anchors` — it is a
        // delimiter, not a phrase, and the prose behind it is exactly the volatile text we
        // stopped baking in. Trigger keywords come from the INTER-SLOT anchors only.
        return CompiledTemplate(pattern: pattern, slotMap: slotMap,
                                suggestedTriggerKeyword: pickTriggerKeyword(from: anchors))
    }

    // MARK: - GN-052 tail anchor (bounds a TRAILING merchant slot)

    /// GN-052 — the boundary that stops a trailing merchant's non-greedy `(.+?)`.
    ///
    /// THE BUG THIS REPLACES: the old rule baked the 40 characters following the merchant into
    /// the pattern VERBATIM. For a real UOB SMS that was ". If unauthorised, call 24/7 Fraud
    /// Hotli" — truncated MID-WORD — so the template only matched messages whose fraud-warning
    /// clause was byte-identical AND wrapped at the same place. Reword the warning (or wrap the
    /// line differently) and the user's template silently stopped matching. That prose is the
    /// single most volatile part of a bank SMS; it must not be in the pattern at all.
    ///
    /// THE RULE: anchor the SHORTEST thing that genuinely terminates the merchant, and nothing
    /// beyond it.
    ///   1. Nothing follows the merchant  → `\s*$` (end of message — GN-025 A5.6: without this
    ///      the bare `(.+?)` captures ONE char, e.g. "BigSupermarket" → "B").
    ///   2. A punctuation/symbol terminator follows (the overwhelmingly common case: "." "," "，"
    ///      "—") → anchor up to and INCLUDING that terminator, and stop. Whitespace inside the
    ///      anchor is emitted as `\s+`, so space-vs-newline wrapping no longer matters.
    ///   3. Only whitespace follows → whitespace is NOT a terminator (merchants contain spaces;
    ///      `(.+?)\s` would cut "fp*Food Panda" at "fp*Food"), so anchor `\s+` plus the next
    ///      WHOLE word.
    ///   4. The merchant is glued straight to the following text (space-less CJK) → anchor that
    ///      following word, bounded.
    ///
    /// TRADE-OFF, deliberately taken: a merchant that itself contains the terminator (e.g.
    /// "7-ELEVEN PTE. LTD") can be captured short. That degrades a merchant NAME on a
    /// transaction that is still recorded with the right amount/currency/date — whereas
    /// over-fitting dropped the whole transaction. Under-matching is the expensive failure, so
    /// the boundary is kept minimal. Discrimination against OTHER banks' messages is the job of
    /// the inter-slot literal anchors ("A transaction of ", " was made with your UOB Card
    /// ending "), which are long, leading, and untouched by this change.
    private static func tailAnchorPattern(after rest: String) -> String {
        guard !rest.isEmpty else { return #"\s*$"# }
        let isTerminator: (Character) -> Bool = { $0.isPunctuation || $0.isSymbol }
        let delimRun = rest.prefix(while: { isTerminator($0) || $0.isWhitespace })

        // Case 2 — a real terminator in the leading delimiter run: anchor through the LAST one
        // and drop everything after it (that is the volatile prose).
        if let lastTerm = delimRun.lastIndex(where: isTerminator) {
            return whitespaceTolerantLiteral(String(delimRun[delimRun.startIndex...lastTerm]))
        }

        // Cases 3 & 4 — no terminator: anchor (optional whitespace +) the next whole word.
        let word = boundaryWordPattern(String(rest.drop(while: { $0.isWhitespace })))
        guard !word.isEmpty else { return #"\s*$"# }   // nothing but whitespace follows
        return (delimRun.isEmpty ? "" : #"\s+"#) + word
    }

    /// Escape `s` for literal matching but emit every whitespace RUN as `\s+`, so a message that
    /// wraps at a different place (single space vs. newline vs. ", \n") still matches.
    private static func whitespaceTolerantLiteral(_ s: String) -> String {
        var out = "", buf = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i].isWhitespace {
                if !buf.isEmpty { out += NSRegularExpression.escapedPattern(for: buf); buf = "" }
                out += #"\s+"#
                while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            } else {
                buf.append(s[i]); i = s.index(after: i)
            }
        }
        if !buf.isEmpty { out += NSRegularExpression.escapedPattern(for: buf) }
        return out
    }

    /// The next WHOLE word after the merchant, used only when no punctuation terminates it.
    /// A Latin word is kept intact — never cut mid-word, which is precisely what the old
    /// fixed-character budget did. A space-less CJK run is capped at 4 characters: every CJK
    /// character is its own morpheme, so a prefix is a clean cut there, and 4 is enough to bound
    /// the merchant without baking in a whole clause.
    private static func boundaryWordPattern(_ s: String) -> String {
        // A DATE immediately after the merchant ("… at NTUC FairPrice 18/07/26 approved") must
        // become the date WILDCARD, never a literal. Splitting it as a "word" would stop at the
        // first separator and bake in the day-of-month ("\s+18"), so the template would only ever
        // match messages from that same day — the very over-fitting GN-052 exists to remove. The
        // inter-slot anchors have always wildcarded embedded dates (escapedAnchorWithDateWildcards);
        // this keeps the tail consistent with them.
        for pat in datePatterns {
            guard let re = try? NSRegularExpression(pattern: "^(?:" + pat + ")") else { continue }
            if re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                return dateWildcard
            }
        }
        let run = s.prefix(while: { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol })
        guard !run.isEmpty else { return "" }

        // GN-053 — the word may itself be VOLATILE. The date case above is not the only kind of
        // changeable token that can sit right after a merchant: a running BALANCE ("…FairPrice
        // 余额12345.67元") or a transaction REFERENCE ("…GRAB 8891234") does too, and anchoring it
        // verbatim baked the digits in (measured: `(.+?)余额12`, `(.+?)\s+8891234`). The very next
        // message — same bank, same format, different balance — then failed to match. So: keep the
        // STABLE, non-numeric head of the word as the anchor, and never the digits after it.
        //   "余额12345"  → 余额        (the label bounds the merchant; the sum is noise)
        //   "Ref8891234" → Ref
        //   "8891234"    → \d+         (no stable head at all → require A number, not THAT number)
        //
        // ★ BE PRECISE ABOUT THE DIRECTION: this DOES widen what matches, deliberately, along the
        // volatile-digit axis. `余额12` → `余额` now accepts any balance; `8891234` → `\d+` now
        // accepts any reference number. That widening IS the fix — "the next message must match"
        // is the whole requirement, and it cannot be met without accepting inputs the old pattern
        // rejected. What it does NOT do is remove the boundary: a literal head still has to be
        // there, and where there is no head a number is still REQUIRED in that position, so the
        // merchant capture stays bounded. Narrowing happens only in what gets BAKED IN (the
        // specific digits); the match set grows. Anyone reviewing a tail-anchor change should be
        // reading for "did the boundary survive", not for "did nothing get looser".
        //
        // Both ASCII and FULL-WIDTH digits count as volatile: `余额１２３４５元` is the same
        // message in a different encoding, and treating ０-９ (U+FF10–FF19) as stable text baked
        // `余额１２` in exactly as the ASCII form once did. Other characters that report
        // `isNumber` are NOT volatile — CJK numerals and enclosed forms (二, 十, ㊈) are ordinary
        // morphemes of a stable word, and cutting there would shorten a perfectly good anchor.
        // (`digitWildcard` is `\d+`, and ICU's `\d` spans Unicode Nd, so it matches both widths.)
        //
        // Known and accepted: a word whose very first character is a digit collapses to `\d+`,
        // and a word that is digit-broken early keeps only its short head ("A1B2C3" → `\s+A`,
        // "第3季度报表" → `\s+第`). A one-character anchor is weak but still a boundary, and it is
        // strictly better than baking in a number that changes on the next message.
        let isVolatileDigit: (Character) -> Bool = { c in
            c.isNumber && (c.isASCII || ("\u{FF10}"..."\u{FF19}").contains(c))
        }
        let head = run.prefix(while: { !isVolatileDigit($0) })
        guard !head.isEmpty else { return digitWildcard }

        // (`head` is digit-free by construction, so "Latin word" here means ASCII letters. A CJK
        // run is still capped at 4 — each character is its own morpheme, so a prefix is a clean cut.)
        let isLatinWord = head.allSatisfy { $0.isASCII && $0.isLetter }
        return NSRegularExpression.escapedPattern(for: isLatinWord ? String(head)
                                                                   : String(head.prefix(4)))
    }

    // MARK: - GN-052 trigger keyword (for the GN-026「信息包含」automation filter)

    /// GN-052 — pick the「信息包含」trigger keyword from the INTER-SLOT literal anchors.
    ///
    /// THE BUG THIS REPLACES: the keyword used to be simply the LONGEST anchor — and because the
    /// old 40-character tail was itself an anchor, the longest was usually that volatile,
    /// mid-word-truncated fraud-warning fragment (". If unauthorised, call 24/7 Fraud Hotli").
    /// The user pasted THAT into their Messages automation filter, so the automation missed any
    /// reworded message and the whole chain looked broken.
    ///
    /// THE RULE: the EARLIEST anchor that is discriminative on its own — ≥12 characters for a
    /// mostly-ASCII anchor, ≥4 for CJK (which packs far more meaning per character) — else the
    /// longest anchor available. Earliest wins because the LEADING phrase of a bank SMS ("A
    /// transaction of", "您尾号…的招行卡于") is its most stable identifying text, while the tail
    /// is the part banks reword. The result is always whole words: anchors END where a slot
    /// begins, and the length cap backs off to a whitespace boundary.
    private static func pickTriggerKeyword(from anchors: [String]) -> String? {
        let trimmed = anchors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                             .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return nil }
        let isDiscriminative: (String) -> Bool = { s in
            s.count >= (s.allSatisfy { $0.isASCII } ? 12 : 4)
        }
        let chosen = trimmed.first(where: isDiscriminative)
            ?? trimmed.max(by: { $0.count < $1.count })!
        return capOnWordBoundary(chosen, max: 40)
    }

    /// Cap `s` at `max` characters WITHOUT cutting a word: back off to the last whitespace.
    /// (A CJK run has no whitespace to back off to; each character is a morpheme, so a plain
    /// prefix is already a clean cut there.)
    private static func capOnWordBoundary(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let head = String(s.prefix(max))
        if let lastSpace = head.lastIndex(where: { $0.isWhitespace }) {
            let cut = String(head[head.startIndex..<lastSpace])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cut.isEmpty { return cut }
        }
        return head
    }
}
