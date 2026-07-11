//
//  SettingsPlaceholderView.swift
//  GoodToNote
//
//  GN-014 — 设置 Tab。GN-033 起重组为三个可点进的二级菜单(通用 / 记账 / 关于)+ 底部「数据
//  备份与还原」区。本文件只保留顶层导航 + 备份/还原:从文件还原一份 .gtnbak 备份(.fileImporter
//  选文件 → 二次确认 → 校验 + 留还原前备份 + 暂存 + 置标记 → 提示并 exit(0),下次启动完成还原)。
//
//  GN-033 搬移:本位币 → GeneralSettingsView;分类/周期/短信模版/短信自动记账 → BookkeepingSettingsView;
//  App 名+版本 → AboutView(`Bundle.shortVersion` 扩展随之移到 AboutView,本文件不再定义)。
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var showImporter = false
    @State private var pendingURL: URL?
    @State private var showConfirm = false
    @State private var showRestoreReady = false
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            List {
                // GN-033: 顶层三个 drill-in 二级菜单。
                Section {
                    NavigationLink("通用") { GeneralSettingsView() }
                    NavigationLink("记账") { BookkeepingSettingsView() }
                    NavigationLink("关于") { AboutView() }
                }
                // 数据备份与还原:保持现状,置于最下方(GN-014/023 原样)。
                Section("数据备份与还原") {
                    // GN-023: 合并为单个插值字面量（"…+…" 拼接会变 String、不自动本地化）；键含 %@=备份文件名。
                    Text("每次启动会自动备份到「文件 → 我的 iPhone → GoodToNote → Backups」，为单个 \(BackupManager.backupName) 文件，可拷到 iCloud Drive / 电脑存档。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("从文件还原…") { showImporter = true }
                }
            }
            .navigationTitle("设置")
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let u = urls.first { pendingURL = u; showConfirm = true }
                case .failure(let e): errorMsg = e.localizedDescription
                }
            }
            .confirmationDialog("用这个备份覆盖当前全部数据？还原前会自动留一份当前数据的备份。",
                                isPresented: $showConfirm, titleVisibility: .visible) {
                Button("还原并覆盖", role: .destructive) { stage() }
                Button("取消", role: .cancel) { pendingURL = nil }
            }
            .alert("还原已就绪", isPresented: $showRestoreReady) {
                Button("关闭 App") { exit(0) }
            } message: {
                Text("数据已就绪。App 即将关闭，请重新打开以完成还原。")
            }
            .alert("还原失败", isPresented: Binding(get: { errorMsg != nil },
                                                  set: { if !$0 { errorMsg = nil } })) {
                Button("好") { errorMsg = nil }
            } message: { Text(errorMsg ?? "") }
        }
    }

    private func stage() {
        guard let src = pendingURL else { return }
        defer { pendingURL = nil }
        do {
            try RestoreManager.stageRestore(from: src)
            showRestoreReady = true
        } catch {
            // GN-023: 纯 String 赋值 → 显式本地化；保留两个 %@ 占位（备份文件名 + 错误描述）。
            errorMsg = String(localized: "无法读取该备份文件（可能不是有效的 \(BackupManager.backupName)）：\(error.localizedDescription)")
        }
    }
}
