//
//  RootView.swift
//  GoodToNote
//
//  GN-009 — Phase 1 root shell. TabView with 流水 (ledger), 统计 (stats
//  placeholder), 设置 (settings placeholder). Replaces the GN-002 debug
//  harness as the app's root.
//
//  GN-026 (Phase 1) — First-launch onboarding gate. On appear, decide whether to present
//  the welcome flow. The MUST-GET-RIGHT rule: only a genuinely-new user (no completion
//  flag AND an empty ledger) sees onboarding. An EXISTING user (has transactions) upgrading
//  to v1.9 must NOT be interrupted — we silently mark onboarding complete for them so the
//  cover never shows now or later. Both are derived from OnboardingState.shouldPresent.
//

import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var showOnboarding = false

    var body: some View {
        TabView {
            LedgerView()
                .tabItem { Label("流水", systemImage: "list.bullet") }
            StatsView()
                .tabItem { Label("统计", systemImage: "chart.pie") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
        // GN-036: route incoming goodtonote:// deep links (the Shortcuts x-callback x-success
        // jump-back) into the shared WalletSetupRouter, which the on-screen Apple Pay setup guide
        // observes to auto-advance. Unknown URLs are ignored safely (handle() no-ops on nil route).
        .onOpenURL { url in
            WalletSetupRouter.shared.handle(url: url)
        }
        .task { evaluateOnboardingGate() }
    }

    /// GN-026 首启门控（老用户静默跳过）：
    /// - 新用户（未完成 + 库空）→ 弹 onboarding。
    /// - 老用户（未完成 + 库非空）→ 不弹，并静默标记完成（避免升级 v1.9 被打扰；以后也不再判定）。
    /// - 已完成 → 不弹。
    private func evaluateOnboardingGate() {
        let completed = OnboardingState.completed
        let count = (try? modelContext.fetchCount(FetchDescriptor<Transaction>())) ?? 0
        if OnboardingState.shouldPresent(completed: completed, transactionCount: count) {
            showOnboarding = true
        } else if !completed && count > 0 {
            // 老用户：库里已有交易但从未走过 onboarding → 视为已完成，静默跳过。
            OnboardingState.completed = true
        }
    }
}
