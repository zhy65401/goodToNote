//
//  BaseCurrencyService.swift
//  GoodToNote
//
//  GN-024 — SwiftData-side orchestration of a base-currency change. Wraps the PURE
//  BaseCurrencyRecomputer with the side-effecting steps: auto-backup BEFORE the
//  change, ONE `latest/{newBase}` fetch for the whole rate table, abort-on-missing-rate
//  (no partial conversion), write recomputed base amounts back to every Transaction,
//  then flip AppSettings.baseCurrencyCode and save.
//
//  Locked design (brainstorm 2026-06-13):
//   • originalAmount is the immutable truth; we recompute at CURRENT rates.
//   • Network failure → abort ENTIRELY before any write (all-or-nothing). The
//     auto-backup taken first is the safety net.
//   • @Model fields keep the names sgdAmount / fxRateToSGD; their semantics are now
//     "amount in base currency" / "rate to base currency" (no SwiftData migration).
//
//  Not unit-tested (touches SwiftData + network); validated by build + simulator +
//  device regression. The pure math it delegates to IS unit-tested (GN-024 tests).
//

import Foundation
import SwiftData

enum BaseCurrencyService {
    enum ChangeError: LocalizedError {
        /// One or more currencies present in the ledger had no rate in the fetched
        /// table → the change was aborted and NOTHING was modified.
        case rateUnavailable([String])
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .rateUnavailable(let codes):
                let list = codes.sorted().joined(separator: ", ")
                return String(localized: "无法获取以下币种的当前汇率：\(list)。需联网，未做任何改动。")
            case .network:
                return String(localized: "获取汇率失败，需联网。未做任何改动。")
            }
        }
    }

    /// Change the base currency to `newBase`, recomputing every transaction's base
    /// amount at CURRENT rates. All-or-nothing: aborts (throwing) before any write if
    /// the network fails or any ledger currency lacks a rate.
    /// - Steps: ① auto-backup → ② collect distinct codes → ③ one full-table fetch →
    ///   ④ abort if any distinct code missing → ⑤ recompute (pure) → ⑥ write back →
    ///   ⑦ flip AppSettings → ⑧ save.
    @MainActor
    static func changeBase(to newBase: String,
                           in context: ModelContext,
                           container: ModelContainer,
                           provider: OpenERAPIProvider = OpenERAPIProvider()) async throws {
        let base = newBase.uppercased()

        // ① Auto-backup BEFORE touching anything (safety net; failure-tolerant inside).
        BackupManager.runLaunchBackup(container)

        // ② All transactions (pending drafts included — their base amount must stay
        //    consistent too) + the set of distinct currency codes actually in use.
        let txns = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let distinctCodes = Set(txns.map { $0.currencyCode.uppercased() })

        // ③ ONE network call: full rate table relative to the new base.
        let table: [String: Decimal]
        do {
            table = try await provider.fullTable(base: base)
        } catch {
            throw ChangeError.network(error)   // nothing written
        }

        // ④ Abort if any in-use currency (other than the new base) lacks a rate.
        let missing = distinctCodes.filter { $0 != base && table[$0] == nil }
        guard missing.isEmpty else {
            throw ChangeError.rateUnavailable(Array(missing))   // nothing written
        }

        // ⑤ Pure recompute over immutable snapshots.
        let snaps = txns.map {
            TxnConvSnapshot(id: $0.id, originalAmount: $0.originalAmount, currencyCode: $0.currencyCode)
        }
        let results = BaseCurrencyRecomputer.recompute(snaps, to: base, rates: table)

        // Safety: recompute must cover every transaction (the missing-rate guard
        // above already ensures this) — otherwise abort rather than half-write.
        guard results.count == txns.count else {
            let producedIDs = Set(results.map { $0.id })
            let lostCodes = Set(txns.filter { !producedIDs.contains($0.id) }.map { $0.currencyCode.uppercased() })
            throw ChangeError.rateUnavailable(Array(lostCodes))   // nothing written
        }

        // ⑥ Write results back. @Model fields keep names; semantics = base.
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        let txnByID = Dictionary(uniqueKeysWithValues: txns.map { ($0.id, $0) })
        for (id, r) in byID {
            guard let t = txnByID[id] else { continue }
            t.fxRateToSGD = r.fxRateToBase
            t.sgdAmount = r.baseAmount
            t.needsFxRate = false   // recomputed at current rate → no longer pending a rate
        }

        // ⑦ Flip the configured base.
        AppSettings.current(in: context).baseCurrencyCode = base

        // ⑧ Persist atomically.
        try context.save()
    }
}
