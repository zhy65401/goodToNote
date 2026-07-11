//
//  CurrencyConverter.swift
//  GoodToNote
//
//  GN-004 / GN-024 — Foreign currency → BASE conversion shared by the App Intent and
//  the manual entry editor. Pure logic over an injected FXRateProviding +
//  FXRateCaching so it's unit-testable. NEVER throws: on failure it downgrades and
//  flags needsFxRate so we never lose a transaction (user decision 2026-05-31).
//  GN-024: generalized from a hardcoded SGD base to a caller-supplied `base` (read
//  from AppSettings). The semantics are symmetric: when base == "SGD" this behaves
//  exactly as the original SGD-only converter.
//
//  Resolution order for a currency, given a `base`:
//   1. code == base → rate 1, needsFxRate=false, provider NOT called.
//   2. today's cached rate (for code in base) hit → use it, provider NOT called.
//   3. provider success → use & cache it, needsFxRate=false.
//   4a. provider fails but a last-successful rate (in base) exists → use it, flagged.
//   4b. provider fails and no history → fall back to rate 1, needsFxRate=true.
//

import Foundation

/// Result of converting an amount into the base currency.
/// GN-024: base-neutral names (was fxRateToSGD/sgdAmount). The @Model Transaction
/// still stores these under fxRateToSGD/sgdAmount — only this value type is renamed.
struct ConversionResult: Equatable {
    let fxRateToBase: Decimal
    let baseAmount: Decimal
    let needsFxRate: Bool
}

struct CurrencyConverter {
    let provider: FXRateProviding
    let cache: FXRateCaching
    /// Injected "today" so tests are deterministic; defaults to now.
    let today: Date

    init(provider: FXRateProviding, cache: FXRateCaching, today: Date = .now) {
        self.provider = provider
        self.cache = cache
        self.today = today
    }

    /// Convert `amount` of `currencyCode` into `base`.
    /// `base` is the configured base currency code (e.g. "SGD"); callers read it
    /// from AppSettings.current(in:).baseCurrencyCode.
    func convert(amount: Decimal, currencyCode: String, base: String) async -> ConversionResult {
        let code = currencyCode.uppercased()
        let baseCode = base.uppercased()

        // 1) Base passthrough.
        if code == baseCode {
            return ConversionResult(fxRateToBase: 1, baseAmount: amount, needsFxRate: false)
        }

        // 2) Same-day cache hit (keyed by base + code).
        if let cached = cache.todayRate(for: code, base: baseCode, on: today) {
            return ConversionResult(fxRateToBase: cached,
                                    baseAmount: amount * cached,
                                    needsFxRate: false)
        }

        // 3) Live fetch.
        do {
            let rate = try await provider.rate(for: code, base: baseCode)
            cache.store(rate: rate, for: code, base: baseCode, on: today)
            return ConversionResult(fxRateToBase: rate,
                                    baseAmount: amount * rate,
                                    needsFxRate: false)
        } catch {
            // 4a) Downgrade to last successful rate (in base), else 4b) fall back to 1.
            let placeholder = cache.lastSuccessfulRate(for: code, base: baseCode) ?? 1
            return ConversionResult(fxRateToBase: placeholder,
                                    baseAmount: amount * placeholder,
                                    needsFxRate: true)
        }
    }

    /// Default converter used by app/intent paths (live API + UserDefaults cache).
    static func live(today: Date = .now) -> CurrencyConverter {
        CurrencyConverter(provider: OpenERAPIProvider(),
                          cache: FXRateCache(),
                          today: today)
    }
}
