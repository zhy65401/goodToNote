//
//  AppModelContainer.swift
//  GoodToNote
//
//  GN-004 — Shared SwiftData ModelContainer construction. The App Intent
//  (AddTransactionIntent) writes transactions in the background and MUST land in
//  the SAME store the main app reads/writes. To guarantee that, both the app and
//  any App Intent / EntityQuery construct the container from this single source:
//  same schema (the four real @Models), same default on-disk store URL
//  (applicationSupport/default.store — see RestoreManager.defaultStoreURL), never
//  in-memory. Free Apple ID: fully local, no CloudKit / App Groups entitlements.
//

import Foundation
import SwiftData

enum AppModelContainer {
    /// The schema shared by app + intents. Keep in lockstep with RestoreManager.makeContainer.
    /// GN-024: + AppSettings (new relation-free entity → additive lightweight migration;
    /// the existing 321-txn store opens unchanged and gains an empty AppSettings table).
    /// GN-025: + SmsTemplate (likewise a NEW relation-free entity — defaultCategoryID is a
    /// UUID scalar, not a Category relation — so it is the same additive lightweight
    /// migration; the 321-txn store gains an empty SmsTemplate table, nothing else moves).
    static let models: [any PersistentModel.Type] = [
        Transaction.self, Category.self, RecurringRule.self, MerchantMapping.self,
        AppSettings.self, SmsTemplate.self,
    ]

    /// Build a container over the real models at the default (on-disk) location.
    /// Uses SwiftData's default configuration so the store URL matches the main
    /// app exactly (applicationSupport/default.store). NOT in-memory.
    static func make() throws -> ModelContainer {
        try ModelContainer(for: Transaction.self, Category.self,
                           RecurringRule.self, MerchantMapping.self,
                           AppSettings.self, SmsTemplate.self)
    }

    // —— Process-shared container for App Intent / EntityQuery paths ——
    // App Intents may run in a separate process from the main app; each process
    // builds its own ModelContainer pointing at the same on-disk store. We cache
    // one per process so repeated intent invocations don't rebuild the stack.
    private static var cached: ModelContainer?
    private static let lock = NSLock()

    /// Shared container for non-UI entry points (App Intent perform / EntityQuery).
    /// Throws if the store can't be opened.
    static func shared() throws -> ModelContainer {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let c = try make()
        cached = c
        return c
    }
}
