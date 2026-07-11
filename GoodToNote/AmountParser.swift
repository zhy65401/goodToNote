//
//  AmountParser.swift
//  GoodToNote
//
//  GN-025 (Phase A) — Number-run string → Decimal with thousand/decimal-separator
//  disambiguation. Region/language-agnostic (per GN-021 §1.2): we do NOT trust the
//  device locale; we decide which of '.' / ',' is the decimal point from the string's
//  own shape, then feed the normalized "dot-decimal" string through en_US_POSIX.
//
//  Rules:
//   - Both '.' and ',' present → whichever appears LAST is the decimal separator; the
//     other is the grouping separator (handles "1,234.56" and "1.234,56" both → 1234.56).
//   - Single separator appearing once with exactly 3 trailing digits → grouping ("1,234"→1234).
//   - Single separator appearing more than once → grouping ("1,234,567"→1234567).
//   - Otherwise (1–2 trailing digits) → decimal ("12,50"→12.50).
//   - Must yield a positive Decimal, else nil.
//

import Foundation

enum AmountParser {
    /// Number string (may contain '.' / ',' as thousand/decimal separators) → positive
    /// Decimal, or nil if unparseable. Locale/region-independent.
    static func parse(_ s: String) -> Decimal? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.contains(where: { $0.isNumber }) else { return nil }
        let hasDot = t.contains("."), hasComma = t.contains(",")
        var normalized = t
        if hasDot && hasComma {
            // The separator occurring LAST is the decimal point; the other is grouping.
            let lastDot = t.lastIndex(of: "."), lastComma = t.lastIndex(of: ",")
            let decimalSep: Character = (lastDot! > lastComma!) ? "." : ","
            let groupSep: Character = decimalSep == "." ? "," : "."
            normalized = t.replacingOccurrences(of: String(groupSep), with: "")
                          .replacingOccurrences(of: String(decimalSep), with: ".")
        } else if hasComma || hasDot {
            let sep: Character = hasComma ? "," : "."
            let parts = t.split(separator: sep, omittingEmptySubsequences: false)
            let occurrences = t.filter { $0 == sep }.count
            // Single occurrence with exactly 3 trailing digits → grouping; multiple
            // occurrences → grouping; otherwise (1–2 trailing) → decimal.
            if occurrences == 1, let last = parts.last, last.count == 3 {
                normalized = t.replacingOccurrences(of: String(sep), with: "")     // grouping
            } else if occurrences > 1 {
                normalized = t.replacingOccurrences(of: String(sep), with: "")     // grouping
            } else {
                normalized = t.replacingOccurrences(of: String(sep), with: ".")    // decimal
            }
        }
        guard let d = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), d > 0
        else { return nil }
        return d
    }
}
