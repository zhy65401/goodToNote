//
//  GoodToNoteApp.swift
//  GoodToNote
//
//  GN-002 — ModelContainer over the four real models (Transaction / Category /
//  RecurringRule / MerchantMapping) with idempotent first-launch preset seeding.
//  Replaces the GN-003 Item smoke-test. Store stays fully local (free Apple ID:
//  no CloudKit / App Groups / iCloud entitlements).
//

import SwiftUI
import SwiftData

@main
struct GoodToNoteApp: App {
    let container: ModelContainer

    init() {
        // 1) 建容器之前：若有待还原，先覆盖 store 文件。
        RestoreManager.applyPendingRestoreIfNeeded()
        // 2) 建容器（失败则回滚后重试）。本地 SwiftData store，无 CloudKit / App Groups（免费 Apple ID）。
        let container = RestoreManager.makeContainerWithRollback()
        self.container = container
        // 3) 幂等首启种入预置分类。
        PresetCategories.seedIfNeeded(container.mainContext)
        // 3a) GN-025/030: 幂等首启种入内置短信模版预置。仅当库中无任何内置预置时种入（库空才种）。
        //     GN-030 起预置是中性占位、默认禁用的「示例模版」演示，不参与匹配；老用户已有的真实预置因
        //     幂等(builtIns.isEmpty 才种)而原样保留，绝不被占位覆盖；用户日后禁用/删除后不再补种。
        SmsTemplatePresets.seedIfNeeded(container.mainContext)
        // 3b) GN-024: 确保 AppSettings 单例行存在（fetch-or-create，默认本位币 SGD）。
        //     老库无此行 → 此处建默认 SGD；新库同理。无关系新实体 = 加性轻量迁移。
        _ = AppSettings.current(in: container.mainContext)
        // 4) GN-006：结算到期周期规则（回补 nextDate..今天全部错过的发生点，生成已确认交易），
        //    再做启动备份，使备份能捕获刚生成的交易。settle 幂等：同一天第二次启动生成 0 笔。
        //    settle 是 async（FX 换算可能触网；SGD 规则汇率 1 不触网），故放进 Task 串行执行；
        //    备份排在 settle 之后保证捕获新生成交易。两者皆容错、不阻塞 UI 启动。
        Task { @MainActor in
            await RecurringRuleGenerator.settleDueRules(container.mainContext, asOf: Date())
            // 5) 每次启动一次性备份 store（容错，不阻塞启动）。
            BackupManager.runLaunchBackup(container)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
