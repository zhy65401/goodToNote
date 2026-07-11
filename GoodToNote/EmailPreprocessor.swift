//
//  EmailPreprocessor.swift
//  GoodToNote
//
//  GN-039 (Task 2) — THE core of the email path. A bank transaction email arrives (via the user's
//  iOS「邮件 / Email」personal automation) as a LONG, usually-HTML body: tables, inline styles,
//  tracking pixels, marketing footers, multi-language boilerplate. Feeding that raw into the SMS
//  engine breaks BOTH ends:
//    • SmsTokenizer cuts every CJK char + every HTML symbol (< > = " / & ;) into its own token →
//      a few-hundred-char HTML email explodes into HUNDREDS-to-THOUSANDS of chips, drowning the
//      tap-to-annotate UI (GN-038 §3.3, the承重 risk).
//    • SmsTemplateCompiler builds literal anchors from the example; HTML attributes/whitespace
//      vary email-to-email (dynamic amounts, A/B templates) → anchors built on HTML structure
//      fail to match real incoming mail (GN-038 §3.1).
//
//  So this preprocessor PRE-SHRINKS a long email into a SHORT "key segment" — the line(s) that
//  carry a money signal plus a little surrounding context — on STABLE PLAIN TEXT. After that, the
//  EXISTING engine + annotation UI are reused almost verbatim. Two phases, both pure Foundation
//  (no NSAttributedString — that needs MainActor and is slow/unstable; a hand-written strip is
//  deterministic, off-actor, and unit-testable in a bare swiftc harness):
//
//    1) htmlToPlainText: drop <script>/<style> blocks, turn <br>/<p>/<tr>/<li>/<div>/<table>…
//       boundaries into newlines, strip all remaining tags, decode the common HTML entities
//       (&amp; &lt; &gt; &quot; &#39; &nbsp; &#NNN; &#xHH;), then collapse runs of spaces/blank
//       lines so the result is compact, readable plain text with meaningful line boundaries.
//
//    2) keySegment: scan the plain-text LINES for a "money signal" (a currency symbol $ € ¥ £ ₩ ฿
//       or RM/S$/US$…, OR a 3-letter ISO code adjacent to digits, OR a decimal-amount shape like
//       12.34 / 1,234.56), keep every matching line plus `contextLines` lines of context on each
//       side, MERGE overlapping/adjacent windows, and join. NO match → fall back to the first
//       `fallbackLines` non-empty lines (truncated, never dropped — 宁多勿漏: missing the amount
//       line means the user can't annotate it).
//
//  CRITICAL invariant (GN-038 §3.1 / spec Task 2 Gotcha): the SAME `process()` must run at
//  TEMPLATE-BUILD time (SmsTemplateEditorView email mode) AND at RUNTIME (IngestEmailIntent), or
//  the literal anchors compiled from the build-time segment won't match the runtime segment.
//  `process` is deterministic + locale-independent for exactly this reason.
//

import Foundation

enum EmailPreprocessor {

    /// Full pipeline: raw email body (HTML or plain text) → short key segment ready for the SMS
    /// engine / annotation UI. Deterministic; safe to call off the main actor. Use the SAME call
    /// at build time and at runtime (see the file header invariant).
    /// - Parameters:
    ///   - rawEmail: the email body as delivered (Shortcut Input "Get Text from Input"); HTML or
    ///     plain. nil-safe at the call site (callers pass "" for empty).
    ///   - contextLines: lines of context kept on EACH side of a money-signal line (default 2).
    ///   - fallbackLines: when NO money signal is found, how many leading non-empty lines to keep
    ///     (default 12) so nothing is silently dropped.
    static func process(_ rawEmail: String,
                        contextLines: Int = 2,
                        fallbackLines: Int = 12) -> String {
        let plain = htmlToPlainText(rawEmail)
        return keySegment(plain, contextLines: contextLines, fallbackLines: fallbackLines)
    }

    // MARK: - Phase 1: HTML → plain text

