//
//  RecurringRulesView.swift
//  GoodToNote
//
//  GN-006 — 周期交易管理：从设置进入，对 RecurringRule 做查 / 增 / 改 / 删 / 启停。
//  纯 SwiftData CRUD，背靠既有的 RecurringRule @Model（不新增字段 → 无 store 迁移）。
//  结算（按 nextDate 回补生成交易）由 RecurringRuleGenerator 在启动时完成，不在本视图。
//
//  删除规则不删除已生成的交易（它们是独立的流水条目）。停用（isActive=off）后下次启动不再生成。
//

import SwiftUI
import SwiftData

// MARK: - List

struct RecurringRulesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurringRule.nextDate) private var rules: [RecurringRule]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var editTarget: RecurringRuleEditTarget?
    @State private var pendingDelete: RecurringRule?

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var body: some View {
        List {
            if rules.isEmpty {
                Text("暂无周期交易。点右上角 + 新增。").foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    row(rule)
                }
            }
        }
        .navigationTitle("周期交易")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editTarget = .add } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新增周期交易")
            }
        }
        .sheet(item: $editTarget) { target in
            RecurringRuleEditSheet(target: target, categories: categories)
        }
        .confirmationDialog("删除此周期规则不会删除已生成的交易。",
                            isPresented: deleteBinding, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let r = pendingDelete { modelContext.delete(r); try? modelContext.save() }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
    }

    @ViewBuilder
    private func row(_ rule: RecurringRule) -> some View {
        HStack(spacing: 12) {
            Button {
                editTarget = .edit(rule)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(rule.note.isEmpty ? (rule.merchant ?? "周期交易") : rule.note)
                            .foregroundStyle(.primary)
                        if let m = rule.merchant, !m.isEmpty, !rule.note.isEmpty {
                            Text(m).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(amountString(rule))
                        Text(periodLabel(rule.period))
                        Text("下次：\(Self.dateFmt.string(from: rule.nextDate))")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Toggle("", isOn: Binding(
                get: { rule.isActive },
                set: { rule.isActive = $0; try? modelContext.save() }
            ))
            .labelsHidden()
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { pendingDelete = rule } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// GN-024: 原币金额走 formatBase（Decimal direct，显式币种前缀），消除 GN-023 残留的 doubleValue。
    private func amountString(_ rule: RecurringRule) -> String {
        formatBase(rule.amount, code: rule.currencyCode)
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

/// 周期标签本地化。GN-023: 全局函数返回纯 String → 显式 String(localized:)。
func periodLabel(_ period: RecurrencePeriod) -> String {
    switch period {
    case .daily:   return String(localized: "每天")
    case .weekly:  return String(localized: "每周")
    case .monthly: return String(localized: "每月")
    case .yearly:  return String(localized: "每年")
    }
}

// MARK: - Add / Edit sheet

/// sheet 的两种模式。Identifiable 以配合 .sheet(item:)。
enum RecurringRuleEditTarget: Identifiable {
    case add
    case edit(RecurringRule)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let r): return r.id.uuidString
        }
    }
}

struct RecurringRuleEditSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let target: RecurringRuleEditTarget
    let categories: [Category]

    @State private var type: TransactionType = .expense
    @State private var amountText = ""
    @State private var currencyCode = "SGD"   // GN-026: 新建规则 load() 时改取本位币（对齐 TransactionEditView）
    @State private var note = ""
    @State private var merchant = ""
    @State private var period: RecurrencePeriod = .monthly
    @State private var nextDate = Date()
    @State private var isActive = true
    @State private var selectedCategoryID: UUID?
    @State private var showCurrencyPicker = false

    private var editing: RecurringRule? {
        if case .edit(let r) = target { return r }; return nil
    }
    /// GN-026: 当前本位币（老库兜底 SGD）。新建规则默认币种取它，对齐 TransactionEditView.load。
    private var baseCode: String { AppSettings.current(in: modelContext).baseCurrencyCode }
    private var availableCategories: [Category] {
        categories.filter { $0.kind == (type == .expense ? .expense : .income) }
                  .sorted { $0.sortOrder < $1.sortOrder }
    }
    private var amount: Decimal { Decimal(string: amountText) ?? 0 }
    private var canSave: Bool {
        amount > 0 && !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $type) {
                    Text("支出").tag(TransactionType.expense)
                    Text("收入").tag(TransactionType.income)
                }.pickerStyle(.segmented)
                .onChange(of: type) { _, _ in
                    if let sel = selectedCategoryID,
                       !availableCategories.contains(where: { $0.id == sel }) {
                        selectedCategoryID = availableCategories.first?.id
                    } else if selectedCategoryID == nil {
                        selectedCategoryID = availableCategories.first?.id
                    }
                }

                Section("金额") {
                    HStack {
                        TextField("0.00", text: $amountText).keyboardType(.decimalPad)
                        Button(currencyCode) { showCurrencyPicker = true }
                            .buttonStyle(.bordered)
                    }
                }

                Section("分类") {
                    Picker("分类", selection: $selectedCategoryID) {
                        Text("未分类").tag(UUID?.none)
                        ForEach(availableCategories) { c in
                            Text("\(c.icon) \(c.name)").tag(Optional(c.id))
                        }
                    }
                }

                Section("周期") {
                    Picker("周期", selection: $period) {
                        ForEach(RecurrencePeriod.allCases) { p in
                            Text(periodLabel(p)).tag(p)
                        }
                    }
                    DatePicker("下次日期", selection: $nextDate, displayedComponents: .date)
                }

                Section {
                    TextField("备注", text: $note)
                    TextField("商户", text: $merchant)
                    Toggle("启用", isOn: $isActive)
                }
            }
            .navigationTitle(editing == nil ? "新增周期交易" : "编辑周期交易")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }.disabled(!canSave)
                }
            }
            .sheet(isPresented: $showCurrencyPicker) {
                CurrencyPickerSheet(selected: currencyCode) { picked in
                    currencyCode = picked
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        if let r = editing {
            type = r.type
            amountText = (r.amount as NSDecimalNumber).stringValue
            currencyCode = r.currencyCode
            note = r.note
            merchant = r.merchant ?? ""
            period = r.period
            nextDate = r.nextDate
            isActive = r.isActive
            selectedCategoryID = r.category?.id
        } else {
            currencyCode = baseCode          // GN-026: 新建规则默认本位币（非写死 SGD）
            selectedCategoryID = availableCategories.first?.id
        }
    }

    private func save() {
        let cat = categories.first { $0.id == selectedCategoryID }
        let m = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = editing {
            r.type = type
            r.amount = amount
            r.currencyCode = currencyCode
            r.note = n
            r.merchant = m.isEmpty ? nil : m
            r.period = period
            r.nextDate = nextDate
            r.isActive = isActive
            r.category = cat
        } else {
            let r = RecurringRule(
                type: type,
                amount: amount,
                currencyCode: currencyCode,
                note: n,
                merchant: m.isEmpty ? nil : m,
                period: period,
                nextDate: nextDate,
                lastGeneratedDate: nil,
                isActive: isActive,
                category: cat
            )
            modelContext.insert(r)
        }
        try? modelContext.save()
        dismiss()
    }
}
