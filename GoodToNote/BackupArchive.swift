//
//  BackupArchive.swift
//  GoodToNote
//
//  GN-014 — 零依赖单文件备份容器：把 store 文件集（.store + -wal + -shm）打成一个
//  二进制 plist。键 = 文件名（如 "default.store"），值 = 文件字节。无手写字节解析，
//  无第三方依赖。用于启动自动备份、还原前备份、待还原暂存的统一打包/解包。
//

import Foundation

/// 零依赖单文件备份容器。
enum BackupArchive {
    enum ArchiveError: Error { case noStore, invalidContainer }

    /// 把 storeURL 及其 -wal/-shm sidecar（存在者）打成容器 Data。
    static func pack(storeURL: URL) throws -> Data {
        let fm = FileManager.default
        let dir = storeURL.deletingLastPathComponent()
        let base = storeURL.lastPathComponent
        var dict: [String: Data] = [:]
        for name in [base, base + "-wal", base + "-shm"] {
            let u = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { dict[name] = try Data(contentsOf: u) }
        }
        guard dict.keys.contains(where: { $0.hasSuffix(".store") }) else { throw ArchiveError.noStore }
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    /// 解出容器 → [文件名: Data]。校验：必须是字典且含一个 .store 键。
    static func unpack(_ data: Data) throws -> [String: Data] {
        let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = obj as? [String: Data],
              dict.keys.contains(where: { $0.hasSuffix(".store") }) else {
            throw ArchiveError.invalidContainer
        }
        return dict
    }

    /// 把解出的文件集写回目标 store 目录：先删目标 store + sidecar，再按容器内文件名写入。
    static func apply(_ dict: [String: Data], toStoreURL storeURL: URL) throws {
        let fm = FileManager.default
        let dir = storeURL.deletingLastPathComponent()
        let base = storeURL.lastPathComponent
        for name in [base, base + "-wal", base + "-shm"] {
            let u = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, bytes) in dict {
            try bytes.write(to: dir.appendingPathComponent(name))
        }
    }
}