    /// Strip HTML to compact plain text: remove script/style, convert block-level tag boundaries to
    /// newlines, drop remaining tags, decode common entities, collapse whitespace. If the input has
    /// no tags at all (a true text/plain email) it is only whitespace-normalized. Pure + deterministic.
    static func htmlToPlainText(_ raw: String) -> String {
        var s = raw

        // 1) Remove <script>…</script> and <style>…</style> wholesale (their contents are not text).
        s = removeBlocks(s, tag: "script")
        s = removeBlocks(s, tag: "style")
        // HTML comments <!-- … --> (may hide conditional MSO markup) — drop them.
        s = replaceRegex(s, pattern: "<!--.*?-->", with: "")

        // 2) Turn block-level / line-break boundaries into newlines so lines stay meaningful AFTER
        //    tag removal (a bank's amount usually sits in its own <td>/<p>/<div>). We insert a
        //    newline BEFORE stripping the tag itself. Order-independent (each adds a '\n').
        //    <br>, </p>, </div>, </tr>, </li>, </h1..6>, </table>, </h*>, </ul>, </ol>, closing block tags.
        let breakTags = ["br", "/p", "/div", "/tr", "/td", "/li", "/ul", "/ol",
                         "/table", "/h1", "/h2", "/h3", "/h4", "/h5", "/h6",
                         "/blockquote", "p", "div", "tr", "li", "table"]
        for t in breakTags {
            // Match "<t", "<t>", "<t ...attrs...>", "<t/>" case-insensitively.
            s = replaceRegex(s, pattern: "<\\s*" + NSRegularExpression.escapedPattern(for: t) + "(\\s[^>]*)?/?>",
                             with: "\n", options: [.caseInsensitive])
        }

        // 3) Strip every remaining tag.
        s = replaceRegex(s, pattern: "<[^>]+>", with: "")

        // 4) Decode common HTML entities (named + numeric decimal + numeric hex).
        s = decodeEntities(s)

        // 5) Collapse whitespace: tabs / non-breaking residue → space; runs of spaces → one space;
        //    trim each line; drop runs of blank lines down to a single blank separator.
        return normalizeWhitespace(s)
    }

