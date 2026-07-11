//
//  GeneralSettingsView.swift
//  GoodToNote
//
//  GN-033 — "通用" drill-in page. Houses Base Currency (moved verbatim from the flat
//  SettingsView — state / changeBase() / sheet / dialogs unchanged; BaseCurrencyService is
//  untouched) and a link into the in-app language picker.
//

import SwiftUI
import SwiftData

struct GeneralSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    // GN-024: 本位币切换（逻辑逐字搬自 SettingsView，未改）。
    @State private var showBasePicker = false
    @State private var pendingBase: String?            // 选中、待确认的新本位币
    @State private var showBaseConfirm = false
    @State private var isChangingBase = false          // spinner 期间
    @State private var baseChangeError: String?

    /// 当前本位币（fetch-or-create 兜底默认 SGD）。
    private var currentBase: String { AppSettings.current(in: modelContext).baseCurrencyCode }

    var body: some View {
        List {
            Section("本位币") {
                Button {
                    showBasePicker = true
                } label: {
                    HStack {
                        Text("本位币")
                        Spacer()
                        Text(CurrencyCatalog.displayName(currentBase))
                            .foregroundStyle(.secondary)
                        if isChangingBase { ProgressView().controlSize(.small) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isChangingBase)
            }
            // GN-033: app 内语言切换（跟随系统 / 简体中文 / English）。
            Section("语言") {
                NavigationLink {
                    LanguageSettingsView()
                } label: {
                    HStack {
                        Text("语言")
                        Spacer()
                        Text(LanguageManager.current().displayName)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "通用"))
        .navigationBarTitleDisplayMode(.inline)
        // —— GN-024: 本位币选择 → 确认 → 切换（搬移，未改）——
        .sheet(isPresented: $showBasePicker) {
            CurrencyPickerSheet(selected: currentBase) { picked in
                // 选与当前相同 → 无操作。
                guard picked != currentBase else { return }
                pendingBase = picked
                showBaseConfirm = true
            }
        }
        .confirmationDialog("更改本位币会按当前汇率重算所有历史交易的本位金额，与当初记账汇率不同。已自动备份。继续？",
                            isPresented: $showBaseConfirm, titleVisibility: .visible) {
            Button("继续重算", role: .destructive) { changeBase() }
            Button("取消", role: .cancel) { pendingBase = nil }
        }
        .alert("更改失败", isPresented: Binding(get: { baseChangeError != nil },
                                              set: { if !$0 { baseChangeError = nil } })) {
            Button("好") { baseChangeError = nil }
        } message: { Text(baseChangeError ?? "") }
    }

    /// GN-024: 调 BaseCurrencyService.changeBase（已自动备份；网络/缺率失败整体中止,不改任何数据）。
    private func changeBase() {
        guard let newBase = pendingBase else { return }
        pendingBase = nil
        isChangingBase = true
        let container = modelContext.container
        Task { @MainActor in
            defer { isChangingBase = false }
            do {
                try await BaseCurrencyService.changeBase(to: newBase,
                                                         in: modelContext,
                                                         container: container)
            } catch {
                baseChangeError = error.localizedDescription
            }
        }
    }
}

#Preview {
    NavigationStack { GeneralSettingsView() }
}
