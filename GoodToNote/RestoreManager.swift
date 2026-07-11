//
//  RestoreManager.swift
//  GoodToNote
//
//  GN-014 — 从文件还原。不能热替换运行中的 SwiftData 库 → 用户选文件时只校验 + 留
//  还原前备份 + 暂存 + 置标记，然后 app 退出；下次启动「在创建 ModelContainer 之前」
//  应用还原（覆盖 store 文件）。建容器失败则回滚到还原前备份再重试。
//

import Foundation
import SwiftData

enum RestoreManager {
    static let pendingFlag = "pendingRestoreV1"
    private static var fm: FileManager { .default }

    /// SwiftData 默认 store 路径（建容器前用，无法从 container 取）。
    /// 须与运行时 container.configurations.first?.url 一致 = applicationSupport/default.store。
    static func defaultStoreURL() -> URL {
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSup.appendingPathComponent("default.store")
    }
    private static func docsDir() -> URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    static func stagedURL() -> URL { docsDir().appendingPathComponent(".pending-restore.gtnbak") }
    static func preRestoreURL() throws -> URL {
        try BackupManager.backupsDir().appendingPathComponent("pre-restore.gtnbak")
    }

    // —— 用户选文件时（app 运行中）调用：校验 + 留还原前备份 + 暂存 + 置标记 ——
    static func stageRestore(from pickedURL: URL) throws {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: pickedURL)
        _ = try BackupArchive.unpack(data)              // 校验：非法/损坏会在此抛出，下面都不执行

        // 还原前备份（回滚保险）：把当前 store 打包存档。
        let storeURL = defaultStoreURL()
        if fm.fileExists(atPath: storeURL.path) {
            let cur = try BackupArchive.pack(storeURL: storeURL)
            try cur.write(to: try preRestoreURL())
        }
        // 暂存所选备份 + 置标记。
        let staged = stagedURL()
        if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
        try data.write(to: staged)
        UserDefaults.standard.set(true, forKey: pendingFlag)
    }

    // —— 下次启动、建 ModelContainer 之前调用 ——
    static func applyPendingRestoreIfNeeded() {
        guard UserDefaults.standard.bool(forKey: pendingFlag) else { return }
        defer {
            UserDefaults.standard.set(false, forKey: pendingFlag)
            try? fm.removeItem(at: stagedURL())
        }
        do {
            let data = try Data(contentsOf: stagedURL())
            let dict = try BackupArchive.unpack(data)
            try BackupArchive.apply(dict, toStoreURL: defaultStoreURL())
            print("RestoreManager: 已应用还原。")
        } catch {
            print("RestoreManager: 应用还原失败（保持现状，清标记防循环）：\(error)")
        }
    }

    private static func rollbackToPreRestore() {
        guard let pre = try? preRestoreURL(), fm.fileExists(atPath: pre.path),
              let data = try? Data(contentsOf: pre),
              let dict = try? BackupArchive.unpack(data) else { return }
        try? BackupArchive.apply(dict, toStoreURL: defaultStoreURL())
        print("RestoreManager: 已回滚到还原前备份。")
    }

    // —— 建容器：失败则回滚再试一次 ——
    private static func makeContainer() throws -> ModelContainer {
        // GN-004: 单一 schema/存储来源,确保主 app 与 App Intent 进程构造出
        // 完全一致的 store(同 schema、同默认 store URL)。
        try AppModelContainer.make()
    }
    static func makeContainerWithRollback() -> ModelContainer {
        do { return try makeContainer() }
        catch {
            print("RestoreManager: 建容器失败，尝试回滚：\(error)")
            rollbackToPreRestore()
            do { return try makeContainer() }
            catch { fatalError("无法创建 ModelContainer（含回滚后）：\(error)") }
        }
    }
}
