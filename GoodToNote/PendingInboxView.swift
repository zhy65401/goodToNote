//
//  PendingInboxView.swift
//  GoodToNote
//
//  GN-005 / GN-025 (Phase B, Task B3) — The pending-draft inbox. Lists isPending=true
//  drafts silently written by IngestUOBMessageIntent. There are now TWO kinds of draft:
//
//  • RECOGNIZED (originalAmount > 0): a template matched the SMS. Rendered exactly as
//    before (GN-005/015/018):
//      - Accept → pick a category (old merchant preselects MerchantMemory's last category,
//        editable, none = uncategorized) → flip isPending=false (enters the ledger) +
//        set category + MerchantMemory.remember(raw→final) + save.
//      - Reject → modelContext.delete(draft) + save (NOT remembered).
//
//  • UNRECOGNIZED (GN-025 B2 no-match original-text draft: originalAmount == 0 &&
//    merchant nil/empty — the full SMS is in `note`). NO template matched. Rendered
//    distinctly (⚠️ 未识别短信 header + raw-text preview) with TWO actions:
//      - 【用这条短信建模版】 → SmsTemplateEditorView(prefillText: draft.note) (the C1
//        editor pre-filled with this SMS). After building a template the unrecognized
//        draft STAYS in the inbox (v1 does NOT re-run the new template on the old draft —
//        the NEXT incoming SMS will match); the user can then 拒绝 it or 手动补一笔.
//      - 【手动补一笔】 → TransactionEditView(target: .add, onSaved: delete this draft).
//        Chosen wiring: reuse the existing add-transaction sheet verbatim; the raw SMS is
//        visible in the draft's note for reference. On a SUCCESSFUL save the editor calls
//        the onSaved hook (additive, defaulted nil — no LedgerView change) which deletes
//        this unrecognized draft. Cancel → draft remains (nothing lost).
//
//  Drafts shown here are the ONLY place isPending txns are visible; the ledger query
//  excludes them so they don't count toward any total/subtotal until accepted.
//
//  Custom Button rows use .contentShape(Rectangle()) (project memory:
//  tappable-row-contentshape — this is the inbox, the exact place GN-015 first hit the
//  "only the left half is tappable" bug).
//

import SwiftUI
import SwiftData

