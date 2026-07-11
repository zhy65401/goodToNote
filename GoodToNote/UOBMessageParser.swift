//
//  UOBMessageParser.swift
//  GoodToNote
//
//  GN-005 — Parses a UOB transaction-alert SMS into a structured transaction.
//  ONLY recognizes the one fixed UOB card-transaction template (user-provided 2026-05-31);
//  any other text (UOB OTP / promo / arbitrary strings / empty) → nil, so the caller
//  (IngestUOBMessageIntent) silently ignores it and writes nothing. Designed to be
//  extensible: more banks become more parsers behind the same `parse` shape later.
//
//  Fixed template:
//   "A transaction of {CUR} {AMT} was made with your UOB Card ending {LAST4}
//    on {DD/MM/YY} at {MERCHANT}. If unauthorised, ..."
//
//  Merchant: text after "at " up to ". If unauthorised". Channel prefix (e.g. "fp*",
//  "GRB*") is stripped for DISPLAY only; the RAW merchant string is kept as the stable
//  merchant-memory key (GN-005 ③/⑤).
//

import Foundation

/// Structured result of a recognized UOB transaction SMS. nil from `parse` = not a target SMS.
struct ParsedUOBTransaction: Equatable {
    let currencyCode: String
    let amount: Decimal
    let cardLast4: String
    let date: Date
    /// Raw merchant string as it appears after "at " (channel prefix kept). Memory key.
    let merchantRaw: String
    /// Merchant with leading `alphanumerics + *` channel prefix stripped. For display.
    let merchantDisplay: String
}

enum UOBMessageParser {
    // Anchored to the fixed UOB template. Capture groups:
    //  1 currency (ISO letters), 2 amount (digits + dot), 3 last4, 4 date DD/MM/YY,
    //  5 merchant (non-greedy up to ". If unauthorised").
    private static let pattern =
        #"A transaction of ([A-Za-z]{3}) ([0-9]+(?:\.[0-9]+)?) was made with your UOB Card ending (\d{4}) on (\d{2}/\d{2}/\d{2}) at (.+?)\. If unauthorised"#

    private static let regex = try? NSRegularExpression(pattern: pattern, options: [])

    /// DD/MM/YY → Date. Fixed POSIX locale so it's input-, not device-, dependent.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd/MM/yy"
        f.timeZone = TimeZone(identifier: "Asia/Singapore") ?? .current
        return f
    }()

    /// Parse a UOB transaction SMS. Returns nil for any non-matching text (ignored).
    static func parse(_ text: String) -> ParsedUOBTransaction? {
        guard let regex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range),
              m.numberOfRanges == 6 else { return nil }

        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            return String(text[r])
        }

        guard let cur = group(1), let amtStr = group(2), let last4 = group(3),
              let dateStr = group(4), let merchantRaw = group(5) else { return nil }

        // Amount must parse as a positive Decimal (POSIX-style decimal point).
        guard let amount = Decimal(string: amtStr, locale: Locale(identifier: "en_US_POSIX")),
              amount > 0 else { return nil }

        guard let date = dateFormatter.date(from: dateStr) else { return nil }

        let rawTrimmed = merchantRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTrimmed.isEmpty else { return nil }

        return ParsedUOBTransaction(
            currencyCode: cur.uppercased(),
            amount: amount,
            cardLast4: last4,
            date: date,
            merchantRaw: rawTrimmed,
            merchantDisplay: displayName(from: rawTrimmed)
        )
    }

    /// Strip a leading channel prefix `^[A-Za-z0-9]+\*` (e.g. "fp*", "GRB*") and trim.
    static func displayName(from raw: String) -> String {
        let stripped = raw.replacingOccurrences(
            of: #"^[A-Za-z0-9]+\*"#,
            with: "",
            options: .regularExpression
        )
        let result = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? raw : result
    }
}
