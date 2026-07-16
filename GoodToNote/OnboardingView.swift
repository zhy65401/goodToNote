//
//  OnboardingView.swift
//  GoodToNote
//
//  GN-026 (Phase 1) — First-launch welcome flow shell.
//  GN-044 (this)    — Onboarding REDO: one new user walks through ALL in-app setup in a
//                     single guided run. Was a FIXED step enum
//                     (welcome→baseCurrency→applePay→sms→email→done); now a DYNAMIC sequence
//                     driven by a new channelSelect step.
//
//  Purpose: turn a brand-new install into "ready to use" by walking a new user through
//  欢迎 → 本位币 → channelSelect (★「你常收哪种交易通知?」短信/邮件/Apple Pay 多选,可全不选)
//  → 按勾选动态走(顺序 Apple Pay → 短信 → 邮件):
//      · Apple Pay 选中 → 直接配自动化(WalletAutomationSetupView,无需模版)
//      · 短信 选中     → ① 建短信模版(SmsTemplateEditorView inputKind:"sms")→ ② 配短信自动化
//      · 邮件 选中     → ① 建邮件模版(SmsTemplateEditorView inputKind:"email")→ ② 配邮件自动化
//  → 完成. Presented by RootView's fullScreenCover ONLY when OnboardingState.shouldPresent is
//  true (no flag + empty ledger); the existing 321-txn user never sees it. Any step is
//  skippable; finishing or skipping sets OnboardingState.completed and dismisses.
//
//  GN-044 断点修复: the old flow had NO "建模版" step, so when a new user reached the
//  短信/邮件 配自动化 step its keyword card had no enabled template's suggestedTriggerKeyword
//  to read ("先去设置建模版" dead end). Now each 短信/邮件 path BUILDS the template inline FIRST,
//  so the very next 配自动化 step's keyword card resolves.
//
//  GN-044 嵌入坑 (dismiss/取消): SmsTemplateEditorView owns its own NavigationStack + a 取消
//  button and a post-save「完成」alert, all of which call @Environment(\.dismiss). Inlined here
//  (inside RootView's fullScreenCover) that dismiss() resolves to the COVER → would tear down the
//  whole onboarding. Fix: the editor gained a GN-044 "embedded mode" (it's embedded iff onCancel
//  is non-nil); in that mode it routes 取消→onCancel() and post-save→onSaved() WITHOUT dismiss().
//  Here onSaved advances to the paired 配自动化 step; onCancel skips the WHOLE path (template +
//  its automation are useless without each other) and jumps to the next path / done. Standalone
//  editor presentations (设置/收件箱/metadata sheet) never pass onCancel → unchanged.
//
//  本位币 step: a new user's ledger is empty, so writing AppSettings.baseCurrencyCode is a
//  direct write — there is nothing to recompute (no BaseCurrencyService needed).
//

