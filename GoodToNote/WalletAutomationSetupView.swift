//
//  WalletAutomationSetupView.swift
//  GoodToNote
//
//  GN-036 (Task 4) — Apple Pay /「钱包」自动记账 onboarding: step cards that walk the user
//  through hand-building ONE Shortcuts「钱包 / Wallet」personal
//  automation that feeds each tap-to-pay payment to IngestWalletTransactionIntent for 0-tap,
//  fully-automatic recording. The automation MUST be hand-built (iOS gives no create-automation
//  API — GN-022/GN-035 floor); this view strips the friction with goal-oriented cards (robust
//  across iOS 17/18/26), an "open Shortcuts" button per step, and the REUSABLE x-callback
//  auto-return infra (ShortcutsLauncher) so finishing a Shortcuts step bounces back here and
//  advances automatically (GN-037 will reuse the same infra for SMS).
//
//  Mirrors ShortcutSetupView's shape (segments + progress + bottom bar + reusable card builders)
//  so the two guides feel consistent; reachable from BOTH onboarding (onFinish advances the flow)
//  and 设置 ▸ 记账 (onFinish nil → Done pops).
//
//  Honest framing (GN-035 §5): we do NOT promise "auto-configured". Apple Pay's「钱包 / Wallet」trigger
//  catches WALLET tap-to-pay only (cash / bank-app / non-Apple-Pay online purchases need the SMS
//  path or manual entry); the automation is a one-time hand-build; iOS may show a run notification
//  (can be turned off here, unlike SMS). Card 0 sets these expectations up front.
//
//  GN-041: the teaching-video placeholder slot was removed (product decision: no video). Text +
//  clear step cards carry the guide.
//
//  GN-045: copy corrected to match the REAL Shortcuts flow. The shortcuts://create-automation deep
//  link lands directly on the trigger picker, so the old "+/Create Personal Automation" intro is
//  gone; the guide now reads as THREE numbered steps after the open-Shortcuts card — (1) pick the
//  「钱包 / Wallet」trigger (with the user-supplied Wallet glyph beside the label), (2) pick cards +
//  Run Immediately, (3) search "记录 Apple Pay 交易" and connect the action's INLINE「金额/商户」blue
//  tokens (Amount is REQUIRED — unmapped → blank ledger). The currency step is dropped (the trigger
//  has no currency field; Amount arrives as a bare number → base currency). No "交易/Transaction"
//  wording (user decision: 只写钱包). Intent/engine/model unchanged.
//

import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// App-wide bridge from an incoming goodtonote:// deep link to the active wallet-setup view.
/// RootView.onOpenURL writes `pendingRoute`; an on-screen WalletAutomationSetupView observes it,
/// consumes it (advancing/finishing), and clears it. ObservableObject so a sheet-presented view
/// still reacts. REUSABLE: GN-037 can add SMS routes and observe the same object.
@MainActor
final class WalletSetupRouter: ObservableObject {
    static let shared = WalletSetupRouter()
    /// The most recent unconsumed deep-link route (nil once handled).
    @Published var pendingRoute: DeepLinkRoute?

    func handle(url: URL) {
        if let route = DeepLinkRoute(url: url) { pendingRoute = route }
    }
}

struct WalletAutomationSetupView: View {
    @Environment(\.modelContext) private var modelContext
    /// GN-041: dismiss the pushed NavigationLink when opened from 设置 (onFinish nil).
    @Environment(\.dismiss) private var dismiss
    /// Non-nil when embedded in onboarding: 完成 advances the onboarding flow. Nil from 设置: 完成 pops.
    var onFinish: (() -> Void)?

    @ObservedObject private var router = WalletSetupRouter.shared

