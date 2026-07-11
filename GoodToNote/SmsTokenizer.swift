//
//  SmsTokenizer.swift
//  GoodToNote
//
//  GN-029 短信模版标注 UI 重做(token 点选高亮) — pure-function tokenizer that cuts raw SMS
//  text into an ordered list of tokens, each carrying its original String.Index range. It is
//  the foundation of the rewritten SmsTemplateEditorView confirm screen: the user picks a
//  category "brush" then taps tokenized words to highlight them; tapping yields a PRECISE
//  character range (the token's own range), which is strictly better than the old
//  range(of:)-first-occurrence span derivation.
//
//  Task-status connection: the engine (DateParser/AmountParser/SmsExtractor/Compiler/Matcher)
//  is DONE + green (57/57). This file adds ONLY the new token model the rewritten confirm UI
//  needs; the compiler still consumes [(role, range)] spans — those ranges now come from the
//  tokens selected here. No SwiftData, no engine deps → unit-testable in a plain swiftc harness.
//
//  Tokenization rules (pinned by GN-029_tokenizer_test.swift):
//   - ASCII letter run [A-Za-z]+              → .word
//   - Number run: starts AND ends on an ASCII digit, may contain . , / : - in the MIDDLE
//     (36.34, 1,234.56, 30/05/26, 12:36 stay whole); a trailing separator is NOT swallowed
//     (it becomes its own .symbol — "26." → number "26" + symbol ".")     → .number
//   - CJK character (per char)                → .cjk
//   - Whitespace run (not selectable)         → .space
//   - Any other single character              → .symbol
//   Ranges contiguously cover the WHOLE string (joining every token's text == the original).
//

import Foundation

/// One token of tokenized SMS text. `range` indexes back into the ORIGINAL string the token
/// came from; `id` is the token's position in the ordered list (0-based, contiguous).
struct SmsToken: Identifiable, Equatable {
    let id: Int
    let text: String
    let range: Range<String.Index>
    let kind: Kind
    enum Kind { case word, number, cjk, symbol, space }
    /// Spaces are layout-only; everything else is a tappable chip in the editor.
    var isSelectable: Bool { kind != .space }
}

enum SmsTokenizer {
    /// Cut `text` into ordered tokens whose ranges contiguously cover the whole string.
    /// See the rules in the file header. Pure function — deterministic, no locale dependence.
    static func tokenize(_ text: String) -> [SmsToken] {
        var tokens: [SmsToken] = []
        var idx = 0
        var i = text.startIndex

        func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
        func isLetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }
        func isNumSep(_ c: Character) -> Bool { ".,/:-".contains(c) }
        func isCJK(_ c: Character) -> Bool {
            c.unicodeScalars.contains {
                (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
            }
        }
        func emit(_ kind: SmsToken.Kind, _ start: String.Index, _ end: String.Index) {
            tokens.append(SmsToken(id: idx, text: String(text[start..<end]), range: start..<end, kind: kind))
            idx += 1
        }

        while i < text.endIndex {
            let c = text[i]
            if c.isWhitespace {
                var j = i
                while j < text.endIndex && text[j].isWhitespace { j = text.index(after: j) }
                emit(.space, i, j); i = j
            } else if isLetter(c) {
                var j = i
                while j < text.endIndex && isLetter(text[j]) { j = text.index(after: j) }
                emit(.word, i, j); i = j
            } else if isDigit(c) {
                // Greedily consume digits + interior separators, then back off any trailing
                // non-digit so the number is digit-bounded ("26." → "26" + the "." re-scanned
                // as a symbol next iteration; "12:36" / "1,234.56" stay whole).
                var j = i
                while j < text.endIndex && (isDigit(text[j]) || isNumSep(text[j])) { j = text.index(after: j) }
                var end = j
                while end > i {
                    let prev = text.index(before: end)
                    if isDigit(text[prev]) { break }
                    end = prev
                }
                emit(.number, i, end); i = end
            } else if isCJK(c) {
                let j = text.index(after: i)
                emit(.cjk, i, j); i = j
            } else {
                let j = text.index(after: i)
                emit(.symbol, i, j); i = j
            }
        }
        return tokens
    }
}
