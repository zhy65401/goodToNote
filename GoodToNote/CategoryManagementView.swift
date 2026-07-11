//
//  CategoryManagementView.swift
//  GoodToNote
//
//  GN-016 — 分类管理:从设置进入,对支出/收入分类做增删改,背靠既有的 Category @Model
//  (不新增字段,故无 SwiftData store 迁移)。删除分类依赖模型已有的 .nullify 删除规则:
//  删分类只把关联交易的 category 置空(变「未分类」),绝不删交易。
//
//  纯 SwiftData CRUD。可单测的逻辑放在 CategoryStore.swift(不依赖 SwiftUI),视图保持薄。
//

import SwiftUI
import SwiftData

// MARK: - List

struct CategoryManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var editTarget: CategoryEditTarget?
    @State private var pendingDelete: Category?
    @State private var pendingDeleteCount = 0

    private var expense: [Category] { categories.filter { $0.kind == .expense } }
    private var income: [Category] { categories.filter { $0.kind == .income } }

    var body: some View {
        List {
            section(title: "支出", items: expense)
            section(title: "收入", items: income)
        }
        .navigationTitle("分类管理")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editTarget = .add } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新增分类")
            }
        }
        .sheet(item: $editTarget) { target in
            CategoryEditSheet(target: target)
        }
        .confirmationDialog(deleteMessage, isPresented: deleteBinding, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let c = pendingDelete { CategoryStore.deleteCategory(c, in: modelContext) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
    }

    @ViewBuilder
    private func section(title: String, items: [Category]) -> some View {
        Section(title) {
            if items.isEmpty {
                Text("暂无分类").foregroundStyle(.secondary)
            } else {
                ForEach(items) { c in
                    Button {
                        editTarget = .edit(c)
                    } label: {
                        HStack {
                            Text("\(c.icon) \(c.name)").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDeleteCount = CategoryStore.transactionCount(for: c, in: modelContext)
                            pendingDelete = c
                        } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteMessage: String {
        guard let c = pendingDelete else { return "" }
        // GN-023: 计算属性返回纯 String → 不会自动本地化，显式 String(localized:)；保留 %@/%lld 占位。
        if pendingDeleteCount == 0 {
            return String(localized: "删除分类「\(c.name)」？该分类下暂无交易。")
        }
        return String(localized: "该分类「\(c.name)」下有 \(pendingDeleteCount) 条交易，删除后这些交易将变为「未分类」（交易不会被删除）。")
    }
}

// MARK: - Add / Edit sheet

/// sheet 的两种模式。Identifiable 以配合 .sheet(item:)。
enum CategoryEditTarget: Identifiable {
    case add
    case edit(Category)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let c): return c.id.uuidString
        }
    }
}

struct CategoryEditSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let target: CategoryEditTarget

    @State private var name = ""
    @State private var icon = ""
    @State private var kind: CategoryKind = .expense

    private var editing: Category? {
        if case .edit(let c) = target { return c }; return nil
    }
    private var canSave: Bool { CategoryStore.validate(name: name, icon: icon) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name)
                    TextField("图标（单个 emoji）", text: $icon)
                        .onChange(of: icon) { _, newValue in
                            // 软约束:只保留最后一个字符簇(单 emoji)。
                            if newValue.count > 1 {
                                icon = String(newValue.suffix(1))
                            }
                        }
                }
                Section("类型") {
                    Picker("类型", selection: $kind) {
                        Text("支出").tag(CategoryKind.expense)
                        Text("收入").tag(CategoryKind.income)
                    }.pickerStyle(.segmented)
                }
            }
            .navigationTitle(editing == nil ? "新增分类" : "编辑分类")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }.disabled(!canSave)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        if let c = editing {
            name = c.name; icon = c.icon; kind = c.kind
        }
    }

    private func save() {
        if let c = editing {
            CategoryStore.editCategory(c, name: name, icon: icon, kind: kind, in: modelContext)
        } else {
            CategoryStore.addCategory(name: name, icon: icon, kind: kind, in: modelContext)
        }
        dismiss()
    }
}
