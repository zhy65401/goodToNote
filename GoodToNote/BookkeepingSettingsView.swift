//
//  BookkeepingSettingsView.swift
//  GoodToNote
//
//  GN-033 — "记账" drill-in page. Collects the bookkeeping entries that used to be flat sections
//  in SettingsView: 分类管理 / 周期交易 / 识别模版 / 短信自动记账 / Apple Pay 自动记账 /
//  GN-039 邮件自动记账. Pure navigation hub — the destination views and their behavior are unchanged.
//

import SwiftUI

struct BookkeepingSettingsView: View {
    var body: some View {
        List {
            NavigationLink("分类管理") { CategoryManagementView() }
            NavigationLink("周期交易") { RecurringRulesView() }
            // GN-039: the list now manages BOTH short-message and email templates (kind badge per
            // row; "+新建" lets the user pick SMS or Email), so the entry is renamed 识别模版.
            NavigationLink("识别模版") { SmsTemplateListView() }
            // From Settings, ShortcutSetupView's段3「完成」 pops via this NavigationStack
            // (onFinish nil) — same as the prior flat entry.
            NavigationLink("短信自动记账") { ShortcutSetupView() }
            // GN-036: Apple Pay 自动记账 引导,与短信自动记账并列。onFinish nil → 完成 popped by this stack.
            NavigationLink("Apple Pay 自动记账") { WalletAutomationSetupView() }
            // GN-039: 邮件自动记账 引导,与短信/Apple Pay 并列。onFinish nil → 完成 popped by this stack.
            NavigationLink("邮件自动记账") { EmailAutomationSetupView() }
        }
        .navigationTitle(String(localized: "记账"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { BookkeepingSettingsView() }
}