    /// Remove `<tag …>…</tag>` blocks (case-insensitive, across newlines). Used for script/style.
    private static func removeBlocks(_ s: String, tag: String) -> String {
        let esc = NSRegularExpression.escapedPattern(for: tag)
        return replaceRegex(s, pattern: "<\\s*" + esc + "[^>]*>.*?<\\s*/\\s*" + esc + "\\s*>",
                            with: " ", options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    /// Decode the HTML entities that actually show up in bank emails. Order: numeric (dec + hex)
    /// first (so a literal "&amp;#39;" edge case still resolves the inner one after), then named.
    /// &nbsp; → normal space (it later collapses); &amp; LAST so we don't double-decode.
    static func decodeEntities(_ input: String) -> String {
        var s = input
        // Numeric decimal: &#160; &#39; …
        s = replaceRegexByMatch(s, pattern: "&#([0-9]{1,7});") { groups in
            guard let code = UInt32(groups[1]), let scalar = Unicode.Scalar(code) else { return nil }
            return String(Character(scalar))
        }
        // Numeric hex: &#x27; &#xA0; …
        s = replaceRegexByMatch(s, pattern: "&#[xX]([0-9A-Fa-f]{1,6});") { groups in
            guard let code = UInt32(groups[1], radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
            return String(Character(scalar))
        }
        // Named — the common set in transactional email. &nbsp; → space.
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&#39;", "'"), ("&middot;", "·"), ("&bull;", "•"),
            ("&ndash;", "–"), ("&mdash;", "—"), ("&hellip;", "…"),
            ("&pound;", "£"), ("&euro;", "€"), ("&yen;", "¥"), ("&cent;", "¢"),
            ("&dollar;", "$"), ("&trade;", "™"), ("&reg;", "®"), ("&copy;", "©"),
        ]
        for (ent, rep) in named { s = s.replacingOccurrences(of: ent, with: rep) }
        // &amp; LAST (so an entity like &amp;nbsp; first became &nbsp; above only if literally
        // present; standard decoding does amp last to avoid turning &amp;lt; into <).
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        return s
    }

    /// Collapse horizontal whitespace, trim each line, and squeeze blank-line runs to one.
    static func normalizeWhitespace(_ s: String) -> String {
        // Normalize CRLF / CR → LF first.
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
                 .replacingOccurrences(of: "\r", with: "\n")
        // Replace NBSP (U+00A0), zero-width space (U+200B) + tabs with a normal space.
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")
             .replacingOccurrences(of: "\u{200B}", with: " ")
             .replacingOccurrences(of: "\t", with: " ")
        // Per-line: collapse internal space runs to one, trim ends.
        let lines = t.components(separatedBy: "\n").map { line -> String in
            let collapsed = replaceRegex(line, pattern: " {2,}", with: " ")
            return collapsed.trimmingCharacters(in: .whitespaces)
        }
        // Drop consecutive blank lines (keep at most one as a separator), and trim leading/trailing blanks.
        var out: [String] = []
        var lastBlank = false
        for line in lines {
            let isBlank = line.isEmpty
            if isBlank && lastBlank { continue }
            out.append(line)
            lastBlank = isBlank
        }
        while out.first?.isEmpty == true { out.removeFirst() }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    // MARK: - Phase 2: key-segment extraction

    /// A line "carries a money signal" if it contains a currency symbol, an ISO code adjacent to
    /// digits, or a decimal-amount shape. Used to pick which plain-text lines to keep.
    static func lineHasMoneySignal(_ line: String) -> Bool {
        if line.isEmpty { return false }
        // 1) Currency SYMBOL anywhere (covers $, €, £, ¥, ₩, ฿, ¢ and the multi-char S$/US$/RM/HK$/A$
        //    via the symbol set below). A bare symbol near digits is the strongest signal.
        for sym in moneySymbols where line.contains(sym) {
            // Require a digit somewhere on the line so a footer "$" logo alone doesn't trip it.
            if line.rangeOfCharacter(from: .decimalDigits) != nil { return true }
        }
        // 2) ISO 4217 three-letter code adjacent to a number, e.g. "SGD 36.34", "36.34 USD".
        //    Validate against the known catalog so a random 3-letter run (e.g. "PDF") is ignored.
        if let codeRe = isoAdjacentRegex {
            let ns = line as NSString
            for m in codeRe.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                // group 1 is whichever side captured the 3-letter code.
                for gi in 1..<m.numberOfRanges {
                    let r = m.range(at: gi)
                    if r.location != NSNotFound {
                        let code = ns.substring(with: r).uppercased()
                        if isoSet.contains(code) { return true }
                    }
                }
            }
        }
        // 3) Decimal-amount shape: 12.34 or 1,234.56 (two decimal places — the canonical money
        //    shape). Broad enough to catch amounts without a visible currency token on that line.
        if amountShapeRegex?.firstMatch(in: line,
                                        range: NSRange(location: 0, length: (line as NSString).length)) != nil {
            return true
        }
        return false
    }

    /// Extract the key segment from plain text: keep each money-signal line ± contextLines of
    /// CONTENT (non-blank) lines, merge overlapping windows, join with newlines. No signal → first
    /// `fallbackLines` content lines (fallback, never dropped).
    ///
    /// Context is counted in CONTENT lines, NOT raw lines, on purpose: HTML tables render one
    /// <td> per line with blank separators between rows (our own block-tag→newline artifact), so a
    /// raw ±N window would burn its budget on blank lines and miss the merchant value that sits a
    /// couple of CELLS away from the amount cell. Counting real content lines makes "前后各 1-2 行"
    /// mean 1-2 lines of actual text (e.g. amount line → blank → "Merchant:" → blank → "LAZADA"
    /// is 2 content lines away, so ±2 keeps the merchant). 宁多勿漏 (spec Task 2 Gotcha).
    static func keySegment(_ plain: String, contextLines: Int, fallbackLines: Int) -> String {
        // Work over CONTENT (non-blank) lines only — drops the blank artifacts entirely.
        let content = plain.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !content.isEmpty else { return "" }

        // Indices (into `content`) of money-signal lines.
        var hitIdx: [Int] = []
        for (i, line) in content.enumerated() where lineHasMoneySignal(line) { hitIdx.append(i) }

        if hitIdx.isEmpty {
            // Fallback: first N content lines (truncated). Never drop the email entirely.
            return content.prefix(fallbackLines).joined(separator: "\n")
        }

        // Build context windows [i-ctx, i+ctx] clamped, then merge overlapping/adjacent ones.
        var windows: [(lo: Int, hi: Int)] = hitIdx.map {
            (max(0, $0 - contextLines), min(content.count - 1, $0 + contextLines))
        }
        windows.sort { $0.lo < $1.lo }
        var merged: [(lo: Int, hi: Int)] = []
        for w in windows {
            if var last = merged.last, w.lo <= last.hi + 1 {
                last.hi = max(last.hi, w.hi)
                merged[merged.count - 1] = last
            } else {
                merged.append(w)
            }
        }

        // Collect the kept content lines in order; insert a blank separator between non-contiguous
        // windows so distinct key regions remain visually grouped for annotation.
        var out: [String] = []
        for (wi, w) in merged.enumerated() {
            if wi > 0 { out.append("") }   // visual gap between separate key regions
            for i in w.lo...w.hi { out.append(content[i]) }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Money signal tables / regexes

    /// Currency symbols recognized on a line. Multi-char first so "S$" wins over "$" when scanning
    /// `contains` (order is irrelevant for `contains`, but kept consistent with SmsExtractor).
    static let moneySymbols: [String] = [
        "S$", "US$", "HK$", "A$", "RM", "$", "€", "£", "¥", "₩", "฿", "¢",
        // native-word money tokens that also signal an amount line
        "人民币", "新币", "美元", "令吉", "元",
    ]

    /// ISO codes we trust (the app's catalog). Computed once.
    static let isoSet: Set<String> = Set(CurrencyCatalog.all)

    /// A 3-letter ISO code immediately adjacent to a number (either side). group1 = code-before,
    /// group2 = code-after; validated against isoSet by the caller.
    static let isoAdjacentRegex: NSRegularExpression? = {
        // "ABC 123" / "ABC123"  OR  "123 ABC" / "123ABC"
        try? NSRegularExpression(
            pattern: "(?:\\b([A-Za-z]{3})\\s*[0-9])|(?:[0-9][0-9.,]*\\s*([A-Za-z]{3})\\b)")
    }()

    /// Canonical money amount shape: 1,234.56 or 12.34 (a thousands-grouped or plain number with
    /// exactly two decimals). Deliberately specific to "money" so prose decimals are less likely
    /// to false-positive, while still catching the amount line宁多勿漏.
    static let amountShapeRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "[0-9]{1,3}(?:,[0-9]{3})+\\.[0-9]{2}|[0-9]+\\.[0-9]{2}")
    }()

    // MARK: - Regex helpers (pure Foundation)

    private static func replaceRegex(_ s: String, pattern: String, with template: String,
                                     options: NSRegularExpression.Options = []) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        let range = NSRange(location: 0, length: (s as NSString).length)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    /// Replace each match using a closure over its capture groups (group 0 = whole match). If the
    /// closure returns nil, the original matched text is kept. Iterates back-to-front so ranges
    /// stay valid while mutating.
    private static func replaceRegexByMatch(_ s: String, pattern: String,
                                            _ transform: ([String]) -> String?) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = NSMutableString(string: s)
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            var groups: [String] = []
            for gi in 0..<m.numberOfRanges {
                let r = m.range(at: gi)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            if let rep = transform(groups) {
                ns.replaceCharacters(in: m.range(at: 0), with: rep)
            }
        }
        return ns as String
    }
}