struct PendingInboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let categories: [Category]

    @Query(filter: #Predicate<Transaction> { $0.isPending },
           sort: \Transaction.date, order: .reverse) private var drafts: [Transaction]
    // GN-025 B3: ledger (non-pending) txns, used only to compute lastRateByCurrency for the
    // 手动补一笔 add sheet (mirrors LedgerView). Read-only; never mutated here.
    @Query(filter: #Predicate<Transaction> { !$0.isPending },
           sort: \Transaction.date, order: .reverse) private var ledgerTxns: [Transaction]

    @State private var acceptTarget: Transaction?
    /// GN-025 B3: drives the 【建模版】 editor sheet (the unrecognized SMS text to prefill).
    @State private var buildTemplateText: String?
    /// GN-025 B3: the unrecognized draft being 手动补一笔'd (its add sheet is showing).
    @State private var manualAddDraft: Transaction?

    /// 某币种最近一次用过的汇率（喂编辑表单预填）— same derivation as LedgerView.
    private var lastRateByCurrency: [String: Decimal] {
        var map: [String: Decimal] = [:]
        for t in ledgerTxns where map[t.currencyCode] == nil { map[t.currencyCode] = t.fxRateToSGD }
        return map
    }

    /// An "unrecognized" draft = the original-text draft B2 writes on no-match.
    private func isUnrecognized(_ d: Transaction) -> Bool {
        d.originalAmount == 0 && (d.merchant == nil || d.merchant == "")
    }

    /// GN-039 (was GN-036): every de-dup CANDIDATE row, mapped to plain DuplicateDetector.Row
    /// tuples (computed each render so it always reflects the latest data; nothing stored). The
    /// three-way detector anchors on applePay/sms/email, so we include BOTH the ledgered rows of
    /// those sources AND the OTHER pending drafts (sms ⇄ email cross-flagging). `key` = the row's
    /// stable UUID string (the deterministic tiebreaker so a same-instant sms/email pair flags
    /// exactly once). We pass ONE flat list per draft scan; the draft's own row is skipped by key.
    private var dedupCandidateRows: [DuplicateDetector.Row] {
        let anchors = DuplicateDetector.anchorSources
        // Ledgered rows of a capture source (always-winning anchors).
        let ledgerRows = ledgerTxns
            .filter { anchors.contains($0.source) }
            .map { DuplicateDetector.Row(amount: $0.originalAmount, currency: $0.currencyCode,
                                         date: $0.date, source: $0.source, isPending: false,
                                         key: $0.id.uuidString) }
        // Other PENDING drafts that carry a real amount (unrecognized amount-0 drafts can't be a
        // purchase match) — these enable sms ⇄ email cross-flagging.
        let pendingRows = drafts
            .filter { anchors.contains($0.source) && $0.originalAmount != 0 }
            .map { DuplicateDetector.Row(amount: $0.originalAmount, currency: $0.currencyCode,
                                         date: $0.date, source: $0.source, isPending: true,
                                         key: $0.id.uuidString) }
        return ledgerRows + pendingRows
    }

    /// GN-039 (was GN-036): true when this RECOGNIZED draft (SMS or EMAIL) looks like the SAME
    /// purchase already captured elsewhere — an accepted applePay/sms/email ledger row, OR a
    /// DIFFERENT-source EARLIER pending draft (sms ⇄ email). Same original amount + currency,
    /// within ±15 min (applePay ⇄ sms) or ±60 min (any email row). Flag only — accept/reject
    /// buttons are unchanged; the user decides. Unrecognized drafts (amount 0) never match. Of a
    /// same-purchase pending pair only the later-arriving draft is flagged (no double-flag).
    /// Runtime-computed, never persisted.
    private func isSuspectedDuplicate(_ d: Transaction) -> Bool {
        guard !isUnrecognized(d) else { return false }
        return DuplicateDetector.isSuspectedDuplicateThreeWay(
            draft: DuplicateDetector.Row(amount: d.originalAmount, currency: d.currencyCode,
                                         date: d.date, source: d.source, isPending: true,
                                         key: d.id.uuidString),
            against: dedupCandidateRows)
    }

    var body: some View {
        NavigationStack {
            Group {
                if drafts.isEmpty {
                    ContentUnavailableView("没有待确认", systemImage: "tray",
                        description: Text("银行短信或邮件自动录入的待确认草稿会出现在这里。"))
                } else {
                    List {
                        ForEach(drafts) { d in
                            if isUnrecognized(d) {
                                unrecognizedRow(d)
                            } else {
                                draftRow(d)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("待确认收件箱")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $acceptTarget) { draft in
                AcceptDraftSheet(draft: draft, categories: categories)
            }
            // 【用这条短信建模版】 → C1 editor prefilled with the unrecognized SMS.
            .sheet(item: Binding(get: { buildTemplateText.map(IdentifiedText.init) },
                                 set: { buildTemplateText = $0?.text })) { item in
                SmsTemplateEditorView(prefillText: item.text)
            }
            // 【手动补一笔】 → existing add sheet; on save, delete the unrecognized draft.
            .sheet(item: $manualAddDraft) { draft in
                TransactionEditView(target: .add, categories: categories,
                                    lastRateByCurrency: lastRateByCurrency,
                                    onSaved: {
                                        modelContext.delete(draft)
                                        try? modelContext.save()
                                    })
            }
        }
    }

    // MARK: - Recognized draft row (UNCHANGED behavior — GN-005/015/018)

    private func draftRow(_ d: Transaction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.merchant.map(UOBMessageParser.displayName(from:)) ?? "未知商户")
                        .font(.body.weight(.medium))
                    Text(dateLabel(d.date)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatBase(d.sgdAmount, code: AppSettings.current(in: modelContext).baseCurrencyCode))
                        .font(.body.weight(.semibold))
                    if d.currencyCode != AppSettings.current(in: modelContext).baseCurrencyCode {
                        // GN-024: 原币显式币种前缀（formatBase 直吃 Decimal）；「汇率待补」走单键 "%@ · 汇率待补"。
                        let orig = formatBase(d.originalAmount, code: d.currencyCode)
                        Text(d.needsFxRate ? String(localized: "\(orig) · 汇率待补") : orig)
                            .font(.caption2)
                            .foregroundStyle(d.needsFxRate ? .orange : .secondary)
                    }
                }
            }
            // GN-036/GN-039: 疑似与已记的另一笔(Apple Pay / 短信 / 邮件)同一笔重复 → 醒目提示让用户
            // 把关(绝不自动丢账)。三路去重:同金额、同币种、时间相近(邮件 ±60 分钟,其余 ±15 分钟)。
            if isSuspectedDuplicate(d) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("可能与已记的另一笔交易重复(同金额、同币种、时间相近)。若确属同一笔请拒绝。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 12) {
                Button {
                    acceptTarget = d
                } label: {
                    Label("接受", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(role: .destructive) {
                    reject(d)
                } label: {
                    Label("拒绝", systemImage: "trash")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Unrecognized draft row (GN-025 B3)

    private func unrecognizedRow(_ d: Transaction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("未识别短信").font(.body.weight(.medium))
                Spacer()
                Text(dateLabel(d.date)).font(.caption).foregroundStyle(.secondary)
            }
            // Raw SMS preview (the full text is in note); truncate to a few lines.
            Text(d.note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Button {
                    buildTemplateText = d.note
                } label: {
                    Label("用这条短信建模版", systemImage: "wand.and.stars")
                        .font(.subheadline)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)

                Button {
                    manualAddDraft = d
                } label: {
                    Label("手动补一笔", systemImage: "square.and.pencil")
                        .font(.subheadline)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            // The unrecognized draft stays after building a template; let the user clear it.
            Button(role: .destructive) {
                reject(d)
            } label: {
                Label("拒绝", systemImage: "trash")
                    .font(.subheadline)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func reject(_ draft: Transaction) {
        modelContext.delete(draft)
        try? modelContext.save()
    }

    private func dateLabel(_ d: Date) -> String {
        d.formatted(.dateTime.year().month().day())
    }
}

/// Wraps an unrecognized SMS string so it can drive a `.sheet(item:)` (which needs
/// Identifiable). Identity = the text itself (fine: one editor sheet at a time).
private struct IdentifiedText: Identifiable {
    let text: String
    var id: String { text }
}

/// Accept sheet: category picker (old merchant preselected via MerchantMemory).
private struct AcceptDraftSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let draft: Transaction
    let categories: [Category]

    @State private var selectedCategoryID: UUID?
    @State private var didInitSelection = false

    var body: some View {
        NavigationStack {
            Form {
                Section("商户") {
                    Text(draft.merchant.map(UOBMessageParser.displayName(from:)) ?? "未知商户")
                    Text(formatBase(draft.sgdAmount, code: AppSettings.current(in: modelContext).baseCurrencyCode))   // GN-024: 显式币种前缀, Decimal direct
                        .foregroundStyle(.secondary)
                }
                Section("分类（不选 = 未分类）") {
                    Button {
                        selectedCategoryID = nil
                    } label: {
                        HStack {
                            Text("未分类")
                            Spacer()
                            if selectedCategoryID == nil { Image(systemName: "checkmark") }
                        }
                        // GN-015 Bug1: 整行(含右侧空白)都参与命中,任意位置可点切换。
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    ForEach(categories.filter { $0.kind == .expense }) { c in
                        Button {
                            selectedCategoryID = c.id
                        } label: {
                            HStack {
                                Text("\(c.icon) \(c.name)")
                                Spacer()
                                if selectedCategoryID == c.id { Image(systemName: "checkmark") }
                            }
                            // GN-015 Bug1: 整行(含右侧空白)都参与命中,任意位置可点切换。
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("接受这一笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定") { accept() }
                }
            }
            .onAppear(perform: initSelection)
        }
    }

    /// Preselect the remembered category for this merchant (raw key), if any.
    private func initSelection() {
        guard !didInitSelection else { return }
        didInitSelection = true
        if let raw = draft.merchant,
           let suggested = MerchantMemory.suggestedCategory(forRaw: raw, in: modelContext) {
            selectedCategoryID = suggested.id
        }
    }

    private func accept() {
        let cat = selectedCategoryID.flatMap { id in categories.first { $0.id == id } }
        draft.category = cat
        draft.isPending = false                       // promote into the ledger
        if let raw = draft.merchant {
            MerchantMemory.remember(rawMerchant: raw, category: cat, in: modelContext)
        }
        try? modelContext.save()
        dismiss()
    }
}
