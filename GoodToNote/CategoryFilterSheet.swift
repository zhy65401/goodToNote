//
//  CategoryFilterSheet.swift
//  GoodToNote
//
//  GN-018 — 单一来源的分类多选筛选 sheet,Ledger 与 Stats 共用。
//  每行 .contentShape(Rectangle()) → 整行可点(根治"只点左边"反复 bug)。
//

import SwiftUI

struct CategoryFilterSheet: View {
    let categories: [Category]
    @Binding var selectedCategoryIDs: Set<UUID>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(categories) { c in
                    Button {
                        if selectedCategoryIDs.contains(c.id) { selectedCategoryIDs.remove(c.id) }
                        else { selectedCategoryIDs.insert(c.id) }
                    } label: {
                        HStack {
                            Text("\(c.icon) \(c.name)")
                            Spacer()
                            if selectedCategoryIDs.contains(c.id) { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())   // 整行命中,含 Spacer 区
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("按分类筛选")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清除") { selectedCategoryIDs.removeAll() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
