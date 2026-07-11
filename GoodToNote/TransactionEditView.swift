//
//  TransactionEditView.swift
//  GoodToNote
//
//  GN-009 — Phase 1 add/edit/delete transaction sheet. Type, amount, category,
//  date, currency dropdown with manual FX rate for non-SGD (live SGD preview),
//  merchant, note. Amounts parsed via Decimal(string:) (never Double). On edit,
//  changing amount/rate calls Transaction.recomputeSGDAmount() to keep the
//  redundant sgdAmount consistent.
//

import SwiftUI
import SwiftData

struct TransactionEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let target: EditTarget
    let categories: [Category]
    let lastRateByCurrency: [String: Decimal]
    /// GN-025 B3: optional hook called right after a successful save (NOT on cancel/delete).
    /// Defaults to nil so existing call sites (LedgerView) are unaffected — additive, no
    /// signature break. The pending inbox passes a closure that deletes the unrecognized
    /// original-text draft once the user has manually filled in a transaction (手动补一笔).
    var onSaved: (() -> Void)? = nil

    @State private var type: TransactionType = .expense
    @State private var amountText: String = ""
    @State private var currencyCode: String = "SGD"
    @State private var rateText: String = "1"
    @State private var date: Date = Date()
    @State private var merchant: String = ""
    @State private var note: String = ""
    @State private var selectedCategoryID: UUID?
    @State private var showCurrencyPicker = false
    /// GN-004: 选外币时异步拉当日汇率填入汇率框(loading 态),用户可覆盖。
    @State private var isFetchingRate = false
    @State private var rateFetchToken = 0

    private var editing: Transaction? {
        if case .edit(let t) = target { return t }; return nil
    }
    /// GN-024: 当前本位币(从 AppSettings 读;老库兜底 SGD)。FX 口径与录入特例都以它为准。
    private var baseCode: String { AppSettings.current(in: modelContext).baseCurrencyCode }
    private var availableCategories: [Category] {
        categories.filter { $0.kind == (type == .expense ? .expense : .income) }
                  .sorted { $0.sortOrder < $1.sortOrder }
    }
    private var amount: Decimal { Decimal(string: amountText) ?? 0 }
    /// 本位币本身锁汇率 1;外币取用户输入。
    private var rate: Decimal { currencyCode == baseCode ? 1 : (Decimal(string: rateText) ?? 1) }
    private var basePreview: Decimal { amount * rate }
    private var canSave: Bool { amount > 0 && selectedCategoryID != nil }

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
                    if currencyCode != baseCode {
                        HStack {
                            Text("汇率 1 \(currencyCode) =")
                            TextField("0.00", text: $rateText).keyboardType(.decimalPad)
                            if isFetchingRate { ProgressView().controlSize(.small) }
                            Text(baseCode)
                        }
                        // GN-024: 本位币预览走 formatBase（Decimal direct, 显式币种前缀）；键 "≈ %@"。
                        Text("≈ \(formatBase(basePreview, code: baseCode))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("分类") {
                    Picker("分类", selection: $selectedCategoryID) {
                        ForEach(availableCategories) { c in
                            Text("\(c.icon) \(c.name)").tag(Optional(c.id))
                        }
                    }
                }

                Section {
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    TextField("商户", text: $merchant)
                    TextField("备注", text: $note)
                }

                if editing != nil {
                    Section {
                        Button("删除", role: .destructive) {
                            if let t = editing { modelContext.delete(t) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(editing == nil ? "记一笔" : "编辑")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }.disabled(!canSave)
                }
            }
            .sheet(isPresented: $showCurrencyPicker) {
                CurrencyPickerSheet(selected: currencyCode) { picked in
                    currencyCode = picked
                    if picked == baseCode {
                        rateText = "1"          // 本位币锁 1
                        isFetchingRate = false
                    } else {
                        // GN-015 Bug2(乐观更新):切币种立即用最近用过的汇率占位填框、不阻塞 UI。
                        // 当日汇率随后由 fetchRate 后台异步拉取、静默更新(若用户期间手改则不覆盖)。
                        rateText = (lastRateByCurrency[picked] as NSDecimalNumber?)?.stringValue ?? ""
                        fetchRate(for: picked)
                    }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        if let t = editing {
            type = t.type
            amountText = (t.originalAmount as NSDecimalNumber).stringValue
            currencyCode = t.currencyCode
            rateText = (t.fxRateToSGD as NSDecimalNumber).stringValue
            date = t.date; merchant = t.merchant ?? ""; note = t.note
            selectedCategoryID = t.category?.id
        } else {
            currencyCode = baseCode          // GN-024: 新交易默认本位币
            rateText = "1"
            selectedCategoryID = availableCategories.first?.id
        }
    }

    /// GN-004 / GN-015 Bug2: 后台异步拉当日汇率,回来静默更新汇率框。不阻塞 UI。
    /// - rateFetchToken 防止快速切换币种时旧请求覆盖新选择。
    /// - optimisticRate 记录本次乐观更新写进框里的占位值;回来时若 rateText 已不等于它,
    ///   说明用户在此期间手动改过汇率 —— 不覆盖用户输入。
    private func fetchRate(for code: String) {
        rateFetchToken += 1
        let token = rateFetchToken
        let optimisticRate = rateText      // 本次切币种写入框的占位值(可能为空)
        // GN-024: 汇率口径 = 到当前本位币(读 AppSettings)。
        let base = baseCode
        isFetchingRate = true
        Task {
            let result = await CurrencyConverter.live().convert(amount: 1, currencyCode: code, base: base)
            await MainActor.run {
                // 仅当仍是同一次请求、且币种未变时才考虑应用。
                guard token == rateFetchToken, currencyCode == code else { return }
                isFetchingRate = false
                // 成功(未标待补)才静默更新;失败降级则保留占位让用户手填。
                // 关键:用户在等待期间手改过汇率(rateText 已变)则不覆盖其输入。
                if !result.needsFxRate, rateText == optimisticRate {
                    rateText = (result.fxRateToBase as NSDecimalNumber).stringValue
                }
            }
        }
    }

    private func save() {
        let cat = categories.first { $0.id == selectedCategoryID }
        let m = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = editing {
            t.type = type
            t.originalAmount = amount
            t.currencyCode = currencyCode
            t.fxRateToSGD = rate
            t.needsFxRate = false   // GN-004: 编辑保存后视为汇率已确认,清除待补标记
            t.recomputeSGDAmount()          // ← GN-002 注记：改金额/汇率后必须重算
            t.date = date
            t.merchant = m.isEmpty ? nil : m
            t.note = note
            t.category = cat
        } else {
            let t = Transaction(type: type, originalAmount: amount, currencyCode: currencyCode,
                                fxRateToSGD: rate, date: date, note: note,
                                merchant: m.isEmpty ? nil : m,
                                source: "manual",       // GN-036: 录入来源 = 手动新建(默认即此,显式更清晰)
                                category: cat)
            modelContext.insert(t)
        }
        onSaved?()        // GN-025 B3: e.g. inbox deletes the unrecognized draft after 手动补一笔
        dismiss()
    }
}

/// 可搜索币种选择 sheet。
struct CurrencyPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selected: String
    let onPick: (String) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            let sec = CurrencyCatalog.sections(matching: query)
            List {
                if !sec.pinned.isEmpty {
                    Section("常用") { ForEach(sec.pinned, id: \.self) { row($0) } }
                }
                Section("全部") { ForEach(sec.others, id: \.self) { row($0) } }
            }
            .searchable(text: $query, prompt: "搜索币种")
            .navigationTitle("选择币种")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("取消") { dismiss() } } }
        }
    }
    private func row(_ code: String) -> some View {
        Button { onPick(code); dismiss() } label: {
            HStack {
                Text(CurrencyCatalog.displayName(code))
                Spacer()
                if code == selected { Image(systemName: "checkmark") }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
