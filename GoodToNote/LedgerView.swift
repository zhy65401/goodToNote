//
//  LedgerView.swift
//  GoodToNote
//
//  GN-009 — Phase 1 流水 tab. Loads all transactions via @Query and does
//  in-memory month + category filtering and summation (321+ rows, trivial).
//  Month total + month switcher + date-grouped list + category multi-select
//  filter + per-category subtotals. ALL totals/subtotals sum `sgdAmount`
//  (the mixed-currency-correct field). Taps a row -> edit sheet; + -> add sheet.
//

import SwiftUI
import SwiftData

struct LedgerView: View {
    @Environment(\.modelContext) private var modelContext
    // GN-005: EXCLUDE isPending drafts from the ledger query — they must never appear
    // in the list nor count toward month total / category subtotals / any statistic.
    // Pending drafts live only in the inbox (PendingInboxView) until accepted.
    @Query(filter: #Predicate<Transaction> { !$0.isPending },
           sort: \Transaction.date, order: .reverse) private var allTxns: [Transaction]
    // GN-005: separate query just to count pending drafts for the inbox entry badge.
    @Query(filter: #Predicate<Transaction> { $0.isPending }) private var pendingTxns: [Transaction]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var showInbox = false

    /// 选中月份的锚点（该月任意一天）。默认今天。
    @State private var monthAnchor: Date = Date()
    @State private var editingTarget: EditTarget?
    @State private var selectedCategoryIDs: Set<UUID> = []
    @State private var showFilter = false

    private var cal: Calendar { .current }

    /// 当月 [start, nextStart)。
    private var monthRange: (start: Date, end: Date) {
        let start = cal.date(from: cal.dateComponents([.year, .month], from: monthAnchor))!
        let end = cal.date(byAdding: .month, value: 1, to: start)!
        return (start, end)
    }

    /// 先按月、再按所选分类过滤。
    private var monthTxns: [Transaction] {
        let r = monthRange
        return allTxns.filter { t in
            guard t.date >= r.start && t.date < r.end else { return false }
            guard !selectedCategoryIDs.isEmpty else { return true }
            guard let cid = t.category?.id else { return false }
            return selectedCategoryIDs.contains(cid)
        }
    }

    private var expenseTotal: Decimal {
        monthTxns.filter { $0.type == .expense }.reduce(0) { $0 + $1.sgdAmount }
    }
    private var incomeTotal: Decimal {
        monthTxns.filter { $0.type == .income }.reduce(0) { $0 + $1.sgdAmount }
    }

    /// 按日分组，日期倒序；组内倒序。
    private var grouped: [(day: Date, items: [Transaction])] {
        let dict = Dictionary(grouping: monthTxns) { cal.startOfDay(for: $0.date) }
        return dict.map { (day: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    /// 按分类小计（仅在有筛选时展示），口径 = sgdAmount。
    private var subtotalsByCategory: [(category: Category, total: Decimal)] {
        guard !selectedCategoryIDs.isEmpty else { return [] }
        var map: [UUID: Decimal] = [:]
        for t in monthTxns { if let c = t.category { map[c.id, default: 0] += t.sgdAmount } }
        return categories.filter { selectedCategoryIDs.contains($0.id) && map[$0.id] != nil }
            .map { ($0, map[$0.id]!) }
    }

    /// 某币种最近一次用过的汇率（喂编辑表单预填）。
    private var lastRateByCurrency: [String: Decimal] {
        var map: [String: Decimal] = [:]
        for t in allTxns {            // allTxns 已按 date 倒序：首次见即最近
            if map[t.currencyCode] == nil { map[t.currencyCode] = t.fxRateToSGD }
        }
        return map
    }

    private var monthLabel: String {
        monthRange.start.formatted(.dateTime.year().month())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if !pendingTxns.isEmpty { pendingInboxEntry }
                if !subtotalsByCategory.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(subtotalsByCategory, id: \.category.id) { item in
                                Text("\(item.category.icon)\(item.category.name) \(sgd(item.total))")
                                    .font(.caption).padding(6)
                                    .background(.thinMaterial, in: Capsule())
                            }
                        }.padding(.horizontal)
                    }
                    .padding(.bottom, 6)
                }
                if monthTxns.isEmpty {
                    ContentUnavailableView("本月暂无记录", systemImage: "tray",
                        description: Text("点右上角 + 记一笔。")).frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(grouped, id: \.day) { group in
                            Section(dayLabel(group.day)) {
                                ForEach(group.items) { t in
                                    Button { editingTarget = .edit(t) } label: {
                                        row(t).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                .onDelete { offsets in
                                    for i in offsets { modelContext.delete(group.items[i]) }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("流水")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showFilter = true } label: {
                        Image(systemName: selectedCategoryIDs.isEmpty
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editingTarget = .add } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editingTarget) { target in
                TransactionEditView(target: target, categories: categories,
                                    lastRateByCurrency: lastRateByCurrency)
            }
            .sheet(isPresented: $showInbox) {
                PendingInboxView(categories: categories)
            }
            .sheet(isPresented: $showFilter) {
                CategoryFilterSheet(categories: categories, selectedCategoryIDs: $selectedCategoryIDs)
            }
        }
    }

    private var header: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            VStack {
                Text(monthLabel).font(.headline)
                HStack(spacing: 16) {
                    // GN-023: "支出 %@" / "收入 %@" keys; sgd() now locale-aware currency (Decimal direct).
                    Text("支出 \(sgd(expenseTotal))").foregroundStyle(.red)
                    Text("收入 \(sgd(incomeTotal))").foregroundStyle(.green)
                }.font(.subheadline)
            }
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    /// GN-005: tappable entry to the pending inbox, with a red count badge.
    private var pendingInboxEntry: some View {
        Button { showInbox = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill")
                Text("\(pendingTxns.count) 笔待确认")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(pendingTxns.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal).padding(.bottom, 6)
        }
        .buttonStyle(.plain)
    }

    private func row(_ t: Transaction) -> some View {
        HStack {
            Text(t.category?.icon ?? "❓")
            VStack(alignment: .leading) {
                Text(t.category?.name ?? String(localized: "未分类"))
                if let m = t.merchant, !m.isEmpty {
                    Text(m).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing) {
                HStack(spacing: 4) {
                    // GN-004: 汇率待补的笔给一个角标,提示用户点进去补汇率。
                    if t.needsFxRate {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Text("\(t.type == .expense ? "-" : "+")\(sgd(t.sgdAmount))")
                        .foregroundStyle(t.type == .expense ? Color.primary : Color.green)
                }
                if t.currencyCode != AppSettings.current(in: modelContext).baseCurrencyCode {
                    // GN-024: 原币显示用显式币种前缀（formatBase 直吃 Decimal）。
                    // 「汇率待补」走单键 "%@ · 汇率待补"（String(localized:)，避免行内中文拼接漏译）。
                    let orig = formatBase(t.originalAmount, code: t.currencyCode)
                    Text(t.needsFxRate ? String(localized: "\(orig) · 汇率待补") : orig)
                        .font(.caption2)
                        .foregroundStyle(t.needsFxRate ? Color.orange : Color.secondary)
                }
            }
        }
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: monthAnchor) { monthAnchor = d }
    }
    private func dayLabel(_ d: Date) -> String {
        d.formatted(.dateTime.month().day().weekday())
    }
    /// GN-024: 本位币金额显示（显式币种前缀，读 AppSettings 当前本位币）。
    private func sgd(_ v: Decimal) -> String {
        formatBase(v, code: AppSettings.current(in: modelContext).baseCurrencyCode)
    }
}

/// 编辑 sheet 的目标：新增或编辑某笔。
enum EditTarget: Identifiable {
    case add
    case edit(Transaction)
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let t): return t.id.uuidString
        }
    }
}
