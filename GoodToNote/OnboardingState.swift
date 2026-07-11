//
//  OnboardingState.swift
//  GoodToNote
//
//  GN-026 (Phase 1) — First-launch onboarding flag + the pure gate decision.
//
//  Purpose: GN-026 adds a welcome flow that should ONLY appear for genuinely-new users
//  (no completion flag AND an empty ledger). The existing 321-txn user must NOT be
//  interrupted on upgrade to v1.9 — RootView reads this flag + the transaction count and,
//  for an existing user, silently marks onboarding complete (see RootView gate).
//
//  Design: a UserDefaults flag (NOT a SwiftData @Model field) → no schema change, no
//  migration. The decision is factored into a pure (Bool, Int) -> Bool function so it can
//  be unit-tested with plain Foundation (battlefield/tests/GN-026_onboarding_test.swift),
//  matching the project's "pure logic out of @Model → swiftc harness" convention.
//

import Foundation

enum OnboardingState {
    private static let completedKey = "onboardingCompleted"

    /// Whether the user has finished (or skipped) the onboarding flow. Persisted in
    /// UserDefaults so it survives relaunch and is independent of the SwiftData store.
    static var completed: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    /// First-launch decision: present onboarding only when it has NOT been completed AND
    /// the ledger is empty (a genuinely-new user). A non-empty ledger means an existing
    /// user (upgrade) → do NOT present; the caller silently marks completion instead.
    static func shouldPresent(completed: Bool, transactionCount: Int) -> Bool {
        !completed && transactionCount == 0
    }
}
