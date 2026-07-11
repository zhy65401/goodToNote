//
//  RecurringRuleGenerator.swift
//  GoodToNote
//
//  GN-006 — 周期交易结算引擎。每次启动调用一次：把每条启用的 RecurringRule 从它的
//  nextDate 起、回补到今天为止所有错过的发生点，各自生成一笔已确认交易（isPending=false，
//  立即计入流水/月度总额）。幂等性来自：结算后把 rule.nextDate 推进到「> now 的第一个发生点」
//  并 save，同时盖 lastGeneratedDate —— 同一天第二次结算生成 0 笔。
//
//  纯逻辑、UI-free（只依赖 Foundation + SwiftData），故可用 swiftc 独立单测
//  （见 battlefield/tests/GN-006_recurring_test.swift）。日期步进 nextOccurrence(after:period:
//  calendar:) 完全可单测；月末由 Calendar 自行 clamp（1/31 + 1 月 → 2/28）。
//
//  FX：复用 GN-004 的 CurrencyConverter（注入为闭包，便于测试不触网）。SGD 规则汇率 1，
//  绝不触网；外币换算失败按其它录入路径一样标 needsFxRate，绝不丢条目。回补的历史发生点
//  用「当前」汇率（免费 API 无历史汇率）—— 这是已锁定的决定。
//
//  安全上限：单条规则单次结算最多生成 CAP 笔（366），防止 nextDate 远在过去的 daily 规则
//  无限灌库。命中上限时写一条 escalation 笔记，但仍把规则推进到 > now，保持状态健全。
//
//  不新增任何 @Model 字段 → 无 SwiftData store 迁移。
//

import Foundation
import SwiftData

enum RecurringRuleGenerator {
    /// 单条规则单次结算的安全上限（约一年的 daily）。
    static let maxOccurrencesPerRulePerSettle = 366

    /// 纯日期步进：给定一个发生日期，返回下一个发生日期。
    /// 用 Calendar.date(byAdding:) 让日历自行处理月末 clamp（如 1/31 +1月 → 2/28）。
    static func nextOccurrence(after date: Date,
                              period: RecurrencePeriod,
                              calendar: Calendar) -> Date {
        let comp: DateComponents
        switch period {
        case .daily:   comp = DateComponents(day: 1)
        case .weekly:  comp = DateComponents(day: 7)
        case .monthly: comp = DateComponents(month: 1)
        case .yearly:  comp = DateComponents(year: 1)
        }
        // byAdding 永不失败这种简单加法；保险起见兜底为原日期 + 1 天。
        return calendar.date(byAdding: comp, to: date)
            ?? date.addingTimeInterval(86_400)
    }

    /// FX 解析闭包类型：给金额 + 币码，返回换算快照（fxRateToBase / baseAmount / needsFxRate）。
    /// 默认用 CurrencyConverter.live()；测试注入同步桩，不触网。
    /// GN-024: 本位币由 liveFXResolver 在创建时绑定（从 AppSettings 读出后传入），
    /// 故闭包接口本身无需 base 参数 —— 测试桩签名保持不变。
    typealias FXResolver = (_ amount: Decimal, _ currencyCode: String) async -> ConversionResult

    /// 默认 FX 解析：复用 GN-004 live converter（与手动录入 / Intent 路径一致）。
    /// GN-024: base 由调用方从 AppSettings 读出后传入，绑定进闭包。
    static func liveFXResolver(today: Date, base: String) -> FXResolver {
        let converter = CurrencyConverter.live(today: today)
        return { amount, code in await converter.convert(amount: amount, currencyCode: code, base: base) }
    }

    /// 结算所有启用规则：回补 nextDate..now 的全部发生点，幂等保存。
    /// - asOf: 注入「现在」，测试用固定日期；app 传 Date()。
    /// - calendar: 默认 .current；测试可固定时区。
    /// - fx: FX 解析闭包；默认 live。
    @MainActor
    static func settleDueRules(_ context: ModelContext,
                               asOf now: Date,
                               calendar: Calendar = .current,
                               fx: FXResolver? = nil) async {
        // GN-024: 默认 resolver 绑定当前本位币（老库/新库均经 current(in:) 兜底默认 SGD）。
        let base = AppSettings.current(in: context).baseCurrencyCode
        let resolveFX = fx ?? liveFXResolver(today: now, base: base)

        // 只取启用规则。
        let descriptor = FetchDescriptor<RecurringRule>(
            predicate: #Predicate { $0.isActive == true }
        )
        let rules = (try? context.fetch(descriptor)) ?? []

        for rule in rules {
            var cursor = rule.nextDate
            var produced = 0

            while cursor <= now && produced < maxOccurrencesPerRulePerSettle {
                // FX 快照（SGD → 1，绝不触网；外币失败标 needsFxRate，绝不丢条目）。
                let conv = await resolveFX(rule.amount, rule.currencyCode)

                let txn = Transaction(
                    type: rule.type,
                    originalAmount: rule.amount,
                    currencyCode: rule.currencyCode,
                    fxRateToSGD: conv.fxRateToBase,   // @Model 字段保留 sgdAmount/fxRateToSGD 名;语义=到本位币
                    date: cursor,
                    note: rule.note,
                    merchant: rule.merchant,
                    needsFxRate: conv.needsFxRate,
                    isPending: false,            // 自动确认：立即计入流水/总额
                    source: "recurring",          // GN-036: 录入来源 = 周期规则
                    category: rule.category
                )
                context.insert(txn)

                rule.lastGeneratedDate = cursor
                cursor = nextOccurrence(after: cursor, period: rule.period, calendar: calendar)
                produced += 1
            }

            // 关键幂等：把 nextDate 推进到 > now 的第一个发生点。下次启动同一天 → 0 笔。
            rule.nextDate = cursor

            if produced >= maxOccurrencesPerRulePerSettle {
                writeCapEscalation(rule: rule, produced: produced, asOf: now)
            }
        }

        try? context.save()
    }

    /// 命中安全上限时写一条 escalation 笔记（不打扰用户；规则可能配置异常）。
    private static func writeCapEscalation(rule: RecurringRule, produced: Int, asOf now: Date) {
        let line = """
        [GN-006] Recurring rule hit safety cap.
        rule.id=\(rule.id) note="\(rule.note)" period=\(rule.periodRaw) \
        amount=\(rule.amount) \(rule.currencyCode) produced=\(produced) \
        asOf=\(now) newNextDate=\(rule.nextDate)
        A rule generating \(produced) occurrences in one settle is likely misconfigured \
        (e.g. a daily rule with an ancient nextDate). Capped to avoid flooding the ledger; \
        rule advanced past now to stay idempotent. Please review.

        """
        // 尽力写文件；失败也不影响结算。escalations/ 在仓库根，app 运行时路径不可用 →
        // 仅在能写时落盘（CLI 测试环境可写），否则打印到 stderr。
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("escalations", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("GN-006_recurring_cap.log")
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: file) {
                    defer { try? handle.close() }
                    handle.seekToEndOfFile()
                    handle.write(data)
                } else {
                    try data.write(to: file)
                }
            }
        } catch {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