import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// GN-044: the notification channels a new user can opt into on the channelSelect step.
    /// Iterated in this declaration order to build the dynamic sequence (Apple Pay → 短信 → 邮件).
    enum Channel: CaseIterable, Hashable {
        case applePay
        case sms
        case email
    }

    /// GN-044: one screen in the flow. The fixed prefix/suffix are always present; the middle is
    /// generated from `selectedChannels` when channelSelect completes (see buildSequence()).
    private enum OnboardingStep: Hashable {
        case welcome
        case baseCurrency
        case channelSelect
        case applePayAuto       // Apple Pay 配自动化 (WalletAutomationSetupView)
        case smsTemplate        // 建短信模版 (SmsTemplateEditorView inputKind:"sms")
        case smsAuto            // 短信 配自动化 (ShortcutSetupView)
        case emailTemplate      // 建邮件模版 (SmsTemplateEditorView inputKind:"email")
        case emailAuto          // 邮件 配自动化 (EmailAutomationSetupView)
        case done
    }

    /// GN-044: the live, ORDERED step sequence. Starts with just the fixed prefix; channelSelect's
    /// 下一步 rebuilds it (prefix + per-channel steps + done) before advancing into the dynamic part.
    @State private var steps: [OnboardingStep] = [.welcome, .baseCurrency, .channelSelect]
    /// Index of the current step within `steps`.
    @State private var index: Int = 0
    /// GN-044: channelSelect multi-select state. Empty = a pure-manual user (skip all automation).
    @State private var selectedChannels: Set<Channel> = []
    @State private var showCurrencyPicker = false

    /// The step currently on screen.
    private var step: OnboardingStep { steps[min(index, steps.count - 1)] }

    /// Current base currency (fetch-or-create defaults to SGD). A new user can change it
    /// in the 本位币 step; the chosen value is written straight to AppSettings.
    private var baseCode: String { AppSettings.current(in: modelContext).baseCurrencyCode }

    /// GN-044: steps that embed a child view owning its OWN nav bar / bottom bar (so OnboardingView
    /// hides its own bottom button AND its 跳过 toolbar item for these — the child drives nav).
    private var stepHasEmbeddedChrome: Bool {
        switch step {
        case .applePayAuto, .smsAuto, .emailAuto, .smsTemplate, .emailTemplate: return true
        default: return false
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // —— Step content ——
                Group {
                    switch step {
                    case .welcome:        welcomeStep
                    case .baseCurrency:   baseCurrencyStep
                    case .channelSelect:  channelSelectStep
                    // GN-036: Apple Pay 配自动化. Its own bottom bar / progress; 完成 → onFinish=advance.
                    case .applePayAuto:   WalletAutomationSetupView(onFinish: advance)
                    // GN-044: 建短信模版 inline. EMBEDDED mode (onSaved + onCancel, NO dismiss) — onSaved
                    // advances to smsAuto; onCancel skips the whole 短信 path. See header「嵌入坑」.
                    case .smsTemplate:    SmsTemplateEditorView(inputKind: "sms",
                                                                onSaved: advance,
                                                                onCancel: { skipCurrentPath() })
                    // GN-026 Phase 2: 短信 配自动化 (three-segment ShortcutSetupView). 完成 → onFinish=advance.
                    case .smsAuto:        ShortcutSetupView(onFinish: advance)
                    // GN-044: 建邮件模版 inline (inputKind:"email" → email mode). Same embedded semantics.
                    case .emailTemplate:  SmsTemplateEditorView(inputKind: "email",
                                                                onSaved: advance,
                                                                onCancel: { skipCurrentPath() })
                    // GN-039: 邮件 配自动化 (EmailAutomationSetupView). 完成 → onFinish=advance.
                    case .emailAuto:      EmailAutomationSetupView(onFinish: advance)
                    case .done:           doneStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // —— Bottom controls —— (hidden on steps whose embedded child drives its own nav)
                if !stepHasEmbeddedChrome {
                    VStack(spacing: 12) {
                        Button(action: advance) {
                            Text(step == .done ? "开始使用" : "下一步")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .toolbar {
                // 任意步可跳过 → 标记完成并退出（用户随时可从设置重入配置）。
                // GN-044: hidden on embedded-chrome steps — those children own their own nav bar
                // (Apple Pay/短信/邮件 配自动化 use their own progress; the editor uses 取消 = 跳过该路径).
                ToolbarItem(placement: .topBarTrailing) {
                    if step != .done && !stepHasEmbeddedChrome {
                        Button("跳过") { finish() }
                    }
                }
            }
            .sheet(isPresented: $showCurrencyPicker) {
                CurrencyPickerSheet(selected: baseCode) { picked in
                    // 新用户库空 → 直接写本位币，无需重算历史。
                    AppSettings.current(in: modelContext).baseCurrencyCode = picked
                    try? modelContext.save()
                }
            }
        }
        .interactiveDismissDisabled()   // 只能经「跳过 / 开始使用」走完门控，不被下滑误关
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("欢迎使用 5分钱")
                .font(.title).bold()
                .multilineTextAlignment(.center)
            Text("随手记一笔，账目了然于心。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("应用语言会自动跟随你的系统语言。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    private var baseCurrencyStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("选择本位币")
                .font(.title2).bold()
            Text("本位币是统计和汇总时使用的货币。记账时可以用任意货币，应用会按汇率折算到本位币。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showCurrencyPicker = true
            } label: {
                HStack {
                    Text("本位币")
                    Spacer()
                    Text(CurrencyCatalog.displayName(baseCode))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Spacer()
        }
        .padding()
    }

    /// GN-044: 通知方式多选 — 「你常收哪种交易通知?」三个可勾选行(短信/邮件/Apple Pay),可全不选。
    private var channelSelectStep: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("你常收哪种交易通知？")
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                Text("勾选后我们带你逐个配好自动记账；没有也能手动记账。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)

            VStack(spacing: 12) {
                channelRow(.applePay,
                           title: "Apple Pay",
                           subtitle: "用 Apple Pay / Apple Card 付款后自动记一笔。",
                           systemImage: "creditcard.fill")
                channelRow(.sms,
                           title: "银行短信",
                           subtitle: "收到银行交易短信后自动记一笔。",
                           systemImage: "message.fill")
                channelRow(.email,
                           title: "交易邮件",
                           subtitle: "收到银行交易邮件后自动记一笔。",
                           systemImage: "envelope.fill")
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding(.bottom)
    }

    /// GN-044: one selectable channel row. Whole row is tappable (memory: custom Button rows need
    /// .contentShape(Rectangle()) or only part taps); a trailing checkmark reflects selection.
    private func channelRow(_ channel: Channel,
                            title: LocalizedStringKey,
                            subtitle: LocalizedStringKey,
                            systemImage: String) -> some View {
        let isOn = selectedChannels.contains(channel)
        return Button {
            if isOn { selectedChannels.remove(channel) } else { selectedChannels.insert(channel) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(.primary)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "party.popper.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("一切就绪")
                .font(.title2).bold()
            Text("现在就开始记你的第一笔吧。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    // MARK: - Navigation (GN-044: dynamic sequence)

    /// GN-044: build the FULL step sequence from the channelSelect choices. PURE in spirit (only
    /// reads `selectedChannels`) — mirrored + pinned in battlefield/tests/GN-044_sequence_test.swift.
    /// Order: fixed prefix → per-channel (Apple Pay → 短信[模版,自动化] → 邮件[模版,自动化]) → done.
    private static func buildSequence(_ channels: Set<Channel>) -> [OnboardingStep] {
        var seq: [OnboardingStep] = [.welcome, .baseCurrency, .channelSelect]
        for channel in Channel.allCases where channels.contains(channel) {
            switch channel {
            case .applePay: seq.append(.applePayAuto)
            case .sms:      seq.append(contentsOf: [.smsTemplate, .smsAuto])
            case .email:    seq.append(contentsOf: [.emailTemplate, .emailAuto])
            }
        }
        seq.append(.done)
        return seq
    }

    /// 下一步：channelSelect 完成时先按勾选生成动态序列;到最后一步「开始使用」= 完成。
    private func advance() {
        // GN-044: leaving channelSelect → freeze the dynamic sequence from the user's picks.
        if step == .channelSelect {
            steps = Self.buildSequence(selectedChannels)
        }
        if index + 1 < steps.count {
            index += 1
        } else {
            finish()
        }
    }

    /// GN-044: 取消建模版 → 跳过该「条」路径(模版 + 紧随的配自动化都跳掉,二者缺一无意义),跳到
    /// 序列里下一条路径的起点 / done。从 smsTemplate/emailTemplate 的 onCancel 调用。
    private func skipCurrentPath() {
        // Skip THIS step plus its paired automation step (the step right after a *Template step).
        let skipTo = index + 2
        if skipTo < steps.count {
            index = skipTo
        } else {
            finish()
        }
    }

    /// 标记完成并退出（跳过 / 开始使用 共用）。
    private func finish() {
        OnboardingState.completed = true
        dismiss()
    }
}
