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
        // A wildcard tolerant of the digit/separator shapes above (slashes, dashes, 月/日).
        let dateWildcard = #"(?:\d{1,4}[/\-月]){1,2}\d{1,4}日?"#
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
        // sole greedy `(.+?)`; left un-anchored at the end it collapses to a single char, so
        // it needs a trailing literal (e.g. ". If unauthorised") to stop against. We take
        // the text after the merchant up to the first newline, capped at 40 chars, verbatim
        // (leading punctuation included — it is part of the fixed warning clause these
        // templates share, so it generalizes across same-type messages).
        // For any OTHER trailing slot type (amount/currency/date) we append NO tail anchor:
        // those sub-patterns are self-delimiting (a bounded char class), and a literal tail
        // would over-fit — e.g. a Chinese SMS ending "…36.34元，余额1,234.56元。" would bake
        // the specific balance into the pattern and fail to match a message with another
        // balance. (suggestedTriggerKeyword still comes from the inter-slot anchors.)
        // (Use lastConsumed, not spans.last: a trailing merchant span can be DROPPED by the
        // overlap guard above, in which case the real trailing slot is an earlier role.)
        if lastConsumed == .merchant {
            let tailFull = String(example[cursor...])
            let tail = String(tailFull.prefix(while: { $0 != "\n" }).prefix(40))
            if !tail.isEmpty {
                pattern += escapedAnchorWithDateWildcards(tail); anchors.append(tail)
            } else {
                // No tail anchor (merchant is the last span and nothing follows it on the line).
                // Left bare, the merchant's non-greedy `(.+?)` collapses to a single char on a
                // second message ("BigSupermarket" → "B"). Anchor it to end-of-line so it
                // captures the WHOLE merchant. We append `$` (works with .dotMatchesLineSeparators:
                // `$` still means end-of-string/line and is unaffected by the dot-mode flag).
                pattern += "$"
            }
        }
        let keyword = anchors.max(by: {
            $0.trimmingCharacters(in: .whitespaces).count < $1.trimmingCharacters(in: .whitespaces).count
        })?.trimmingCharacters(in: .whitespaces)
        return CompiledTemplate(pattern: pattern, slotMap: slotMap, suggestedTriggerKeyword: keyword)
    }
}
