//
//  FXRateCache.swift
//  GoodToNote
//
//  GN-004 / GN-024 — Two-layer FX cache backed by UserDefaults:
//   ① today's rate per (base, currency) (key includes yyyy-MM-dd) → used as a
//      same-day hit so we don't refetch; expires across days simply by not matching.
//   ② per-(base, currency) LAST successful rate (no date) → the failure-downgrade
//      placeholder so we "never lose a transaction" when offline / API down.
//  Decimal is stored as its string form (lossless, avoids Double drift).
//  GN-024: every key now includes the base currency code so changing the base does
//  NOT hit a stale rate computed against the old base (e.g. USD→SGD vs USD→EUR).
//

import Foundation

/// Abstraction so CurrencyConverter tests can use an in-memory cache.
/// `base` is the target currency the rate is expressed in ("1 code = X base").
protocol FXRateCaching {
    func todayRate(for code: String, base: String, on day: Date) -> Decimal?
    func lastSuccessfulRate(for code: String, base: String) -> Decimal?
    /// Persist a freshly fetched rate: sets both today's entry and the "last successful".
    func store(rate: Decimal, for code: String, base: String, on day: Date)
}

struct FXRateCache: FXRateCaching {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private func dayKey(_ code: String, _ base: String, _ day: Date) -> String {
        "fx_\(Self.dayFormatter.string(from: day))_\(base.uppercased())_\(code.uppercased())"
    }
    private func lastKey(_ code: String, _ base: String) -> String {
        "fxlast_\(base.uppercased())_\(code.uppercased())"
    }

    func todayRate(for code: String, base: String, on day: Date) -> Decimal? {
        guard let s = defaults.string(forKey: dayKey(code, base, day)) else { return nil }
        return Decimal(string: s)
    }

    func lastSuccessfulRate(for code: String, base: String) -> Decimal? {
        guard let s = defaults.string(forKey: lastKey(code, base)) else { return nil }
        return Decimal(string: s)
    }

    func store(rate: Decimal, for code: String, base: String, on day: Date) {
        let s = (rate as NSDecimalNumber).stringValue
        defaults.set(s, forKey: dayKey(code, base, day))
        defaults.set(s, forKey: lastKey(code, base))
    }
}

/// In-memory cache for unit tests (no UserDefaults persistence).
final class InMemoryFXRateCache: FXRateCaching {
    private var today: [String: Decimal] = [:]
    private var last: [String: Decimal] = [:]
    private let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f
    }()
    init() {}

    private func k(_ code: String, _ base: String, _ day: Date) -> String {
        "\(dayFmt.string(from: day))_\(base.uppercased())_\(code.uppercased())"
    }
    private func lk(_ code: String, _ base: String) -> String {
        "\(base.uppercased())_\(code.uppercased())"
    }
    func todayRate(for code: String, base: String, on day: Date) -> Decimal? { today[k(code, base, day)] }
    func lastSuccessfulRate(for code: String, base: String) -> Decimal? { last[lk(code, base)] }
    func store(rate: Decimal, for code: String, base: String, on day: Date) {
        today[k(code, base, day)] = rate
        last[lk(code, base)] = rate
    }
    /// Test helper: pre-seed a "last successful" rate with no today entry.
    func seedLastSuccessful(_ rate: Decimal, for code: String, base: String) {
        last[lk(code, base)] = rate
    }
}
