//
//  EmailAutomationSetupView.swift
//  GoodToNote
//
//  GN-039 (Task 6) — 邮件自动记账 onboarding: step cards that walk the user through hand-building
//  ONE iOS「邮件 / Email」personal automation that feeds each bank transaction email to
//  IngestEmailIntent → parsed by the user's email template → a pending draft. Mirrors
//  WalletAutomationSetupView (GN-036) / ShortcutSetupView in SHAPE (segments + progress + bottom bar
//  + reusable card builders + the REUSABLE ShortcutsLauncher x-callback auto-return infra), so the
//  three guides feel consistent. Reachable from BOTH onboarding (onFinish advances the flow) and
//  设置 ▸ 记账 (onFinish nil → 完成 pops).
//
//  ── The KEY differences from SMS / Apple Pay (GN-038 research, baked into the cards) ──
//   • FILTER BY SENDER, NOT BODY KEYWORDS. The iOS Email trigger can filter by Sender / Subject /
//     Account / Recipient, but NOT by body content (unlike Messages' "Message Contains"). So the
//     guide tells the user to enter the BANK'S SENDER ADDRESS / DOMAIN (e.g. alerts@uob.com.sg) —
//     this is actually STURDIER than the SMS keyword approach (a bank's from-address is stable).
//   • ONE EXTRA SHORTCUT ACTION: the email arrives as a FILE (name = subject, contents = body,
//     usually .html). The Shortcut must add "Get Text from Input" to turn that file into text BEFORE
//     handing it to「处理银行邮件」. SMS passes a plain string directly; email needs this step.
//   • Same floor as SMS/Apple Pay (GN-022/GN-035): iOS gives NO create-automation API, so the user
//     hand-builds it once; choosing "Run Immediately" forces a per-run system notification (can't be
//     turned off for Email — unlike Apple Pay) — card 0 sets that expectation honestly.
//   • Also requires an EMAIL template first (built in 识别模版 ▸ 邮件模版) — the runtime only
//     recognizes email whose key segment matches a user-built email template; card 0 points there.
//
//  GN-041: the teaching-video / one-tap-import placeholder slot was removed (product decision: no
//  video). The figure-and-text step cards carry the guide.
//

import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

struct EmailAutomationSetupView: View {
    @Environment(\.modelContext) private var modelContext
    /// GN-041: dismiss the pushed NavigationLink when opened from 设置 (onFinish nil).
    @Environment(\.dismiss) private var dismiss
    /// Non-nil when embedded in onboarding: 完成 advances the onboarding flow. Nil from 设置: 完成 pops.
    var onFinish: (() -> Void)?

    /// GN-039: reuse the shared router (it publishes ANY DeepLinkRoute). We react ONLY to the
    /// emailSetup* routes; the wallet guide ignores them and vice-versa (both observe this object).
    @ObservedObject private var router = WalletSetupRouter.shared

    /// Guide cards. Kept as an enum so the x-callback "next" can advance by rawValue.
    private enum Card: Int, CaseIterable {
        case expectation    // 卡0 预期管理 + 需要先建邮件模版
        case openShortcuts  // 卡1 打开快捷指令 → 自动化
        case createAuto     // 卡2 新建个人自动化 → 选「邮件 / Email」
        case filterSender   // 卡3 按发件人(银行域名)过滤 + 立即运行
        case mapAction      // 卡4 Get Text from Input → 处理银行邮件
        case done           // 卡5 完成
    }

