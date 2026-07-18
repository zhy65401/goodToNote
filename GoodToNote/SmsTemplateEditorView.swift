//
//  SmsTemplateEditorView.swift
//  GoodToNote
//
//  GN-025 (Phase C, Task C1) — The paste → detect → correct → save flow that produces a
//  SmsTemplate. Reachable from C2's "+新建" and B3's 【建模版】 (both pass an optional prefill
//  text); a TEMPORARY entry in SettingsPlaceholderView also opens it.
//
//  GN-029 (confirm-screen rewrite) — the ANNOTATION mechanism of the confirm step changed from
//  "edit 4 prefilled fields + locate via String.range(of:) first occurrence" to "tap tokenized
//  words to highlight them per category". The user picks a category "brush" (金额/币种/商户/日期),
//  taps words above to paint them that category's color (tapping adjacent words extends a
//  contiguous selection), and can edit each category's selected text below. Tapping yields a
//  PRECISE character range (the covered tokens' own ranges) — strictly better than the old
//  first-occurrence ambiguity. EVERYTHING ELSE IS PRESERVED: the paste step, the 模版设置 section,
//  save()→compile→SmsTemplate→self-check, prefillText, and the "amount required / others
//  optional" canSave semantics. The engine (DateParser/AmountParser/SmsExtractor/Compiler/
//  Matcher) is untouched; SmsTemplateCompiler.compile still consumes [(role, range)] spans —
//  buildSpans() now derives those ranges from the token selections.
//
//  GN-029 REVISION (review fix) — pre-selection had NO cross-role dedup: a merchant-before-
//  amount SMS with no stop punctuation (e.g. "Purchase at LAZADA SGD 36.34") let the greedy
//  merchant token range CONTAIN the currency+amount tokens, the compiler's overlap guard then
//  silently dropped the REQUIRED amount group, and canSave (which only checks assign[.amount]
//  is set) let the broken template save. Fixed in two places: (1) goToConfirm() now runs the
//  seeded assignments through dedupeAssignments(_:priority:) — a pure helper that enforces the
//  same "one token → one category" invariant tapToken upholds (amount/currency/date win over
//  the greedy merchant); (2) buildSpans() is now overlap-aware — if the .amount span char-
//  overlaps any other role's span (i.e. would be dropped by the compiler), amount is reported
//  missing → canSave false → save() shows "找不到金额" instead of persisting a broken template.
//
//  Task-status connection: M2 上架方向的核心泛用性修正。Engine + runtime + UOB preset seed are
//  DONE and green (57/57). This view is the user-facing creator that turns ANY user's bank SMS
//  into a reusable SmsTemplate; GN-029 makes its annotation step match the user's requested
//  point-and-highlight experience and gives the compiler more precise spans.
//
//  Custom tappable views here (token chips + brush buttons) use .contentShape(Rectangle())
//  (project memory: tappable-row-contentshape — custom tappable rows are otherwise only
//  tappable where the label is drawn).
//

import SwiftUI
import SwiftData

