//
//  ShortcutSetupView.swift
//  GoodToNote
//
//  GN-026 (Phase 2) — 短信自动记账 setup: the three-segment guide (per GN-022 §3/§5/§6).
//
//  Task→status: GN-022 proved iOS has NO API for an app to create/install a Messages
//  automation (research fact 1) — "truly one-tap" is impossible. The realistic floor is the
//  user hand-building one Messages automation (~6 steps); the app's job is to strip the
//  cognitive load: the ingest action is already in Shortcuts zero-config (AppShortcutsProvider),
//  the trigger keyword is auto-copied to the clipboard, and a 发送测试 button proves the
//  app-side parse→persist chain works in-app. This view delivers exactly that.
//
//  Reachable from BOTH:
//    • OnboardingView's 短信自动记账 step (embedded; `onFinish` advances the flow), and
//    • 设置 ▸ 短信自动记账 (NavigationLink; `onFinish` nil → the Done button just pops).
//  Skippable / resumable: nothing here is persisted as "must-finish"; the user can leave and
//  come back from Settings any time.
//
//  Three segments (GN-022):
//    段0 预期管理 — set expectations (manual automation, ~6 steps, system notification normal).
//    段1 拿到快捷指令 — open Shortcuts (shortcuts://), add the zero-config "处理银行短信"
//                       (IngestUOBMessageIntent) action, set its input to 快捷指令输入, save.
//    段2 建「信息」自动化 — on entry, COPY the first enabled template's suggestedTriggerKeyword
//                          to the clipboard; goal-oriented step cards (robust across iOS
//                          17/18/26); 重新复制 button + plaintext keyword for re-paste.
//    段3 验证闭环 — 【发送测试】 runs IngestUOBMessageIntent.ingest on the neutral placeholder
//                  demo sample IN-APP (the SAME parse→FX→persist chain the automation uses —
//                  DRY, no reimplementation) → one pending draft → success alert. + prompt to
//                  text yourself a real SMS for the end-to-end check.
//

import SwiftUI
import SwiftData
import UIKit

struct ShortcutSetupView: View {
    @Environment(\.modelContext) private var modelContext
    /// GN-041: dismiss the pushed NavigationLink when opened from 设置 (onFinish nil).
    @Environment(\.dismiss) private var dismiss

    /// Non-nil when embedded in onboarding: the 完成 button advances the onboarding flow.
    /// Nil when opened from 设置: the 完成 button just pops the NavigationLink.
    var onFinish: (() -> Void)?

    /// The four guide segments. `.expectation` is 段0; the rest map to GN-022 段1–3.
    private enum Segment: Int, CaseIterable {
        case expectation   // 段0
        case getShortcut   // 段1
        case automation    // 段2
        case verify        // 段3
    }

    @State private var segment: Segment = .expectation
    /// The trigger keyword copied to the clipboard on entering 段2 (first enabled template's
    /// suggestedTriggerKeyword). Shown in plaintext + re-copyable. nil if no template/keyword.
    @State private var triggerKeyword: String?
    @State private var didCopyToast = false

    // 段3 send-test state.
    @State private var isSendingTest = false
    @State private var testResultMessage: String?
    @State private var showTestResult = false

    // —— GN-052 Task 3: test with YOUR OWN text, against the real engine ——
    /// The text the user tests with. Seeded from their most recent UNRECOGNIZED SMS draft (the
    /// message they actually want answered: "why didn't my template catch THIS?"), else the demo.
    @State private var testText: String = ""
    @State private var didSeedTestText = false
    /// Result of the last dry-run recognition test (no drafts written).
    @State private var diagnosis: Diagnosis?