    @State private var card: Card = .expectation

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    progressHeader
                    switch card {
                    case .expectation:   expectationCard
                    case .openShortcuts: openShortcutsCard
                    case .createAuto:    createAutoCard
                    case .filterSender:  filterSenderCard
                    case .mapAction:     mapActionCard
                    case .done:          doneCard
                    }
                }
                .padding()
            }
            bottomBar
        }
        .navigationTitle("邮件自动记账")
        .navigationBarTitleDisplayMode(.inline)
        // GN-039: x-callback auto-return (REUSED infra). When a Shortcuts step finishes with
        // x-success=goodtonote://emailsetup/next, iOS reopens the app, RootView routes it into the
        // shared router, and we advance here automatically. We consume ONLY our own routes.
        .onReceive(router.$pendingRoute.compactMap { $0 }) { route in
            switch route {
            case .emailSetupNext:
                advance(); router.pendingRoute = nil
            case .emailSetupDone:
                card = .done; router.pendingRoute = nil
            case .walletSetupNext, .walletSetupDone:
                break   // not ours — leave for the wallet guide
            }
        }
    }

    // MARK: - Progress header

    private var progressHeader: some View {
        HStack(spacing: 6) {
            badge("①", label: "准备", active: card.rawValue >= Card.openShortcuts.rawValue)
            connector
            badge("②", label: "建自动化", active: card.rawValue >= Card.createAuto.rawValue)
            connector
            badge("③", label: "填发件人", active: card.rawValue >= Card.filterSender.rawValue)
            connector
            badge("④", label: "接动作", active: card.rawValue >= Card.mapAction.rawValue)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private func badge(_ num: String, label: LocalizedStringKey, active: Bool) -> some View {
        VStack(spacing: 4) {
            Text(num)
                .font(.headline)
                .foregroundStyle(active ? Color.white : Color.secondary)
                .frame(width: 28, height: 28)
                .background(active ? Color.accentColor : Color(.tertiarySystemFill))
                .clipShape(Circle())
            Text(label)
                .font(.caption2)
                .foregroundStyle(active ? .primary : .secondary)
        }
    }

    private var connector: some View {
        Rectangle().fill(Color(.separator)).frame(height: 1).frame(maxWidth: .infinity)
    }

    // MARK: - 卡0 预期管理

    private var expectationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("envelope.badge.fill", "用邮件自动记账")
            // GN-037: 去"为什么"解释,只留一句极短引入 + 一句必须的先决条件。
            Text("跟着下面四步做,以后收到银行交易邮件就自动记一笔。")
                .font(.body)
                .foregroundStyle(.secondary)
            calloutCard(icon: "highlighter", text: "先决条件:先到「识别模版 ▸ 邮件模版」建一个邮件模版。")
        }
    }

    // MARK: - 卡1 打开快捷指令

    private var openShortcutsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("square.stack.3d.up", "第一步:打开「快捷指令」自动化")
            openAutomationButton
            stepCard(1, "底部点「自动化 / Automation」,再点右上角「+」。")
        }
    }

    // MARK: - 卡2 新建个人自动化 → 选「邮件 / Email」

    private var createAutoCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("gearshape.2", "第二步:选「邮件 / Email」触发")
            stepCard(1, "(若出现)选「创建个人自动化 / Create Personal Automation」。")
            stepCard(2, "在触发列表里点「邮件 / Email」。")
        }
    }

    // MARK: - 卡3 按发件人过滤 + 立即运行

    private var filterSenderCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("at.circle", "第三步:填银行发件人、立即运行")
            stepCard(1, "在「发件人 / Sender」填银行交易邮件的发件地址(如 alerts@uob.com.sg)。")
            stepCard(2, "(可选)填「主题包含 / Subject Contains」进一步收窄。")
            stepCard(3, "选「立即运行 / Run Immediately」,点「下一步 / Next」。")
            // GN-037: 系统通知预防针留一句极简(邮件触发关不掉,防当 bug)。
            calloutCard(icon: "bell.badge", text: "每来一封记账邮件会有一条系统通知,属正常。")
        }
    }

    // MARK: - 卡4 接动作(Get Text from Input → 处理银行邮件)

    private var mapActionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("link", "第四步:取出正文,交给记账动作")
            stepCard(1, "加操作「从输入获取文本 / Get Text from Input」。")
            stepCard(2, "再加操作「处理银行邮件」。")
            stepCard(3, "把「处理银行邮件」的「邮件正文」设为上一步「文本」的输出。")
            stepCard(4, "点「完成 / Done」保存。")
            // GN-037: 顺序是这条流程能否认出邮件的关键,留一句极简提醒(how,非 why)。
            calloutCard(icon: "exclamationmark.triangle", text: "顺序必须是先「获取文本」、再「处理银行邮件」,否则认不出。")
        }
    }

    // MARK: - 卡5 完成

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("party.popper.fill", "设置完成")
            Text("邮件自动记账已就绪,下次来一封交易邮件即自动记一笔待确认。")
                .font(.body)
                .foregroundStyle(.secondary)
            calloutCard(icon: "questionmark.circle", text: "没自动记上?确认已建邮件模版、发件人填对、动作顺序是「获取文本 → 处理银行邮件」。可到「设置 ▸ 记账」重做。")
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if card != .expectation {
                Button("上一步") { goBack() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            Button(card == .done ? "完成" : "下一步") { advance() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Reusable card builders (mirror WalletAutomationSetupView / ShortcutSetupView)

    private func cardTitle(_ icon: String, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
            Text(title).font(.title3.bold())
        }
    }

    private func stepCard(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func calloutCard(icon: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Opens Shortcuts at the Automation surface (best-effort deep link; if the system only opens
    /// Shortcuts, the cards still guide the user). REUSED ShortcutsLauncher (GN-036).
    private var openAutomationButton: some View {
        Button {
            ShortcutsLauncher.openAutomationTab()
        } label: {
            Label("打开「快捷指令」自动化", systemImage: "arrow.up.forward.app")
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: - Navigation

    private func advance() {
        if let next = Card(rawValue: card.rawValue + 1) {
            card = next
        } else {
            // 卡5「完成」: onboarding → advance the flow; from 设置 (onFinish nil) → dismiss the
            // pushed NavigationLink (GN-041: was a no-op `onFinish?()`, so 完成 was dead).
            if let onFinish { onFinish() } else { dismiss() }
        }
    }

    private func goBack() {
        if let prev = Card(rawValue: card.rawValue - 1) { card = prev }
    }
}
