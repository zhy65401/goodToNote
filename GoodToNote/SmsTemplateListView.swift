//
//  SmsTemplateListView.swift
//  GoodToNote
//
//  GN-025 (Phase C, Task C2) — SMS template management. Lists every SmsTemplate
//  (@Query by ascending orderIndex — the same first-match order the runtime intent
//  uses), lets the user enable/disable, reorder (drag in edit mode → rewrites
//  orderIndex), delete ANY template (including built-in presets, see below), edit
//  per-template metadata, and create new ones via the C1 editor.
//
//  Task-status connection: M2 上架方向的核心泛用性修正。Phase A (engine) + B (runtime +
//  UOB preset seed) + C1 (SmsTemplateEditorView) are DONE and green (26/26 tests). This
//  is the management surface + the REAL Settings entry (replacing C1's temporary one), so
//  a user can see / order / toggle / edit / delete the templates that drive recognition.
//
//  GN-031: ALL templates are now deletable (built-in presets included). Previously the
//  built-in was delete-blocked because SmsTemplatePresets.seedIfNeeded re-seeded whenever
//  NO built-in preset existed, so deleting it just resurrected a zombie on next launch.
//  GN-031 adds a one-shot "smsDemoPresetSeeded" UserDefaults flag in seedIfNeeded so the
//  demo seeds at most once EVER — deleting it does NOT bring it back. With resurrection
//  gone, the delete block has no value and is just annoying, so it is removed.
//  GN-030: the built-in is a neutral, DISABLED placeholder demo ("示例模版"); it ships
//  disabled, so it does not participate in matching until a user explicitly enables it.
//
//  Metadata-edit sheet (NOT a detection re-edit): SmsTemplate does NOT store the original
//  example text, so the compiled pattern/slots can't be re-derived here. The sheet edits
//  only the OUTPUT-side metadata (name / type / default category / currency fallback /
//  enabled). To change WHAT a template detects, delete it and re-create via the editor
//  (which recompiles) — the sheet says so.
//
//  Custom Button rows use .contentShape(Rectangle()) (project memory:
//  tappable-row-contentshape — .plain Button rows are otherwise only tappable where the
//  label is drawn).
//

import SwiftUI
import SwiftData

// MARK: - List

