//
//  StatsAggregator.swift
//  GoodToNote
//
//  GN-017 — Pure aggregation for the 统计 tab. No SwiftData, no SwiftUI.
//  All sums are over ExpenseSnapshot.sgdAmount (callers pass only expense,
//  non-pending snapshots, already category-filtered). Keeps the 全仓口径:
//  sgdAmount sums, exclude isPending, expense-only — enforced by the caller (StatsView).
//

import Foundation

enum StatsAggregator {

    /// 选颗粒度:单月范围 → 每日;跨月 → 每月;自定义按天数阈值(≤62 天每日,否则每月)。
    static func bucket(for range: StatsRange, now: Date, earliest: Date?, calendar cal: Calendar) -> TimeBucket {
        switch range {
        case .thisMonth, .lastMonth:
            return .daily
        case .thisYear, .all:
            return .monthly
        case .custom:
            let (s, e) = range.resolve(now: now, earliest: earliest, calendar: cal)
            let days = cal.dateComponents([.day], from: s, to: e).day ?? 0
            return days <= 62 ? .daily : .monthly
        }
    }

    /// 趋势点:从 start 到 end(半开)按 bucket 枚举所有桶,空桶补 0。
    static func trend(_ snapshots: [ExpenseSnapshot], bucket: TimeBucket,
                      start: Date, end: Date, calendar cal: Calendar) -> [TrendPoint] {
        let comp: Calendar.Component = (bucket == .daily) ? .day : .month
        // 把每笔归到其桶起点。
        func bucketStart(_ d: Date) -> Date {
            switch bucket {
            case .daily:   return cal.startOfDay(for: d)
            case .monthly: return cal.date(from: cal.dateComponents([.year, .month], from: d))!
            }
        }
        var sums: [Date: Decimal] = [:]
        for s in snapshots where s.date >= start && s.date < end {
            sums[bucketStart(s.date), default: 0] += s.sgdAmount
        }
        // 枚举所有桶(从 start 的桶起点到 end 之前)。
        var points: [TrendPoint] = []
        var cursor = bucketStart(start)
        while cursor < end {
            points.append(TrendPoint(bucketStart: cursor, total: sums[cursor] ?? 0))
            cursor = cal.date(byAdding: comp, value: 1, to: cursor)!
        }
        return points
    }

    /// 分类占比:按 categoryID 汇总,降序;fraction = 该类 / 总额(总额为 0 时 fraction=0)。
    static func breakdown(_ snapshots: [ExpenseSnapshot]) -> [CategorySlice] {
        struct Acc { var total: Decimal = 0; var name = ""; var icon = "" }
        var map: [String: (id: UUID?, acc: Acc)] = [:]   // key=id 或 "uncategorized"
        for s in snapshots {
            let key = s.categoryID?.uuidString ?? "uncategorized"
            var entry = map[key] ?? (s.categoryID, Acc(total: 0, name: s.categoryName, icon: s.categoryIcon))
            entry.acc.total += s.sgdAmount
            entry.acc.name = s.categoryName
            entry.acc.icon = s.categoryIcon
            map[key] = entry
        }
        let grand = map.values.reduce(Decimal(0)) { $0 + $1.acc.total }
        let grandD = NSDecimalNumber(decimal: grand).doubleValue
        return map.values
            .map { v in
                let t = NSDecimalNumber(decimal: v.acc.total).doubleValue
                return CategorySlice(categoryID: v.id, name: v.acc.name, icon: v.acc.icon,
                                     total: v.acc.total,
                                     fraction: grandD > 0 ? t / grandD : 0)
            }
            .sorted { $0.total > $1.total }
    }
}
