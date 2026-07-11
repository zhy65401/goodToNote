//
//  BackupManager.swift
//  GoodToNote
//
//  GN-014 — 启动时把 SwiftData store（含 WAL sidecar）打包成单个
//  Documents/Backups/GoodToNote-backup.gtnbak（零依赖二进制 plist 容器），单份覆盖。
//  全程容错：任何失败只打日志，绝不抛出、不阻塞启动。Documents 经文件共享暴露为「GoodToNote」。
//

import Foundation
import SwiftData

enum BackupManager {
    static let backupName = "GoodToNote-backup.gtnbak"

    static func backupsDir() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let b = docs.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        return b
    }

    /// 在 App.init 容器创建（+ seedIfNeeded）之后调用一次。
    static func runLaunchBackup(_ container: ModelContainer) {
        do {
            guard let storeURL = container.configurations.first?.url else {
                print("BackupManager: 无 store url，跳过"); return
            }
            let data = try BackupArchive.pack(storeURL: storeURL)
            let dest = try backupsDir().appendingPathComponent(backupName)
            try data.write(to: dest)
            print("BackupManager: 备份完成 → \(dest.path)")
        } catch {
            print("BackupManager: 备份失败（已忽略，不影响启动）：\(error)")
        }
    }
}
