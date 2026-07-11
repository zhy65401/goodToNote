//
//  CategoryStore.swift
//  GoodToNote
//
//  GN-016 — 分类增删改的纯逻辑层(UI-free,只依赖 Foundation + SwiftData)。
//  独立成文件以便用 swiftc 做独立单测(见 battlefield/tests/GN-016_category_test.swift),
//  也让 CategoryManagementView 保持薄。
//
//  删除分类只 context.delete:模型上的 .nullify 删除规则会把关联交易的 category 置空
//  (交易变「未分类」),绝不删交易。不新增任何 @Model 字段,故无 SwiftData store 迁移。
//

import Foundation
import SwiftData

/// 分类增删改的纯逻辑层。
enum CategoryStore {
    /// 校验:名称去空白后非空,图标去空白后非空。
    /// 图标软约束为单字(单 emoji)由输入框 onChange 负责;此处只拒绝空。
    static func validate(name: String, icon: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 某 kind 下一个排序号 = 该 kind 现有 sortOrder 最大值 + 1(空则 0)。
    static func nextSortOrder(for kind: CategoryKind, in context: ModelContext) -> Int {
        let raw = kind.rawValue
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.kindRaw == raw }
        )
        let existing = (try? context.fetch(descriptor)) ?? []
        let maxOrder = existing.map(\.sortOrder).max() ?? -1
        return maxOrder + 1
    }

    /// 新增一个用户分类(isPreset=false),自动分配 sortOrder,插入并保存。
    /// 校验失败返回 nil 且不写入。
    @discardableResult
    static func addCategory(name: String, icon: String, kind: CategoryKind,
                            in context: ModelContext) -> Category? {
        guard validate(name: name, icon: icon) else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIcon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = Category(
            name: trimmedName,
            icon: trimmedIcon,
            kind: kind,
            sortOrder: nextSortOrder(for: kind, in: context),
            isPreset: false
        )
        context.insert(category)
        try? context.save()
        return category
    }

    /// 编辑分类的名称/图标/种类。校验失败返回 false 且不改动。
    /// 改 kind 仅改变它归在哪个分组,关联交易仍保持关联。
    @discardableResult
    static func editCategory(_ category: Category, name: String, icon: String,
                             kind: CategoryKind, in context: ModelContext) -> Bool {
        guard validate(name: name, icon: icon) else { return false }
        category.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        category.icon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        category.kind = kind
        try? context.save()
        return true
    }

    /// 删除分类:依赖模型上的 .nullify 规则把关联交易的 category 置空(交易变「未分类」),
    /// 绝不删交易。
    ///
    /// 注意(GN-016 实测踩坑):.nullify 仅对「已物化」的 transactions 逆关系生效。若删除发生
    /// 在一个 transactions 数组还是空 fault 的 context 里,SwiftData 不知道有哪些交易引用了它,
    /// 删完后这些交易会留下悬挂的 category 引用(category==nil 不成立)。因此删除前先显式按
    /// category?.id 取出所有关联交易并手动置 nil,确保不论 context 处于何种状态都能正确「未分类」,
    /// 再删分类。交易本身永不删除。
    static func deleteCategory(_ category: Category, in context: ModelContext) {
        let cid = category.id
        let linked = (try? context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.category?.id == cid })
        )) ?? []
        for t in linked { t.category = nil }
        context.delete(category)
        try? context.save()
    }

    /// 统计某分类下的交易数(删除确认对话框用)。谓词按 category?.id 匹配。
    static func transactionCount(for category: Category, in context: ModelContext) -> Int {
        let cid = category.id
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.category?.id == cid }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }
}