    /// What one dry-run test found — either a hit (which template + the extracted fields) or a
    /// miss WITH the reason each enabled template rejected the text.
    private struct Diagnosis {
        var matched: Bool
        var templateName: String?
        var fields: [(label: String, value: String)]
        var reason: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    progressHeader
                    switch segment {
                    case .expectation: expectationSegment
                    case .getShortcut: getShortcutSegment
                    case .automation:  automationSegment
                    case .verify:      verifySegment
                    }
                }
                .padding()
            }
            bottomBar
        }
        .navigationTitle("短信自动记账")
        .navigationBarTitleDisplayMode(.inline)
        .alert("发送测试", isPresented: $showTestResult) {
            Button("好") {}
        } message: {
            Text(testResultMessage ?? "")
        }
    }

    // MARK: - Progress header (① 快捷指令 / ② 自动化 / ③ 验证)

    private var progressHeader: some View {
        HStack(spacing: 6) {
            badge("①", label: "快捷指令", active: segment.rawValue >= Segment.getShortcut.rawValue)
            connector
            badge("②", label: "自动化", active: segment.rawValue >= Segment.automation.rawValue)
            connector
            badge("③", label: "验证", active: segment.rawValue >= Segment.verify.rawValue)
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
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    // MARK: - 段0 预期管理

    private var expectationSegment: some View {
        VStack(alignment: .leading, spacing: 16) {
            segmentTitle("message.badge.filled.fill", "跟着做,建一个自动短信触发")
            // GN-037: 段0 去"为什么"解释,只留一句极短引入。
            Text("跟着下面三步做,以后收到银行短信就自动记一笔。")
                .font(.body)
                .foregroundStyle(.secondary)
            // GN-037: 唯一保留的预防针——一句极简(防用户把系统通知当 bug)。
            calloutCard(icon: "bell.badge", text: "每次自动记账会有一条系统通知,属正常。")
        }
    }

    // MARK: - 段1 拿到快捷指令

    private var getShortcutSegment: some View {
        VStack(alignment: .leading, spacing: 16) {
            segmentTitle("square.stack.3d.up", "第一步:建一个快捷指令")

            // GN-037: shortcuts://create-shortcut 直达新建编辑器,省"点+新建"一步。
            newShortcutButton

            stepCard(1, "点「添加操作 / Add Action」,搜并选「处理银行短信」。")
            stepCard(2, "把动作输入设为「快捷指令输入 / Shortcut Input」。")
            stepCard(3, "命名「记账短信」并保存。")
        }
    }

    // MARK: - 段2 建「信息」自动化

    private var automationSegment: some View {
        VStack(alignment: .leading, spacing: 16) {
            segmentTitle("gearshape.2", "第二步:建一个「信息」自动化")

            keywordCard
            openAutomationButton

            stepCard(1, "底部点「自动化 / Automation」,再点右上角「+」。")
            stepCard(2, "在触发列表里点「信息 / Message」。")
            stepCard(3, "在「信息包含 / Message Contains」里长按粘贴关键词,点「下一步 / Next」。")
            stepCard(4, "选要运行的快捷指令「记账短信」。")
            stepCard(5, "选「立即运行 / Run Immediately」,点「完成 / Done」。")
        }
        .onAppear(perform: copyKeywordToClipboard)
    }

    /// 关键词卡:明文显示 + 「重新复制」按钮（防剪贴板被覆盖）。
    private var keywordCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("触发关键词(已复制到剪贴板)", systemImage: "doc.on.clipboard")
                .font(.subheadline.bold())
            if let kw = triggerKeyword {
                Text(kw)
                    .font(.callout.monospaced())
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
                Button {
                    copyKeywordToClipboard()
                    withAnimation { didCopyToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { didCopyToast = false }
                    }
                } label: {
                    Label(didCopyToast ? "已复制" : "重新复制", systemImage: didCopyToast ? "checkmark" : "doc.on.doc")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
            } else {
                Text("没有可用的短信模版,无法生成关键词。请先到「设置 ▸ 短信模版」添加一个模版。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 段3 验证闭环

    private var verifySegment: some View {
        VStack(alignment: .leading, spacing: 16) {
            segmentTitle("checkmark.seal", "第三步:验证")

            // GN-052 Task 3: the test box now takes the USER'S OWN text. It used to always feed
            // the hardcoded demo SMS, so a user whose real template was broken got a cheerful
            // "✓ OK" from a message their template had nothing to do with — the app could not
            // answer the one question that mattered ("does my template match MY sms?").
            VStack(alignment: .leading, spacing: 10) {
                Label("① 在 app 内测试", systemImage: "testtube.2")
                    .font(.subheadline.bold())
                Text("粘贴一条你自己的银行短信,看模版能不能认出它。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextEditor(text: $testText)
                    .font(.callout)
                    .frame(minHeight: 96)
                    .padding(6)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 10) {
                    Button {
                        runRecognitionTest()
                    } label: {
                        Text("测试识别")
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        testText = SmsTemplatePresets.demoExample
                        diagnosis = nil
                    } label: {
                        Text("用示例短信")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                }

                if let d = diagnosis { diagnosisCard(d) }

                Divider().padding(.vertical, 2)

                // The original end-to-end check, now fed the SAME text box (was: always the demo).
                Text("确认识别无误后,可以让它真正落一笔待确认草稿。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    runSendTest()
                } label: {
                    HStack {
                        if isSendingTest { ProgressView().controlSize(.small) }
                        Text("发送测试(落一笔草稿)")
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .disabled(isSendingTest || testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // 端到端：用户自发一条真实短信。
            calloutCard(icon: "paperplane", text: "② 给自己发一条含关键词的短信,约 1 分钟后到流水页看待确认草稿。")
            calloutCard(icon: "questionmark.circle", text: "没收到?检查自动化已开、关键词填对、选了「立即运行 / Run Immediately」。")
        }
        .onAppear(perform: seedTestTextIfNeeded)
    }

    /// GN-052 Task 3 — the dry-run result: which template caught the text and what it extracted,
    /// or WHY each enabled template rejected it.
    @ViewBuilder
    private func diagnosisCard(_ d: Diagnosis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: d.matched ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(d.matched ? .green : .orange)
                Text(d.matched
                     ? String(localized: "已识别 · 模版「\(d.templateName ?? "")」")
                     : String(localized: "未识别"))
                    .font(.subheadline.bold())
            }
            ForEach(d.fields, id: \.label) { f in
                HStack {
                    Text(f.label).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(f.value).font(.callout.monospaced())
                }
            }
            if let reason = d.reason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Bottom bar (上一段 / 下一段 / 完成)

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if segment != .expectation {
                Button("上一步") { goBack() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            Button(segment == .verify ? "完成" : "下一步") { advance() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Reusable card builders

    private func segmentTitle(_ icon: String, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(title)
                .font(.title3.bold())
        }
    }

    /// A numbered, goal-oriented step card (GN-022: one step per card, robust across iOS versions).
    private func stepCard(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// An informational callout (icon + secondary text).
    private func calloutCard(icon: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 段1: 直达「新建快捷指令」编辑器（GN-037: shortcuts://create-shortcut 省"点+新建"一步;
    /// 若该 scheme 不被支持则回落 shortcuts:// 落在 app 里,卡片继续引导）。
    private var newShortcutButton: some View {
        Button {
            if let url = URL(string: "shortcuts://create-shortcut"), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            } else if let fallback = URL(string: "shortcuts://") {
                UIApplication.shared.open(fallback)
            }
        } label: {
            Label("新建快捷指令", systemImage: "plus.app")
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    /// 段2: 打开「快捷指令」自动化页（复用 GN-036 ShortcutsLauncher，与 Apple Pay/邮件引导一致;
    /// best-effort,不灵则落在 Shortcuts 根,卡片继续引导）。
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

    // MARK: - Logic

    /// Copy the first ENABLED template's suggestedTriggerKeyword to the clipboard (GN-022 段2
    /// entry). Sorted by orderIndex. GN-030: the built-in demo preset is DISABLED, so for a new
    /// user this finds nothing until they build/enable their own template — keywordCard then
    /// shows the "add a template first" hint, which is the honest state.
    private func copyKeywordToClipboard() {
        var descriptor = FetchDescriptor<SmsTemplate>(
            predicate: #Predicate { $0.isEnabled == true },
            sortBy: [SortDescriptor(\.orderIndex, order: .forward)]
        )
        descriptor.fetchLimit = 1
        let kw = (try? modelContext.fetch(descriptor))?.first?.suggestedTriggerKeyword
        triggerKeyword = kw
        if let kw, !kw.isEmpty {
            UIPasteboard.general.string = kw
        }
    }

    /// GN-052 Task 3 — seed the test box with the user's OWN most recent unrecognized SMS draft.
    /// That is the message they are actually asking about; falling back to the neutral demo only
    /// when there is none. (Read-only — nothing is written or consumed.)
    private func seedTestTextIfNeeded() {
        guard !didSeedTestText else { return }
        didSeedTestText = true
        var d = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.isPending },
            sortBy: [SortDescriptor(\.date, order: .reverse)])
        d.fetchLimit = 20
        let recent = ((try? modelContext.fetch(d)) ?? [])
            .first { SmsRecognitionRuntime.isUnrecognizedDraft($0) && $0.source == "sms" }
        testText = recent?.note ?? SmsTemplatePresets.demoExample
    }

    /// GN-052 Task 3 — DRY-RUN the real engine over the user's own text: the exact runtime path
    /// (SmsRecognitionRuntime.scan → SmsTemplateMatcher.matchDetailed → decodeSlotMap on the
    /// PERSISTED slotMapJSON), just without persisting anything. Writes no drafts, so the user can
    /// iterate freely. On a miss it reports WHY each enabled template rejected the text — before
    /// GN-052 all three failure modes collapsed into a silent nil and nothing could be diagnosed
    /// from inside the app.
    private func runRecognitionTest() {
        let text = testText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let templates = SmsRecognitionRuntime.enabledTemplates(kind: "sms", in: modelContext)
        guard !templates.isEmpty else {
            diagnosis = Diagnosis(matched: false, templateName: nil, fields: [],
                                  reason: String(localized: "还没有启用的短信模版。请先到「设置 ▸ 短信模版」建一个,或启用已有的。"))
            return
        }
        let result = SmsRecognitionRuntime.scan(text, templates: templates)
        if let t = result.hitTemplate, let f = result.hitFields {
            let cur = f.currency ?? t.currencyFallback
            diagnosis = Diagnosis(
                matched: true,
                templateName: t.name,
                fields: [
                    (String(localized: "金额"), f.amount.map { formatBase($0, code: cur) } ?? "—"),
                    (String(localized: "币种"), cur),
                    (String(localized: "商户"), f.merchantRaw.map { UOBMessageParser.displayName(from: $0) } ?? "—"),
                    (String(localized: "日期"), f.date.map { Self.testDateFormatter.string(from: $0) } ?? "—"),
                ],
                reason: nil)
        } else {
            let lines = result.attempts.map { "「\($0.template.name)」：\(Self.describe($0.reason))" }
            diagnosis = Diagnosis(matched: false, templateName: nil, fields: [],
                                  reason: lines.joined(separator: "\n"))
        }
    }

    /// GN-052 Task 3 — plain-language rendering of each distinguishable failure reason.
    private static func describe(_ r: SmsRecognitionRuntime.SkipReason) -> String {
        switch r {
        case .failed(.invalidPattern):
            return String(localized: "这条模版的规则本身无效(正则无法编译),它永远不会匹配任何短信。请重新编辑并保存它。")
        case .failed(.noMatch):
            return String(localized: "这段文字与它的结构对不上。")
        case .failed(.groupCountMismatch(let expected, let actual)):
            return String(localized: "模版槽位与规则对不上(期望 \(expected) 组,实际 \(actual) 组),需要重新编辑并保存它。")
        case .matchedButNoAmount:
            return String(localized: "结构对上了,但没能从中读出金额。")
        }
    }

    /// Localized medium-date formatter for the test result (matches the editor's preview style).
    private static let testDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// 段3 发送测试: run the SAME ingest chain the Messages automation uses, in-app (DRY —
    /// IngestUOBMessageIntent.ingest is the single source of truth; no parse/FX/persist
    /// reimplemented here). Creates one real pending draft in the shared store, then reports the
    /// app-side result.
    ///
    /// GN-052: it now ingests the TEXT BOX's content (the user's own SMS) instead of always the
    /// hardcoded demo sample — the old behavior could only ever prove the demo worked. The demo
    /// remains one tap away via「用示例短信」.
    private func runSendTest() {
        isSendingTest = true
        let sample = testText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            defer { isSendingTest = false }
            let outcome = await IngestUOBMessageIntent.ingest(message: sample, into: modelContext)
            if outcome.matched {
                testResultMessage = String(localized: "✓ 已生成 \(outcome.draftsCreated) 笔待确认(到流水页确认),app 侧 OK。")
            } else {
                // Expected for a new user: no enabled template matches the placeholder, so the
                // SMS lands as an original-text draft (never dropped). Be honest about it.
                testResultMessage = String(localized: "✓ 测试短信已收到并落盘(到流水页查看)。建好你自己的短信模版后,真实账单短信会自动识别金额、商户。")
            }
            showTestResult = true
        }
    }

    private func advance() {
        if let next = Segment(rawValue: segment.rawValue + 1) {
            segment = next
        } else {
            // 段3「完成」: embedded in onboarding → advance the flow; from 设置 (onFinish nil) →
            // dismiss the pushed NavigationLink (GN-041: was a no-op `onFinish?()`, so 完成 was dead).
            if let onFinish { onFinish() } else { dismiss() }
        }
    }

    private func goBack() {
        if let prev = Segment(rawValue: segment.rawValue - 1) {
            segment = prev
        }
    }
}
