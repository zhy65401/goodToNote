//
//  CategoryEntity.swift
//  GoodToNote
//
//  GN-004 — Exposes the user's Category list to Shortcuts as an AppEntity so the
//  shortcut shows a category picker. Backed by the SAME on-disk SwiftData store as
//  the app (via AppModelContainer.shared) so presets + user-created categories all
//  appear. Stable Category.id (UUID) is the entity id.
//

import Foundation
import AppIntents
import SwiftData

struct CategoryEntity: AppEntity, Identifiable {
    var id: UUID
    var name: String
    var icon: String
    /// expense / income raw — lets the intent map back to a category kind if needed.
    var kindRaw: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "分类"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(icon) \(name)")
    }

    static var defaultQuery = CategoryEntityQuery()

    init(id: UUID, name: String, icon: String, kindRaw: String) {
        self.id = id; self.name = name; self.icon = icon; self.kindRaw = kindRaw
    }

    init(_ c: Category) {
        self.init(id: c.id, name: c.name, icon: c.icon, kindRaw: c.kindRaw)
    }
}

struct CategoryEntityQuery: EntityQuery {
    /// Resolve entities by id (used after the user picks from the menu).
    @MainActor
    func entities(for ids: [UUID]) async throws -> [CategoryEntity] {
        let ctx = try AppModelContainer.shared().mainContext
        let want = Set(ids)
        let all = try ctx.fetch(FetchDescriptor<Category>())
        return all.filter { want.contains($0.id) }.map(CategoryEntity.init)
    }

    /// All categories (presets + custom), sorted, for the Shortcuts picker menu.
    @MainActor
    func suggestedEntities() async throws -> [CategoryEntity] {
        let ctx = try AppModelContainer.shared().mainContext
        let all = try ctx.fetch(
            FetchDescriptor<Category>(sortBy: [SortDescriptor(\.sortOrder)]))
        return all.map(CategoryEntity.init)
    }
}
