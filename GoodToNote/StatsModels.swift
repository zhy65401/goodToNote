//
//  StatsModels.swift
//  GoodToNote
//
//  GN-017 — Pure value types for the 统计 tab. Decoupled from SwiftData so the
//  aggregation logic (StatsAggregator) is unit-testable with a plain-Foundation
//  swiftc harness (avoids the SwiftData CLI "Unable to determine Bundle Name" trap).
//
//  Task-status connection: app is live (v1.1) and this is a NEW read-only feature —
//  no new @Model fields, no migration. These value types are a snapshot projection of
//  the existing Transaction/Category models so the math is testable without SwiftData.
//

import Foundation

/// GN-023/024 — 共享金额格式化 helper（DRY）。直接吃 Decimal（不经 Double，消除精度隐患），
/// 输出 = 显式币种前缀（CurrencyCatalog.symbol，不歧义）+ locale 分组的两位小数。
/// 本位币 SGD → "S$1,234.50"，与原品牌一致；任意 base 都明确带前缀。
/// `code` 由调用方传入（base 金额传当前本位币码，原币金额传该笔 currencyCode）。
func formatBase(_ v: Decimal, code: String) -> String {
    CurrencyCatalog.symbol(code) + v.formatted(.number.precision(.fractionLength(2)))
}

/// 一笔支出的纯值快照(从 Transaction 提取),喂给 StatsAggregator。
struct ExpenseSnapshot: Equatable {
    let date: Date
    let sgdAmount: Decimal
    let categoryID: UUID?      // nil = 未分类
    let categoryName: String   // 展示用;未分类时为 "未分类"
    let categoryIcon: String   // 展示用;未分类时为 "❓"
}

/// 折线图横轴颗粒度。
enum TimeBucket { case daily, monthly }

/// 折线图上的一个点(某日或某月的支出合计)。空桶补 0。
struct TrendPoint: Equatable, Identifiable {
    let bucketStart: Date   // 当日 00:00 或当月 1 号 00:00
    let total: Decimal
    var id: Date { bucketStart }
}

/// 饼图/排行榜的一段(某分类的支出合计与占比)。
struct CategorySlice: Equatable, Identifiable {
    let categoryID: UUID?
    let name: String
    let icon: String
    let total: Decimal
    let fraction: Double    // 0...1,占当前范围+filter 支出总额的比例
    var id: String { categoryID?.uuidString ?? "uncategorized" }
}

/// 时间范围选项。resolve 返回半开区间 [start, end)。
enum StatsRange: Hashable, Identifiable {
    case thisMonth
    case lastMonth
    case thisYear
    case all
    case custom(start: Date, end: Date)

    var id: String {
        switch self {
        case .thisMonth: return "thisMonth"
        case .lastMonth: return "lastMonth"
        case .thisYear:  return "thisYear"
        case .all:       return "all"
        case .custom(let s, let e): return "custom-\(s.timeIntervalSince1970)-\(e.timeIntervalSince1970)"
        }
    }

    var label: String {
        switch self {
        case .thisMonth: return String(localized: "本月")
        case .lastMonth: return String(localized: "上月")
        case .thisYear:  return String(localized: "今年")
        case .all:       return String(localized: "全部")
        case .custom:    return String(localized: "自定义")
        }
    }

    /// 解析为半开区间 [start, end)。
    /// - now: 当前时间(测试可注入固定值)。
    /// - earliest: 全部数据中最早一笔的日期(用于 .all 的起点);nil 时退回 now 当年 1 月。
    func resolve(now: Date, earliest: Date?, calendar cal: Calendar) -> (start: Date, end: Date) {
        switch self {
        case .thisMonth:
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            return (start, cal.date(byAdding: .month, value: 1, to: start)!)
        case .lastMonth:
            let thisStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            let start = cal.date(byAdding: .month, value: -1, to: thisStart)!
            return (start, thisStart)
        case .thisYear:
            let start = cal.date(from: cal.dateComponents([.year], from: now))!
            return (start, cal.date(byAdding: .year, value: 1, to: start)!)
        case .all:
            let endExclusive = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            let start = cal.startOfDay(for: earliest ?? cal.date(from: cal.dateComponents([.year], from: now))!)
            return (start, endExclusive)
        case .custom(let s, let e):
            // 归一到日边界,end 取所选末日的次日 00:00(半开)。
            let start = cal.startOfDay(for: min(s, e))
            let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(s, e)))!
            return (start, end)
        }
    }
}