struct SmsTemplateListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SmsTemplate.orderIndex) private var templates: [SmsTemplate]

    @State private var editTarget: SmsTemplate?
    /// GN-039: when set, opens the editor in the chosen kind ("sms" / "email"). nil = closed. We
    /// drive the create sheet off this (instead of a bool) so the user first picks SMS vs Email.
    @State private var createKind: String?
    /// GN-039: presents the "新建短信模版 / 新建邮件模版" chooser (a confirmationDialog).
    @State private var showCreateChooser = false

    var body: some View {
        List {
            Section {
                if templates.isEmpty {
                    Text("还没有模版。点右上角「+」，粘贴一条交易短信或一封交易邮件来新建。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(templates) { t in
                        row(t)
                    }
                    .onMove(perform: move)
                }
            } footer: {
                Text("自动按从上到下的顺序逐条尝试识别，命中即停。短信只试短信模版、邮件只试邮件模版。拖动可调整顺序。")
            }
        }
        .navigationTitle("识别模版")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreateChooser = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建")
            }
        }
        // GN-039: choose which kind of template to build (short SMS vs long HTML email take
        // different paste / preprocess paths).
        .confirmationDialog("新建模版", isPresented: $showCreateChooser, titleVisibility: .visible) {
            Button("短信模版") { createKind = "sms" }
            Button("邮件模版") { createKind = "email" }
            Button("取消", role: .cancel) {}
        } message: {
            Text("识别银行交易短信，还是交易邮件？")
        }
        .sheet(item: $editTarget) { t in
            SmsTemplateMetadataSheet(template: t)
        }
        // C1 editor with NO prefill → user pastes a fresh SMS / email (kind from the chooser).
        .sheet(item: Binding(get: { createKind.map(IdentifiedKind.init) },
                             set: { createKind = $0?.kind })) { item in
            SmsTemplateEditorView(inputKind: item.kind)
        }
    }

    @ViewBuilder
    private func row(_ t: SmsTemplate) -> some View {
        HStack {
            // Textual area opens the metadata-edit sheet. The Toggle lives OUTSIDE this
            // Button so the row tap and the toggle don't fight (the Button's hit area is
            // bounded by .contentShape(Rectangle()) on its own label, not the Toggle).
            Button {
                editTarget = t
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.name).foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            // GN-039: 短信 / 邮件 kind badge — so the list shows which input path each
                            // template recognizes (email templates are tried only for incoming email).
                            kindBadge(t)
                            Text(typeLabel(t))
                                .font(.caption).foregroundStyle(.secondary)
                            if t.isBuiltInPreset {
                                Text("预置")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.tint.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: enabledBinding(t))
                .labelsHidden()
        }
        .swipeActions(edge: .trailing) {
            // GN-031: ALL templates deletable (seeded-once flag prevents demo resurrection).
            Button(role: .destructive) {
                delete(t)
            } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func typeLabel(_ t: SmsTemplate) -> String {
        (TransactionType(rawValue: t.transactionTypeRaw) ?? .expense) == .income
            ? String(localized: "收入") : String(localized: "支出")
    }

    /// GN-039: a small colored capsule showing the template's input kind (短信 / 邮件), with an
    /// icon matching the rest of the app (message vs envelope).
    @ViewBuilder
    private func kindBadge(_ t: SmsTemplate) -> some View {
        let isEmail = t.inputKind == "email"
        Label(isEmail ? String(localized: "邮件") : String(localized: "短信"),
              systemImage: isEmail ? "envelope" : "message")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((isEmail ? Color.purple : Color.blue).opacity(0.15), in: Capsule())
            .foregroundStyle(isEmail ? Color.purple : Color.blue)
    }

    /// Writes isEnabled directly on the @Model (autosaved) + an explicit save for the
    /// cross-process store the intent reads.
    private func enabledBinding(_ t: SmsTemplate) -> Binding<Bool> {
        Binding(get: { t.isEnabled }, set: { newValue in
            t.isEnabled = newValue
            try? modelContext.save()
        })
    }

    /// Drag-to-reorder → rewrite orderIndex to the new positions (0..<n), then save.
    private func move(from source: IndexSet, to destination: Int) {
        var ordered = templates
        ordered.move(fromOffsets: source, toOffset: destination)
        for (i, t) in ordered.enumerated() { t.orderIndex = i }
        try? modelContext.save()
    }

    private func delete(_ t: SmsTemplate) {
        // GN-031: any template deletes (built-in included); seeded-once flag stops the demo
        // from re-seeding, so deleting the placeholder demo does not resurrect it.
        modelContext.delete(t)
        try? modelContext.save()
    }
}

/// GN-039: wraps the chosen input kind ("sms"/"email") so it can drive a `.sheet(item:)` (which
/// needs Identifiable). Identity = the kind string (fine: one create sheet at a time).
private struct IdentifiedKind: Identifiable {
    let kind: String
    var id: String { kind }
}

// MARK: - Metadata-edit sheet

/// Edits a template's OUTPUT metadata only (name / type / default category / currency
/// fallback / enabled). Does NOT touch the compiled pattern — SmsTemplate stores no
/// original example to recompile from, so "what it detects" is changed by deleting +
/// re-creating in the editor (the footer hint says so).
private struct SmsTemplateMetadataSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let template: SmsTemplate

    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var name = ""
    @State private var type: TransactionType = .expense
    @State private var defaultCategoryID: UUID? = nil
    @State private var currencyFallback = "SGD"
    @State private var isEnabled = true
    @State private var showFallbackPicker = false
    @State private var didLoad = false
    /// GN-034: presents the token-annotation editor in EDIT mode to re-edit THIS template's
    /// detection rule (only offered when exampleText is non-empty — GN-032+ templates).
    @State private var showEditDetection = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var categoriesForType: [Category] {
        categories.filter { $0.kind == (type == .expense ? .expense : .income) }
                  .sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: - GN-032 highlighted example + legend

    /// The four highlight roles shown in the legend, in display order. cardMask is excluded
    /// (it's a non-capturing wildcard → never in slotMap → never highlighted).
    private static let legendRoles: [SlotRole] = [.amount, .currency, .merchant, .date]

    /// The stored example SMS as an AttributedString with each selected span colored by its
    /// category (金额 blue / 币种 green / 商户 orange / 日期 purple) + bold. The spans are
    /// RECOVERED by running the compiled pattern over exampleText (SmsTemplateMatcher.matchSpans)
    /// — they are never stored. nil when exampleText is empty (old template → fallback hint).
    private var highlightedExample: AttributedString? {
        let ex = template.exampleText
        guard !ex.isEmpty else { return nil }
        let slotMap = (try? JSONDecoder().decode([String].self, from: Data(template.slotMapJSON.utf8)))?
            .compactMap { SlotRole(rawValue: $0) } ?? []
        let spans = SmsTemplateMatcher.matchSpans(ex, pattern: template.compiledPattern, slotMap: slotMap)
        var attr = AttributedString(ex)
        func color(_ role: SlotRole, _ c: Color) {
            // AttributedString.Index(_:within:) can fail (e.g. an index landing inside a grapheme
            // cluster) → guard and skip that span rather than crashing.
            guard let r = spans[role],
                  let lo = AttributedString.Index(r.lowerBound, within: attr),
                  let hi = AttributedString.Index(r.upperBound, within: attr) else { return }
            attr[lo..<hi].foregroundColor = c
            attr[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
        }
        color(.amount, .blue)
        color(.currency, .green)
        color(.merchant, .orange)
        color(.date, .purple)
        return attr
    }

    /// A small color-coded legend row (matches the editor: 金额 blue / 币种 green / 商户 orange /
    /// 日期 purple) so the user can read what each highlighted color means.
    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(Self.legendRoles, id: \.self) { role in
                legendDot(roleLabel(role), roleColor(role))
            }
        }
        .font(.caption2)
    }

    private func legendDot(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func roleLabel(_ role: SlotRole) -> String {
        switch role {
        case .amount:   return String(localized: "金额")
        case .currency: return String(localized: "币种")
        case .merchant: return String(localized: "商户")
        case .date:     return String(localized: "日期")
        case .cardMask: return String(localized: "卡号")
        }
    }

    private func roleColor(_ role: SlotRole) -> Color {
        switch role {
        case .amount:   return .blue
        case .currency: return .green
        case .merchant: return .orange
        case .date:     return .purple
        case .cardMask: return .gray
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("模版设置") {
                    HStack {
                        Text("模版名")
                        Spacer()
                        TextField("模版名", text: $name)
                            .multilineTextAlignment(.trailing)
                    }

                    Picker("类型", selection: $type) {
                        Text("支出").tag(TransactionType.expense)
                        Text("收入").tag(TransactionType.income)
                    }
                    .pickerStyle(.segmented)

                    Picker("默认分类", selection: $defaultCategoryID) {
                        Text("不选").tag(UUID?.none)
                        ForEach(categoriesForType) { c in
                            Text("\(c.icon) \(c.name)").tag(Optional(c.id))
                        }
                    }

                    Button {
                        showFallbackPicker = true
                    } label: {
                        HStack {
                            Text("币种回退")
                            Spacer()
                            Text(CurrencyCatalog.displayName(currencyFallback))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Toggle("启用", isOn: $isEnabled)
                }

                // GN-032: show the ORIGINAL example SMS the template was set up with, the
                // amount/currency/merchant/date spans highlighted in their category colors
                // (recovered by running the compiled pattern over exampleText — never stored),
                // + a legend. Old templates (exampleText == "") fall back to the original hint.
                if let highlighted = highlightedExample {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            // GN-039: email templates store the preprocessed KEY SEGMENT as the
                            // example — label it accordingly so the user isn't confused that it's
                            // not the full email.
                            Text(template.inputKind == "email" ? "邮件模版样例（关键段）" : "短信模版样例")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(highlighted)
                                .font(.callout)
                                .textSelection(.enabled)
                            legend
                        }
                        .padding(.vertical, 2)
                    } footer: {
                        // GN-034: this template stored its original example (GN-032+), so its
                        // detection rule CAN be re-edited in place — open the token-annotation
                        // editor in EDIT mode (pre-selects the spans the current rule recognizes).
                        Text("点下面可重新标注金额／币种／商户／日期，改它「识别哪些交易」。")
                    }
                    // GN-034: the "Edit detection rule" entry. Custom Button rows use
                    // .contentShape(Rectangle()) (project memory: tappable-row-contentshape).
                    Section {
                        Button {
                            showEditDetection = true
                        } label: {
                            HStack {
                                Label("编辑识别规则", systemImage: "highlighter")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Section {
                        Text("这里只改产出设置（名称、类型、默认分类、币种回退、启用）。要修改它「识别哪些短信」，请删除后用一条新短信重新创建。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("编辑模版")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }.disabled(!canSave)
                }
            }
            .sheet(isPresented: $showFallbackPicker) {
                CurrencyPickerSheet(selected: currencyFallback) { picked in
                    currencyFallback = picked
                }
            }
            // GN-034: re-edit THIS template's detection rule. The editor overwrites the template
            // in place (preserving id/orderIndex/isEnabled/isBuiltInPreset). On a successful save
            // its onSaved closure dismisses this metadata sheet too, so the user lands back on the
            // list (not on a now-stale highlighted example).
            .sheet(isPresented: $showEditDetection) {
                SmsTemplateEditorView(editingTemplate: template, onCancel:  {
                    dismiss()
                })
            }
            .onChange(of: type) { _, _ in
                if let sel = defaultCategoryID,
                   !categoriesForType.contains(where: { $0.id == sel }) {
                    defaultCategoryID = nil
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        name = template.name
        type = TransactionType(rawValue: template.transactionTypeRaw) ?? .expense
        defaultCategoryID = template.defaultCategoryID
        currencyFallback = template.currencyFallback
        isEnabled = template.isEnabled
    }

    private func save() {
        template.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        template.transactionTypeRaw = type.rawValue
        template.defaultCategoryID = defaultCategoryID
        template.currencyFallback = currencyFallback
        template.isEnabled = isEnabled
        try? modelContext.save()
        dismiss()
    }
}
