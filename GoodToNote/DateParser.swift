//
//  DateParser.swift
//  GoodToNote
//
//  GN-028 短信日期识别增强 (Task 1) — Pure-function multi-format date parser: a date
//  STRING lifted from an SMS → Date, or nil if no known format matches. Offline, no ML,
//  language-agnostic (mirrors the GN-025 engine philosophy). Used by SmsTemplateMatcher's
//  .date slot (runtime) and by SmsExtractor's best-date pick (auto-detect).
//
//  Design (locked with the user 2026-06-13):
//    • DD/MM is the DEFAULT (user is in Singapore / most of the world). So "05/06/26" is
//      05 June, not May 6. ISO (4-digit-year-leading, e.g. "2026-05-30") is detected FIRST
//      so a leading 4-digit year is never misread as a day.
//    • Year-less formats ("05月30日", "30 May", "May 30") adopt the CURRENT year. `now` is
//      injectable so tests are deterministic (DateFormatter otherwise defaults such dates
//      to year 1900/2000, which we override to now's year).
//    • Failure → nil. The runtime caller falls back to .now (the SMS arrival time) and never
//      drops a transaction (GN-025 "never lose a txn" principle).
//
//  Asia/Singapore time zone + en_US_POSIX locale keep parsing deterministic regardless of
//  device locale (e.g. month-name parsing, and which calendar day a midnight maps to).
//

import Foundation

enum DateParser {
    /// Fixed parse tz so "05月30日" lands on the same calendar day everywhere; falls back to
    /// .current only if the identifier is somehow unavailable.
    private static let tz = TimeZone(identifier: "Asia/Singapore") ?? .current

    /// A non-lenient DateFormatter for `pattern` (en_US_POSIX so month names + separators are
    /// parsed literally, not by the device locale). Non-lenient so partial garbage is rejected.
    private static func fmt(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = pattern
        f.isLenient = false
        return f
    }

    // Format groups. DD/MM default (Singapore).
    // Numeric: `yy` patterns FIRST. A non-lenient `yyyy` formatter mis-reads a 2-digit year
    // ("30/05/26" → year 26 AD, not 2026), whereas a `yy` formatter correctly pivots a 2-digit
    // year to 2026 AND still accepts a literal 4-digit year ("30/05/2026" → 2026). So `yy` first
    // handles both 2- and 4-digit years; the `yyyy` variants stay as a backstop. (Year-less
    // textual/Chinese formats live in their own groups, after the year-bearing ones there.)
    private static let numeric = ["dd/MM/yy", "d/M/yy", "dd/MM/yyyy", "d/M/yyyy",
                                  "dd-MM-yy", "d-M-yy", "dd-MM-yyyy", "d-M-yyyy"]
    private static let iso     = ["yyyy-MM-dd", "yyyy/MM/dd"]
    private static let chinese = ["yyyy年M月d日", "M月d日"]
    private static let textual = ["d MMM yyyy", "d MMMM yyyy", "MMM d, yyyy", "MMMM d, yyyy",
                                  "d MMM", "d MMMM", "MMM d", "MMMM d"]

    /// Multi-format parse; nil on failure. Year-less formats use `now`'s year. `now` is
    /// injected for deterministic tests (defaults to Date()).
    static func parse(_ s: String, now: Date = Date()) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }

        // Order the groups by the strongest available clue to minimize cross-format misreads.
        let groups: [[String]]
        if t.prefix(4).allSatisfy(\.isNumber) && t.contains(where: { $0 == "-" || $0 == "/" }) {
            groups = [iso, numeric, chinese, textual]               // 4-digit-leading + sep → ISO first
        } else if t.contains("月") {
            groups = [chinese, numeric, iso, textual]               // 月/日 → Chinese first
        } else if t.contains(where: { $0.isLetter && $0.isASCII }) {
            groups = [textual, numeric, iso, chinese]               // has a month NAME → textual first
        } else {
            groups = [numeric, iso, chinese, textual]               // bare digits/separators → DD/MM first
        }

        for grp in groups {
            for pat in grp {
                if let d = fmt(pat).date(from: t) {
                    // Year-less patterns (no "y") parse to a default year (1900/2000) → graft now's year.
                    let candidate = pat.contains("y") ? d : withYear(of: now, into: d)
                    // Year-plausibility guard. A malformed numeric date whose day > 31 (e.g.
                    // "32/05/26") fails every DD/MM pattern and falls through to the ISO
                    // `yyyy-MM-dd` formatter, which happily reads a 1–2 digit leading segment
                    // as a year ("32" → 0032). That is a WRONG date, not a parse: the intent is
                    // "never produce a wrong date — return nil so the caller falls back to .now".
                    // If this candidate's year is implausible, DON'T return — `continue` so a
                    // later format group still gets a chance; only fall through to nil if no
                    // plausible parse exists anywhere. (For these malformed inputs none does.)
                    guard isPlausibleYear(candidate, now: now) else { continue }
                    return candidate
                }
            }
        }
        return nil
    }

    /// True iff `d`'s Gregorian year (in the parse tz) is within [2000, now.year + 1].
    /// Lower bound 2000: no bank SMS predates it (rejects absurd 0032/0099 from the
    /// formatter quirk above). Upper bound now.year + 1: headroom for year-boundary edge
    /// cases while still rejecting typos like a far-future "2099".
    private static func isPlausibleYear(_ d: Date, now: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let y = cal.component(.year, from: d)
        let ny = cal.component(.year, from: now)
        return y >= 2000 && y <= ny + 1
    }

    /// Replace a year-less parse's default year with `now`'s year (keeping month/day).
    private static func withYear(of now: Date, into d: Date) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz
        let y = c.component(.year, from: now)
        var comp = c.dateComponents([.month, .day], from: d)
        comp.year = y
        return c.date(from: comp) ?? d
    }
}