struct SmsTemplateEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Optional text to pre-fill the paste step (C2 "+新建" passes nil → user pastes;
    /// B3 【建模版】 passes the unrecognized draft's original SMS text).
    let prefillText: String?

    /// GN-034: when non-nil, the editor is in EDIT mode — it loads this template's stored
    /// exampleText, PRE-SELECTS the spans its CURRENT rule actually recognizes (via
    /// SmsTemplateMatcher.matchSpans, NOT a fresh SmsExtractor guess), and on save OVERWRITES
    /// this template's rule/output fields in place (applyEdits) instead of inserting a new one —
    /// so the template keeps its id / orderIndex / isEnabled / isBuiltInPreset / createdAt.
    /// nil = the original NEW-template path (paste → guess → insert), unchanged.
    let editingTemplate: SmsTemplate?

    /// GN-034: called once after a successful save lands (NEW or EDIT). Used by the metadata
    /// sheet's "编辑识别规则" entry so that, when the editor closes, the metadata sheet ALSO
    /// dismisses back to the list (instead of leaving the user on a now-stale highlighted
    /// example). nil for the standalone "+新建" presentation (which just dismisses itself).
    var onSaved: (() -> Void)? = nil

    /// GN-044: "embedded mode" flag. When non-nil, the editor is rendered INLINE inside another
    /// flow (the onboarding fullScreenCover) rather than in its own sheet. In that case the
    /// editor must NOT call `@Environment(\.dismiss)` — doing so would resolve to (and close) the
    /// host cover, tearing down the whole onboarding. So when this is set: the 取消 button calls
    /// onCancel() (parent skips this step), and the post-save 「完成」alert calls onSaved() ONLY —
    /// both WITHOUT dismiss(). When nil (every standalone presentation — 设置 ▸ 短信/邮件模版,
    /// 收件箱「建模版」, metadata sheet「编辑识别规则」) the original GN-034 dismiss() behavior is
    /// byte-for-byte unchanged. This mirrors the GN-041 `if let onFinish { onFinish() } else
    /// { dismiss() }` idiom the three AutomationSetupViews already use for the same reason.
    var onCancel: (() -> Void)? = nil

    /// GN-039: which input path this editor builds a template for — "sms" (default, unchanged) or
    /// "email". In EMAIL mode the paste step asks for a full transaction EMAIL and goToConfirm()
    /// runs EmailPreprocessor.process FIRST (HTML→plain + key-segment extraction) so the user
    /// annotates the SHORT key segment (not a thousand HTML-symbol chips), and save() stores
    /// inputKind="email" with exampleText = that KEY SEGMENT (the SAME text the runtime
    /// preprocessor produces, so the compiled anchors line up — GN-038 §3.1 invariant). In SMS mode
    /// everything is byte-for-byte the original GN-029/034 behavior (full text, inputKind="sms").
    /// In EDIT mode this is derived from the template (editingTemplate.inputKind), not the param.
    let initialInputKind: String

    /// All categories, for the optional default-category picker (reuse the app's @Query
    /// pattern). 默认分类 may be 不选 → nil.
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    /// Existing templates — used only to compute orderIndex = max existing + 1.
    @Query private var existingTemplates: [SmsTemplate]

    private enum Step { case paste, confirm }
    @State private var step: Step = .paste

    // —— Step A (paste) ——
    @State private var exampleText: String = ""

    // —— Step B (confirm) — GN-029 token-annotation state ——
    /// Ordered tokens of exampleText (range-bearing). Filled by goToConfirm().
    @State private var tokens: [SmsToken] = []
    /// The currently-selected category "brush". Tapping a token assigns it to this category.
    @State private var brush: SlotRole = .amount
    /// Per category → the contiguous token-id range currently painted that color. A category
    /// with no entry has no selection (and thus, for amount, blocks save).
    @State private var assign: [SlotRole: ClosedRange<Int>] = [:]
    /// Per category → the editable text shown below. Defaults to the token-selected substring;
    /// if the user edits it to a DIFFERENT string locatable in the example, buildSpans() uses
    /// that (range(of:) tweak) instead of the token range.
    @State private var editedText: [SlotRole: String] = [:]

    // —— Template settings (PRESERVED) ——
    @State private var currencyFallback: String = "SGD"
    @State private var transactionType: TransactionType = .expense
    @State private var defaultCategoryID: UUID? = nil
    @State private var templateName: String = ""
    @State private var maskCardDigits: Bool = true

    @State private var showFallbackPicker = false          // for the 币种回退 field

    // —— Step C (self-check after save) — PRESERVED ——
    @State private var selfCheck: MatchedFields?
    @State private var showSelfCheck = false
    @State private var saveError: String?
    /// GN-052 Task 2: how many already-landed unrecognized inbox drafts this save just upgraded.
    @State private var rescanUpgradedCount = 0

    init(prefillText: String? = nil,
         editingTemplate: SmsTemplate? = nil,
         inputKind: String = "sms",
         onSaved: (() -> Void)? = nil,
         onCancel: (() -> Void)? = nil) {
        self.prefillText = prefillText
        self.editingTemplate = editingTemplate
        // EDIT mode: follow the template's own kind (so re-editing an email template stays email);
        // NEW mode: use the caller's choice (sms default; the list's "邮件模版" entry passes email).
        self.initialInputKind = editingTemplate?.inputKind ?? inputKind
        self.onSaved = onSaved
        self.onCancel = onCancel
    }

    /// GN-044: true when the editor is hosted inline (onboarding) — gates OUT the self-dismiss so
    /// the host cover survives. Derived solely from `onCancel`, so NO existing standalone call site
    /// (which never passes it) changes behavior.
    private var isEmbedded: Bool { onCancel != nil }

    /// GN-039: live mode flag derived once from initialInputKind. true → build/edit an EMAIL
    /// template (preprocess on goToConfirm, store inputKind="email").
    private var isEmailMode: Bool { initialInputKind == "email" }

    /// GN-034: tracks whether the EDIT-mode initial load has happened, so re-renders / a
    /// returning .onAppear don't clobber the user's in-progress annotation. (The NEW path uses
    /// the analogous `exampleText.isEmpty` guard for its prefill.)
    @State private var didLoadForEdit = false

    /// The four user-paintable categories, in display + iteration order.
    private static let paintRoles: [SlotRole] = [.amount, .currency, .merchant, .date]

    /// GN-034/GN-039: the nav title. EDIT mode → "编辑识别规则" on both steps (the user can still
    /// go back to paste to swap the example); NEW mode keeps the original paste/confirm titles, with
    /// an EMAIL variant for the paste step so the user knows they're building an email template.
    private var navTitle: LocalizedStringKey {
        if editingTemplate != nil { return "编辑识别规则" }
        if step == .confirm { return "确认识别结果" }
        return isEmailMode ? "新建邮件模版" : "新建短信模版"
    }

    // MARK: - GN-034 overwrite (PURE, for re-editing an existing template's detection rule)

    /// GN-034: copy ONLY the "output + rule" fields onto an EXISTING template, overwriting its
    /// detection rule in place. It DELIBERATELY never touches `t.id`, `t.orderIndex`,
    /// `t.isEnabled`, `t.isBuiltInPreset`, or `t.createdAt` — so re-editing a template's rule
    /// keeps its list position, enabled state, preset badge, and identity (no duplicate row).
    /// Pure + static → unit-testable without the view (mirrored + pinned in
    /// battlefield/tests/GN-034_edit_test.swift). save() calls this on `editingTemplate` instead
    /// of inserting a new SmsTemplate.
    static func applyEdits(to t: SmsTemplate,
                           name: String,
                           compiledPattern: String,
                           slotMapJSON: String,
                           transactionTypeRaw: String,
                           defaultCategoryID: UUID?,
                           currencyFallback: String,
                           suggestedTriggerKeyword: String?,
                           exampleText: String) {
        t.name = name
        t.compiledPattern = compiledPattern
        t.slotMapJSON = slotMapJSON
        t.transactionTypeRaw = transactionTypeRaw
        t.defaultCategoryID = defaultCategoryID
        t.currencyFallback = currencyFallback
        t.suggestedTriggerKeyword = suggestedTriggerKeyword
        t.exampleText = exampleText
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .paste:   pasteStep
                case .confirm: confirmStep
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // GN-044: embedded (onboarding) → onCancel() lets the parent skip this step;
                    // standalone → original dismiss() (close the sheet). Never dismiss() when
                    // embedded, or the whole onboarding cover closes.
                    Button("取消") {
                        if isEmbedded { onCancel?() } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    switch step {
                    case .paste:
                        Button("下一步") { goToConfirm() }
                            .disabled(exampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    case .confirm:
                        Button("保存模版") { save() }
                            .disabled(!canSave)
                    }
                }
            }
            .onAppear {
                // GN-034: EDIT mode loads the stored example + pre-selects the CURRENT rule's
                // recognized spans (once). NEW mode keeps its prefill behavior unchanged.
                if editingTemplate != nil {
                    if !didLoadForEdit { loadForEdit() }
                } else if let p = prefillText, exampleText.isEmpty {
                    exampleText = p
                }
            }
            // Self-check result after a successful save → then dismiss. GN-034: in EDIT mode
            // (opened from the metadata sheet) also notify the parent so it dismisses too,
            // returning the user to the list instead of a stale highlighted example.
            .alert("模版已保存", isPresented: $showSelfCheck) {
                Button("完成") {
                    // GN-044: embedded (onboarding) → onSaved() advances to the next step WITHOUT
                    // dismiss() (dismiss would close the onboarding cover). Standalone → original
                    // GN-034 behavior: dismiss() the sheet, then onSaved?() (e.g. close the
                    // metadata sheet behind it). The template is already persisted (isEnabled +
                    // suggestedTriggerKeyword) regardless of branch.
                    if isEmbedded {
                        onSaved?()
                    } else {
                        dismiss()
                        onSaved?()
                    }
                }
            } message: {
                Text(selfCheckMessage)
            }
            .alert("无法保存", isPresented: Binding(get: { saveError != nil },
                                                  set: { if !$0 { saveError = nil } })) {
                Button("好") { saveError = nil }
            } message: { Text(saveError ?? "") }
        }
    }

    // MARK: - Step A: paste (PRESERVED)

    private var pasteStep: some View {
        Form {
            Section {
                // GN-039: email mode asks for a full transaction EMAIL (it will be preprocessed into
                // a short key segment on 下一步); sms mode keeps the original SMS prompt.
                Text(isEmailMode
                     ? "把你银行的一封交易邮件粘贴进来（整封即可，含 HTML 也行），我们会自动抽出含金额的关键段来认一认。"
                     : "把你银行的一条交易短信粘贴进来，我们来认一认。")
                    .font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $exampleText)
                    .frame(minHeight: 140)
                    .font(.body)
                Button {
                    if let s = UIPasteboard.general.string, !s.isEmpty { exampleText = s }
                } label: {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                }
            }
        }
    }

    // MARK: - Step B: tap-to-tag (GN-029 rewrite) + 模版设置 (PRESERVED)

    private var confirmStep: some View {
        Form {
            // —— GN-029: pick a category brush, then tap words to paint them that color. ——
            Section("点词标注") {
                Text("先选下面的类别，再点上面的词，词会高亮成该类别的颜色；连点相邻的词可连成一段。")
                    .font(.caption).foregroundStyle(.secondary)

                // Brush selector — capsule buttons, current brush filled.
                HStack(spacing: 8) {
                    ForEach(Self.paintRoles, id: \.self) { role in
                        brushButton(role)
                    }
                }
                .padding(.vertical, 2)

                // Token flow — every selectable token is a tappable chip colored by its owner.
                FlowLayout(spacing: 4) {
                    ForEach(tokens.filter { $0.isSelectable }) { tok in
                        tokenChip(tok)
                    }
                }
                .padding(.vertical, 4)
            }

            // —— GN-029: each painted category's selected text, editable + parse preview. ——
            Section("选中内容（可编辑）") {
                let active = Self.paintRoles.filter { assign[$0] != nil }
                if active.isEmpty {
                    Text("还没有选中任何内容。选「金额」类别并点出金额至少一项。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(active, id: \.self) { role in
                        selectedRow(role)
                    }
                }
            }

            // —— PRESERVED: 模版设置 ——
            Section("模版设置") {
                Picker("类型", selection: $transactionType) {
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

                HStack {
                    Text("模版名")
                    Spacer()
                    TextField("模版名", text: $templateName)
                        .multilineTextAlignment(.trailing)
                }

                Toggle("卡尾号通配（多卡也能匹配）", isOn: $maskCardDigits)
            }
        }
        .sheet(isPresented: $showFallbackPicker) {
            CurrencyPickerSheet(selected: currencyFallback) { picked in
                currencyFallback = picked
            }
        }
        .onChange(of: transactionType) { _, _ in
            // Keep the default-category selection valid for the chosen type.
            if let sel = defaultCategoryID,
               !categoriesForType.contains(where: { $0.id == sel }) {
                defaultCategoryID = nil
            }
        }
    }

    // MARK: - GN-029 brush + token chip + selected-row views

    /// A capsule category button. Tapping makes it the active brush. Filled when active.
    private func brushButton(_ role: SlotRole) -> some View {
        let isActive = brush == role
        return Button {
            brush = role
        } label: {
            Text(roleLabel(role))
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(
                    Capsule().fill(isActive ? roleColor(role) : roleColor(role).opacity(0.15))
                )
                .foregroundStyle(isActive ? .white : roleColor(role))
                .overlay(Capsule().stroke(roleColor(role), lineWidth: isActive ? 0 : 1))
                .contentShape(Rectangle())   // memory: tappable-row-contentshape
        }
        .buttonStyle(.plain)
    }

    /// A tappable token chip, background = its owning category's color (light gray if unowned).
    private func tokenChip(_ tok: SmsToken) -> some View {
        let owner = ownerRole(of: tok.id)
        let bg = owner.map { roleColor($0).opacity(0.85) } ?? Color(.systemGray5)
        let fg: Color = owner == nil ? .primary : .white
        return Button {
            tapToken(tok.id)
        } label: {
            Text(tok.text)
                .font(.callout)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(bg))
                .foregroundStyle(fg)
                .contentShape(Rectangle())   // memory: tappable-row-contentshape
        }
        .buttonStyle(.plain)
    }

    /// One row in "选中内容（可编辑）": colored dot + label + editable text + parse preview + clear.
    @ViewBuilder
    private func selectedRow(_ role: SlotRole) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(roleColor(role)).frame(width: 8, height: 8)
                Text(roleLabel(role)).font(.subheadline)
                Spacer()
                TextField(roleLabel(role), text: editedBinding(role))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(role == .amount ? .decimalPad : .default)
                Button {
                    clearAssignment(role)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if let preview = parsePreview(role) {
                Text(preview).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - GN-029 token tap logic

    /// Which category currently owns token `id` (the category whose assign range contains it).
    private func ownerRole(of id: Int) -> SlotRole? {
        Self.paintRoles.first { assign[$0]?.contains(id) ?? false }
    }

    /// Tap a token with the active brush:
    ///  - if the token already belongs to the brush category → cancel it (removeToken: single
    ///    → clear, endpoint → shrink one, interior → clear the category);
    ///  - if it belongs to ANOTHER category → remove it there, then assign to the brush;
    ///  - extend the brush category's selection to the minimal contiguous range covering the
    ///    existing selection + this id (so tapping adjacent words grows one segment).
    /// One token → one category (a token can never be in two categories at once).
    private func tapToken(_ id: Int) {
        // GN-031: re-tap a token already in the brush's selection → cancel. The previous check
        // (cur == id...id) only fired for an EXACTLY-single-token selection, so re-tapping a
        // token inside a multi-token selection fell through to extend (a no-op). removeToken
        // handles single→clear / endpoint→shrink / interior→clear.
        if assign[brush]?.contains(id) == true {
            removeToken(id, from: brush)
            return
        }
        // If another category owns it, remove it from that category first (shrink/clear).
        if let other = ownerRole(of: id), other != brush {
            removeToken(id, from: other)
        }
        // Extend the brush selection to cover the existing selection + this id (contiguous).
        if let cur = assign[brush] {
            let lo = min(cur.lowerBound, id), hi = max(cur.upperBound, id)
            assign[brush] = lo...hi
        } else {
            assign[brush] = id...id
        }
        // The selection text changed → reset the editable text to the new token substring.
        syncEditedText(brush)
    }

    /// Remove `id` from `role`'s selection. Because a selection is a contiguous range, removing
    /// an interior token would split it; we keep it simple + predictable: removing an endpoint
    /// shrinks the range, removing an interior token (or the last token) clears the category.
    private func removeToken(_ id: Int, from role: SlotRole) {
        guard let cur = assign[role] else { return }
        if cur.lowerBound == cur.upperBound {           // single token → clear
            clearAssignment(role); return
        }
        if id == cur.lowerBound {
            assign[role] = (cur.lowerBound + 1)...cur.upperBound
        } else if id == cur.upperBound {
            assign[role] = cur.lowerBound...(cur.upperBound - 1)
        } else {
            // interior token taken by another brush → splitting a contiguous range isn't
            // representable; clear this category (the user re-paints what they still want).
            clearAssignment(role); return
        }
        syncEditedText(role)
    }

    /// Drop a category's selection + its edited text entirely.
    private func clearAssignment(_ role: SlotRole) {
        assign[role] = nil
        editedText[role] = nil
    }

    /// Reset a category's editable text to the substring its current token range covers.
    private func syncEditedText(_ role: SlotRole) {
        if let r = stringRange(forRole: role) {
            editedText[role] = String(exampleText[r])
        } else {
            editedText[role] = nil
        }
    }

    /// Two-way binding for a category's editable text (falls back to the token substring).
    private func editedBinding(_ role: SlotRole) -> Binding<String> {
        Binding(
            get: {
                if let t = editedText[role] { return t }
                if let r = stringRange(forRole: role) { return String(exampleText[r]) }
                return ""
            },
            set: { editedText[role] = $0 }
        )
    }

    // MARK: - Step navigation (PRESERVED shape; GN-029 tokenize + preselect added)

    /// Run the extractor, TOKENIZE the example, and PRE-SELECT each category's token range from
    /// the extractor's best guesses (mapping each best span to the covering token-id range).
    private func goToConfirm() {
        // GN-039: in EMAIL mode, FIRST shrink the pasted email to its key segment via the SAME
        // EmailPreprocessor.process the runtime IngestEmailIntent uses — then tokenize/annotate/
        // compile/save all operate on that short, stable plain text (so the literal anchors line up
        // with what the matcher sees at runtime, GN-038 §3.1 invariant), and the FlowLayout gets a
        // handful of chips instead of hundreds of HTML-symbol chips (GN-038 §3.3). We REPLACE
        // exampleText with the segment so save() persists the segment as exampleText (the email
        // template's example IS its key segment — GN-032 highlight / GN-034 edit / runtime matchSpans
        // all then agree). SMS mode is unchanged (text = the full SMS).
        if isEmailMode {
            exampleText = EmailPreprocessor.process(exampleText)
        }
        let text = exampleText
        tokens = SmsTokenizer.tokenize(text)
        let r = SmsExtractor.extract(text)

        assign = [:]
        editedText = [:]

        // Amount: the candidate span whose parsed value == bestAmount.
        if let amt = r.bestAmount,
           let span = r.amountCandidates.first(where: { AmountParser.parse($0.text) == amt }),
           let idr = tokenRange(covering: span.range) {
            assign[.amount] = idr
        }
        // Currency: prefer the candidate span for bestCurrency; else the located currency token.
        if let cur = r.bestCurrency,
           let span = r.currencyCandidates.first(where: { $0.code == cur }),
           let idr = tokenRange(covering: span.span.range) {
            assign[.currency] = idr
        } else if let cr = currencyTokenRange(for: r.bestCurrency ?? defaultBaseCurrency),
                  let idr = tokenRange(covering: cr) {
            assign[.currency] = idr
        }
        // Merchant: the first merchant candidate span.
        if let span = r.merchantCandidates.first,
           let idr = tokenRange(covering: span.range) {
            assign[.merchant] = idr
        }
        // Date: bestDateText's range in the example.
        if let dt = r.bestDateText, let dr = text.range(of: dt),
           let idr = tokenRange(covering: dr) {
            assign[.date] = idr
        }

        // GN-029 REVISION: the four seeds above came from INDEPENDENT tokenRange(covering:)
        // calls with no cross-role dedup — unlike tapToken, which enforces "one token → one
        // category". A merchant-before-amount SMS with no stop punctuation (e.g.
        // "Purchase at LAZADA SGD 36.34") makes the `at ` anchor over-grab the merchant to
        // "LAZADA SGD 36.34", whose token range CONTAINS the currency + amount tokens. Left
        // overlapping, buildSpans → compile's overlap guard drops currency+amount and the
        // REQUIRED amount capture group is silently lost. Restore the same "one token → one
        // category" invariant tapToken upholds: dedup by PRIORITY — amount/currency/date win
        // over the greedy merchant, which is trimmed (or dropped) to exclude already-claimed
        // token ids. Pre-selection is only a convenience; the user can re-tap.
        assign = Self.dedupeAssignments(assign, priority: [.amount, .currency, .date, .merchant])

        // Seed editable texts + the fallback currency from the best guess.
        for role in Self.paintRoles { syncEditedText(role) }
        currencyFallback = r.bestCurrency ?? defaultBaseCurrency
        templateName = suggestedName(merchant: r.bestMerchant, type: transactionType)
        if defaultCategoryID != nil,
           !categoriesForType.contains(where: { $0.id == defaultCategoryID }) {
            defaultCategoryID = nil
        }
        // Default the brush to amount (the required field) so the user can immediately fix it.
        brush = .amount
        step = .confirm
    }

    // MARK: - GN-034 edit-mode load (PRE-SELECT the CURRENT rule's spans, not a fresh guess)

    /// GN-034: load `editingTemplate` for re-editing its detection rule. Mirrors goToConfirm()'s
    /// SHAPE (tokenize → seed assign → dedupe → sync texts → confirm step), but PRE-SELECTS each
    /// category's token range from what the template's CURRENT compiled rule ACTUALLY recognizes
    /// — SmsTemplateMatcher.matchSpans(exampleText, pattern, slotMap) — rather than re-guessing
    /// with SmsExtractor.extract (which could disagree with the saved rule and mislead the user).
    /// Output settings (name/type/category/currency) are loaded from the template; maskCardDigits
    /// can't be reverse-engineered from the compiled pattern → defaults to true (the editor's
    /// default; the user can toggle it before saving). Optional roles the rule doesn't capture
    /// (e.g. no .date slot) simply aren't pre-selected — same as a NEW template with no date.
    private func loadForEdit() {
        guard let t = editingTemplate else { return }
        didLoadForEdit = true

        // —— Load the stored example + output settings ——
        exampleText = t.exampleText
        templateName = t.name
        transactionType = TransactionType(rawValue: t.transactionTypeRaw) ?? .expense
        defaultCategoryID = t.defaultCategoryID
        currencyFallback = t.currencyFallback
        maskCardDigits = true   // see Gotcha — not recoverable from the compiled pattern.

        // —— Pre-select each role from the CURRENT rule's recognized spans ——
        let text = exampleText
        tokens = SmsTokenizer.tokenize(text)
        assign = [:]
        editedText = [:]

        // GN-052: one decoder for every consumer of a persisted rule (was an inline copy here).
        let slotMap = SmsTemplateMatcher.decodeSlotMap(t.slotMapJSON)
        let spans = SmsTemplateMatcher.matchSpans(text, pattern: t.compiledPattern, slotMap: slotMap)
        for role in Self.paintRoles {
            if let charRange = spans[role], let idr = tokenRange(covering: charRange) {
                assign[role] = idr
            }
        }
        // Keep the same "one token → one category" invariant the NEW path enforces. (matchSpans
        // returns disjoint capture-group ranges, so this is normally a no-op, but it costs nothing
        // and matches goToConfirm() exactly.)
        assign = Self.dedupeAssignments(assign, priority: [.amount, .currency, .date, .merchant])

        for role in Self.paintRoles { syncEditedText(role) }
        // Keep the default-category selection valid for the loaded type.
        if defaultCategoryID != nil,
           !categoriesForType.contains(where: { $0.id == defaultCategoryID }) {
            defaultCategoryID = nil
        }
        brush = .amount
        step = .confirm
    }

    // MARK: - Span derivation (GN-029: precise ranges from token selections)

    /// For each painted category, derive its precise character range from the covered tokens'
    /// ranges (tokens[lo].range.lowerBound ..< tokens[hi].range.upperBound). If the user edited
    /// the text below to a DIFFERENT non-empty string that IS locatable in the example, use that
    /// (range(of:) tweak); otherwise use the exact token range. Only 金额 is required (missing →
    /// not saveable); 币种/商户/日期 are optional.
    private func buildSpans() -> (spans: [(role: SlotRole, range: Range<String.Index>)],
                                  missing: [String]) {
        var spans: [(role: SlotRole, range: Range<String.Index>)] = []
        var missing: [String] = []

        for role in [SlotRole.currency, .amount, .merchant, .date] {
            guard let tokenR = stringRange(forRole: role) else {
                if role == .amount { missing.append(String(localized: "金额")) }
                continue
            }
            let tokenText = String(exampleText[tokenR])
            let edited = (editedText[role] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let finalRange: Range<String.Index> =
                (!edited.isEmpty && edited != tokenText)
                ? (exampleText.range(of: edited) ?? tokenR)
                : tokenR
            spans.append((role, finalRange))
        }

        // Sort by position; the compiler also guards against overlap/out-of-order.
        spans.sort { $0.range.lowerBound < $1.range.lowerBound }

        // GN-029 REVISION — overlap-aware amount guard (belt-and-suspenders so NO path can
        // save a template whose amount group the compiler would drop). The compiler's overlap
        // guard (SmsTemplateCompiler.swift:120) drops any span that starts before the running
        // cursor; sorted by lowerBound, an amount span CONTAINED in (or overlapping) an earlier
        // role's span (e.g. a greedy merchant) is silently dropped → the required amount
        // capture group is lost while canSave still thinks amount is "set". The pre-selection
        // dedup above prevents this for seeded ranges, but a user could also hand-edit the
        // amount/merchant text below to overlapping range(of:) spans. So: if the .amount span
        // CHAR-overlaps any other role's span, treat amount as missing → canSave false →
        // save() shows the "找不到金额" error instead of persisting a broken template.
        // (Two ranges overlap iff a.lowerBound < b.upperBound && b.lowerBound < a.upperBound.)
        if !missing.contains(String(localized: "金额")),
           let amt = spans.first(where: { $0.role == .amount })?.range,
           spans.contains(where: { $0.role != .amount
                                   && $0.range.lowerBound < amt.upperBound
                                   && amt.lowerBound < $0.range.upperBound }) {
            missing.append(String(localized: "金额"))
        }

        return (spans, missing)
    }

    /// Map a category's token-id range → the precise character range it covers.
    private func stringRange(forRole role: SlotRole) -> Range<String.Index>? {
        guard let ids = assign[role] else { return nil }
        return stringRange(forTokenIDs: ids)
    }

    /// token-id range → original String range (lo token's lowerBound ..< hi token's upperBound).
    private func stringRange(forTokenIDs ids: ClosedRange<Int>) -> Range<String.Index>? {
        guard let lo = tokens.first(where: { $0.id == ids.lowerBound })?.range.lowerBound,
              let hi = tokens.first(where: { $0.id == ids.upperBound })?.range.upperBound,
              lo <= hi else { return nil }
        return lo..<hi
    }

    /// GN-029 REVISION — PURE dedup over token-id ranges: enforce "one token → one category"
    /// for the pre-selected `assign` map (the invariant `tapToken` already upholds for user
    /// taps). Roles are resolved in `priority` order; each role claims its token ids, and any
    /// LATER role's range is trimmed to its LARGEST maximal contiguous run of still-unclaimed
    /// ids — or dropped entirely if no unclaimed id remains. The result's ranges are pairwise
    /// disjoint in token ids. Trimming (vs. dropping outright) keeps as much of the greedy
    /// merchant's pre-selection as can stay contiguous; the user can always re-tap. Pure →
    /// unit-testable without the view (mirrored + pinned in battlefield/tests/GN-029_dedup_test.swift).
    static func dedupeAssignments(_ assign: [SlotRole: ClosedRange<Int>],
                                  priority: [SlotRole]) -> [SlotRole: ClosedRange<Int>] {
        var result: [SlotRole: ClosedRange<Int>] = [:]
        var claimed = Set<Int>()
        // Visit priority roles first (in order), then any roles not listed in `priority`
        // (defensive — every paint role is normally listed).
        let ordered = priority + assign.keys.filter { !priority.contains($0) }
        for role in ordered {
            guard let range = assign[role] else { continue }
            // Walk the range, collecting maximal contiguous runs of unclaimed ids; keep the
            // longest run (earliest wins ties). A range with no unclaimed id is dropped.
            var best: ClosedRange<Int>? = nil
            var runStart: Int? = nil
            var prev: Int? = nil
            func closeRun(_ end: Int) {
                guard let s = runStart else { return }
                let run = s...end
                if best == nil || (run.count > best!.count) { best = run }
            }
            for id in range {
                if claimed.contains(id) {
                    if let p = prev { closeRun(p) }
                    runStart = nil
                } else if runStart == nil {
                    runStart = id
                }
                prev = id
            }
            if let p = prev, runStart != nil { closeRun(p) }
            if let kept = best {
                result[role] = kept
                for id in kept { claimed.insert(id) }
            }
            // else: every id was already claimed → this role keeps no pre-selection.
        }
        return result
    }

    /// Map a character range in the example to the minimal contiguous token-id range that COVERS
    /// it: the first token whose range overlaps/precedes span.lower through the last token whose
    /// range overlaps/exceeds span.upper. Used to pre-select from the extractor's best spans.
    private func tokenRange(covering span: Range<String.Index>) -> ClosedRange<Int>? {
        let selectable = tokens.filter { $0.isSelectable }
        // first selectable token whose upperBound is strictly past span.lowerBound (i.e. it
        // contains or starts at the span's start), and last whose lowerBound is before span.upper.
        guard let lo = selectable.first(where: { $0.range.upperBound > span.lowerBound })?.id,
              let hi = selectable.last(where: { $0.range.lowerBound < span.upperBound })?.id,
              lo <= hi else { return nil }
        return lo...hi
    }

    /// Currency token range for a given ISO code (the ISO code itself plus any symbol/native-word
    /// token mapping to it; earliest occurrence wins). Used only as a pre-selection helper.
    private func currencyTokenRange(for code: String) -> Range<String.Index>? {
        var toks: [String] = [code]
        toks += SmsExtractor.currencyTokens.filter { $0.code == code }.map { $0.token }
        var best: Range<String.Index>? = nil
        for tok in toks where !tok.isEmpty {
            if let r = exampleText.range(of: tok) {
                if best == nil || r.lowerBound < best!.lowerBound { best = r }
            }
        }
        return best
    }

    private var canSave: Bool {
        // Amount must be selected + locatable; template name non-empty. (Others optional.)
        let (_, missing) = buildSpans()
        return missing.isEmpty
            && !templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Save / self-check (PRESERVED — still compiles + self-checks)

    private func save() {
        let (spans, missing) = buildSpans()
        guard missing.isEmpty else {
            saveError = String(localized: "请先选中「\(missing.joined(separator: "、"))」。")
            return
        }

        let compiled = SmsTemplateCompiler.compile(
            example: exampleText, spans: spans, cardMask: maskCardDigits)

        // Encode slotMap (capture-group order → role rawValues) as JSON, e.g.
        // ["currency","amount","merchant"] — symmetric with the B2 decoder + B1 seeder.
        let roleStrings = compiled.slotMap.map { $0.rawValue }
        let slotMapJSON = (try? JSONEncoder().encode(roleStrings))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let trimmedName = templateName.trimmingCharacters(in: .whitespacesAndNewlines)

        // GN-034: EDIT mode OVERWRITES the existing template in place (applyEdits preserves its
        // id / orderIndex / isEnabled / isBuiltInPreset / createdAt — no duplicate row); NEW mode
        // inserts a fresh template (orderIndex = max existing + 1), exactly as before.
        // GN-052: whichever branch ran, keep the persisted template so the post-save rescan can
        // re-run it over the inbox's already-landed unrecognized drafts.
        let savedTemplate: SmsTemplate
        if let t = editingTemplate {
            Self.applyEdits(
                to: t,
                name: trimmedName,
                compiledPattern: compiled.pattern,
                slotMapJSON: slotMapJSON,
                transactionTypeRaw: transactionType.rawValue,
                defaultCategoryID: defaultCategoryID,
                currencyFallback: currencyFallback,
                suggestedTriggerKeyword: compiled.suggestedTriggerKeyword,
                exampleText: exampleText
            )
            try? modelContext.save()
            savedTemplate = t
        } else {
            let nextOrder = (existingTemplates.map { $0.orderIndex }.max() ?? -1) + 1
            let template = SmsTemplate(
                name: trimmedName,
                orderIndex: nextOrder,
                isEnabled: true,
                compiledPattern: compiled.pattern,
                slotMapJSON: slotMapJSON,
                transactionTypeRaw: transactionType.rawValue,
                defaultCategoryID: defaultCategoryID,
                currencyFallback: currencyFallback,
                suggestedTriggerKeyword: compiled.suggestedTriggerKeyword,
                isBuiltInPreset: false,
                // GN-032: store the example so the metadata sheet can show "当时怎么设的" with the
                // amount/currency/merchant/date spans highlighted (recovered via matchSpans). GN-039:
                // in EMAIL mode exampleText is the PREPROCESSED key segment (goToConfirm replaced it),
                // which is exactly the text the runtime matcher will see — anchors line up.
                exampleText: exampleText,
                // GN-039: tag the path so the runtime tries this template ONLY for that input kind
                // (IngestUOBMessageIntent fetches inputKind=="sms"; IngestEmailIntent "email").
                inputKind: initialInputKind
            )
            modelContext.insert(template)
            try? modelContext.save()
            savedTemplate = template
        }

        // Self-check (both modes): run the matcher on the ORIGINAL example and show what the
        // (possibly re-edited) rule now recognizes, so the user sees it works before dismissing.
        selfCheck = SmsTemplateMatcher.matchOne(
            exampleText, pattern: compiled.pattern, slotMap: compiled.slotMap)

        // Show the "saved" confirmation IMMEDIATELY — the template is already persisted, and the
        // rescan below may need an FX lookup (15 s network timeout worst case). Nothing about the
        // save should wait on that.
        showSelfCheck = true

        // GN-052 Task 2 — the fix for "我建完模版,再放同一条短信仍说没识别到". The unrecognized
        // draft the user built this template FROM is already sitting in the inbox; before GN-052
        // nothing ever re-ran a new rule over it ("下一条短信才会匹配"), so the user's own SMS
        // stayed unrecognized and the template looked broken. Now every successful save — NEW and
        // EDIT alike — re-runs the saved template over those drafts. Matching goes through the
        // shared runtime on the PERSISTED slotMapJSON (never a second engine, and it proves the
        // JSON round-trip). Non-matching drafts are left untouched; matching ones are upgraded IN
        // PLACE so nothing can be lost or duplicated.
        //
        // Runs DETACHED from the alert: the inbox is the authoritative surface for the result (its
        // @Query re-renders the upgraded row as soon as this lands). The count in the alert is a
        // best-effort nicety — if the rescan outlives the alert the user simply doesn't see the
        // line, and never sees a wrong one.
        Task { @MainActor in
            rescanUpgradedCount = await SmsRecognitionRuntime.rescanUnrecognizedDrafts(
                with: savedTemplate, in: modelContext)
        }
    }

    // MARK: - Self-check message (PRESERVED)

    private var selfCheckMessage: String {
        guard let f = selfCheck else {
            // Saved, but the compiled pattern didn't re-match its own example (rare; e.g.
            // the user typed values that overlap oddly). Still saved — say so honestly.
            return String(localized: "模版已保存，但用示例自检时未能重新识别。你可以稍后在模版列表里编辑。")
        }
        let cur = (f.currency ?? currencyFallback)
        let amt = f.amount.map { formatBase($0, code: cur) } ?? "—"
        let merch = f.merchantRaw.map { UOBMessageParser.displayName(from: $0) } ?? "—"
        let dateStr = f.date.map { Self.previewDateFormatter.string(from: $0) } ?? "—"
        var msg = String(localized: "✓ 这条模版能认出示例：金额 \(amt)／币种 \(cur)／商户 \(merch)／日期 \(dateStr)")
        // GN-052 Task 2: tell the user their already-received SMS was just picked up, so the
        // inbox change isn't a surprise (and, when it's 0, they aren't left expecting one).
        if rescanUpgradedCount > 0 {
            msg += "\n\n" + String(localized: "收件箱里有 \(rescanUpgradedCount) 条之前未识别的短信已被这条模版认出，现在可以直接确认了。")
        }
        return msg
    }

    // MARK: - GN-029 parse previews per category

    /// A small parse/normalize preview under each selected category's editable text, mirroring
    /// what the engine will extract: amount → AmountParser, currency → ISO, date → DateParser,
    /// merchant → display name (channel prefix stripped). nil = no preview line.
    private func parsePreview(_ role: SlotRole) -> String? {
        let text = effectiveText(role)
        guard !text.isEmpty else { return nil }
        switch role {
        case .amount:
            if let d = AmountParser.parse(text) {
                return "= " + formatBase(d, code: currencyEffectiveCode)
            }
            return String(localized: "无法解析金额")
        case .currency:
            return "= " + currencyEffectiveCode
        case .date:
            if let d = DateParser.parse(text, now: .now) {
                return "= " + Self.previewDateFormatter.string(from: d)
            }
            return String(localized: "无法解析，将用短信到达时刻")
        case .merchant:
            let disp = UOBMessageParser.displayName(from: text)
            return disp == text ? nil : "= " + disp
        case .cardMask:
            return nil
        }
    }

    /// The effective text for a category (edited override if present, else the token substring).
    private func effectiveText(_ role: SlotRole) -> String {
        let edited = (editedText[role] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !edited.isEmpty { return edited }
        if let r = stringRange(forRole: role) {
            return String(exampleText[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// The currency code the previews/self-check should display: the painted currency token
    /// normalized to ISO if recognizable, else the fallback.
    private var currencyEffectiveCode: String {
        let tok = effectiveText(.currency)
        guard !tok.isEmpty else { return currencyFallback }
        if tok.count == 3, tok.allSatisfy({ $0.isASCII && $0.isLetter }) { return tok.uppercased() }
        return SmsExtractor.currencyTokens.first { $0.token == tok }?.code ?? currencyFallback
    }

    // MARK: - Category label / color (GN-029)

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

    /// Localized medium-date preview formatter (follows the system language, like the rest of
    /// the app's date display — GN-023 i18n). Computed once.
    private static let previewDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    // MARK: - Misc helpers (PRESERVED)

    private var defaultBaseCurrency: String {
        AppSettings.current(in: modelContext).baseCurrencyCode
    }

    private var categoriesForType: [Category] {
        categories.filter { $0.kind == (transactionType == .expense ? .expense : .income) }
                  .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Auto-suggested name: the merchant's first word (split on space/* punctuation) + the
    /// type word, e.g. "fp*Food Panda" + 支出 → "fp 支出"; nil merchant → "我的银行 支出".
    private func suggestedName(merchant: String?, type: TransactionType) -> String {
        let typeWord = type == .expense ? String(localized: "支出") : String(localized: "收入")
        if let m = merchant {
            let firstWord = m.split(whereSeparator: { $0 == " " || $0 == "*" }).first.map(String.init)
            if let w = firstWord, !w.isEmpty { return "\(w) \(typeWord)" }
        }
        return "\(String(localized: "我的银行")) \(typeWord)"
    }
}
