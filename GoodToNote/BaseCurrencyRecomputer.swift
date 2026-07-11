//
//  BaseCurrencyRecomputer.swift
//  GoodToNote
//
//  GN-024 — PURE recompute function for a base-currency change. Given a snapshot of
//  every transaction (its immutable originalAmount + currencyCode) and a rate table
//  relative to the NEW base ("1 unit of code = N units of newBase", newBase itself
//  = 1), produce the new base amount + snapshot rate for each.
//
//  Design (locked, brainstorm 2026-06-13): `originalAmount` is the immutable truth;
//  changing base recomputes history at CURRENT rates. A currency MISSING from the
//  table is NOT produced — the SwiftData-side service (BaseCurrencyService) detects a
//  short result and ABORTS the whole change (no partial conversion, never lose money
//  integrity). The base currency itself is always rate 1 even if absent from the table.
//
//  Pure Foundation, no SwiftData → unit-tested by the swiftc harness
//  (battlefield/tests/GN-024_basecurrency_test.swift), same pattern as GN-004/017.
//

import Foundation

/// Immutable per-transaction input to the recompute (the truth that survives a base change).
struct TxnConvSnapshot: Equatable {
    let id: UUID
    let originalAmount: Decimal
    let currencyCode: String
}

/// Recomputed base amount + snapshot rate for one transaction.
struct RecomputeResult: Equatable {
    let id: UUID
    let fxRateToBase: Decimal
    let baseAmount: Decimal
}

enum BaseCurrencyRecomputer {
    /// `rates[code]` = "1 unit of code = rate units of newBase". The base currency
    /// itself is treated as rate 1 (whether or not it appears in `rates`).
    /// A transaction whose currency has NO rate is **omitted** — the caller compares
    /// output count to input count and aborts the change if any are missing, so we
    /// never half-convert the ledger.
    static func recompute(_ snaps: [TxnConvSnapshot],
                          to newBase: String,
                          rates: [String: Decimal]) -> [RecomputeResult] {
        let base = newBase.uppercased()
        return snaps.compactMap { s in
            let code = s.currencyCode.uppercased()
            let rate: Decimal? = (code == base) ? 1 : rates[code]
            guard let r = rate else { return nil }
            return RecomputeResult(id: s.id, fxRateToBase: r, baseAmount: s.originalAmount * r)
        }
    }
}