    /// Guide cards. Kept as an enum so the x-callback "next" can advance by rawValue.
    /// GN-045: the `shortcuts://create-automation` deep link lands directly on the trigger picker
    /// (skipping "+/Create Personal Automation"), so the old "create automation" card is gone; the
    /// first real step is now picking the「钱包 / Wallet」trigger. Three numbered steps follow the
    /// open-Shortcuts card. RawValue ORDER is load-bearing (the x-callback "next" advances by it).
    private enum Card: Int, CaseIterable {
        case expectation   // 卡0 预期管理
        case openShortcuts // 打开快捷指令(直达触发选择那一屏)
        case pickWallet    // 第一步 在触发列表选「钱包 / Wallet」
        case pickCards     // 第二步 选卡 + 立即运行 + 关通知
        case mapAction     // 第三步 接上记账动作并映射「金额 / Amount」「商户 / Merchant」
        case done          // 完成
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
                    case .pickWallet:    pickWalletCard
                    case .pickCards:     pickCardsCard
                    case .mapAction:     mapActionCard
                    case .done:          doneCard
                    }
                }
                .padding()
            }
            bottomBar
        }
        .navigationTitle("Apple Pay 自动记账")
        .navigationBarTitleDisplayMode(.inline)
        // GN-036: x-callback auto-return. When a Shortcuts step finishes with
        // x-success=goodtonote://walletsetup/next, iOS reopens the app, RootView routes it into the
        // shared router, and we advance here automatically (no manual "switch back + tap Next").
        .onReceive(router.$pendingRoute.compactMap { $0 }) { route in
            // Only react to (and consume) wallet routes; GN-039 email routes are left for the
            // EmailAutomationSetupView to consume (both observe the same shared router).
            switch route {
            case .walletSetupNext:
                advance(); router.pendingRoute = nil
            case .walletSetupDone:
                card = .done; router.pendingRoute = nil
            case .emailSetupNext, .emailSetupDone:
                break   // not ours — don't consume
            }
        }
    }

    // MARK: - Progress header

    private var progressHeader: some View {
        HStack(spacing: 6) {
            badge("①", label: "准备", active: card.rawValue >= Card.openShortcuts.rawValue)
            connector
            badge("②", label: "选钱包", active: card.rawValue >= Card.pickWallet.rawValue)
            connector
            badge("③", label: "选卡", active: card.rawValue >= Card.pickCards.rawValue)
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
            cardTitle("creditcard.fill", "用 Apple Pay 全自动记账")
            // GN-037: 去"为什么"解释,只留一句极短引入。GN-045: 四步→三步(去掉"建自动化"那一屏)。
            Text("跟着下面三步做,以后用「钱包」里的卡线下刷 Apple Pay 就自动记一笔。")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 卡1 打开快捷指令

    private var openShortcutsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("square.stack.3d.up", "打开「快捷指令」")
            // GN-045: 深链 shortcuts://create-automation 直接落在"选择触发"那一屏,不经过"+/创建个人自动化",
            // 所以这里只开 App 并交代落点,不再让用户找「+」。
            Text("点下面的按钮,会直接打开「新建自动化 / New Automation」,停在选择触发那一屏。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            openAutomationButton
        }
    }

    // MARK: - 卡2 第一步:在触发列表选「钱包 / Wallet」

    private var pickWalletCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("gearshape.2", "第一步:选「钱包 / Wallet」触发")
            triggerPickStep
        }
    }

    // MARK: - 卡3 第二步:选卡 + 立即运行 + 关通知

    private var pickCardsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("creditcard", "第二步:选卡、立即运行")
            stepCard(1, "勾选要追踪的卡(建议常用卡全选)。")
            stepCard(2, "选「立即运行 / Run Immediately」。")
            stepCard(3, "关掉「运行时通知 / Notify When Run」,点「下一步 / Next」。")
        }
    }

    // MARK: - 卡4 第三步:接上记账动作(映射 inline token)

    private var mapActionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("link", "第三步:接上记账动作")
            // GN-045: 深链已落在「选择操作 / Choose Action」页(不经过"添加操作"),且本 app 的动作在
            // Shortcuts 里渲染成 parameterSummary 那一句、「金额」「商户」是蓝色可填 token(不是字段列表),
            // 「金额」必须接,否则 ingest 记空账。搜索名须与 IngestWalletTransactionIntent.title 一致。
            stepCard(1, "这时已经在「选择操作 / Choose Action」页。在搜索框搜「记录 Apple Pay 交易」,选本 app 的这个操作。")
            stepCard(2, "操作会显示成一句:「把 Apple Pay 交易 [金额] [商户] 记入流水」。点蓝色的「金额」,选触发器的「金额 / Amount」;点「商户」,选「商户 / Merchant」。「金额」必须接上,否则记的是空账。")
            stepCard(3, "点「完成 / Done」保存。")
        }
    }

    // MARK: - 卡5 完成

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("party.popper.fill", "设置完成")
            Text("Apple Pay 自动记账已就绪,下次线下刷卡即自动入账。")
                .font(.body)
                .foregroundStyle(.secondary)
            calloutCard(icon: "questionmark.circle", text: "没自动记上?最常见是「金额」没接上触发器的「金额 / Amount」变量;也确认自动化已开、选了「立即运行 / Run Immediately」。可到「设置 ▸ 记账」重做。")
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

    // MARK: - Reusable card builders (mirror ShortcutSetupView)

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

    /// GN-045: the single Step-1 row that tells the user to pick the「钱包 / Wallet」trigger, with the
    /// user-supplied Wallet icon shown beside the label. Mirrors `stepCard`'s badge + card styling.
    /// The icon is DECORATIVE (full-color, not templated) — not a control. The「钱包 / Wallet」label is
    /// the trailing token of both the zh and en strings, so the trailing icon reads as "beside" it.
    private var triggerPickStep: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("1")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor)
                .clipShape(Circle())
            // Localized sentence (its own catalog key) with the colored Wallet glyph beside the
            // 「钱包 / Wallet」label (the sentence's trailing token). The glyph is a sized sibling
            // Image (~22pt) rendered in its ORIGINAL colors — full-color, never templated/tinted.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("在触发列表里选「钱包 / Wallet」。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Image("WalletGlyph")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 3 }
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Opens Shortcuts at the Automation surface, with x-success so iOS auto-returns here and
    /// advances to the next card (the REUSABLE auto-return infra). Best-effort deep link; if the
    /// system only opens Shortcuts, the cards still guide the user.
    private var openAutomationButton: some View {
        Button {
            // Auto-return: when the user finishes/cancels in Shortcuts and returns, we still rely on
            // them tapping back; but where the URL flow supports it, x-success advances us. We open
            // the automation surface here; the cards guide the manual build.
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
