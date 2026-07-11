//
//  CurrencyCatalog.swift
//  GoodToNote
//
//  GN-009 — Phase 1 录入/查看 UI. Supported-currency catalog for the
//  multi-currency transaction editor: system ISO 4217 set + pinned common
//  currencies (incl. DKK/NOK seen in imported data) + localized display names.
//

import Foundation

/// 支持的币种集合：系统全套常用 ISO 4217 + 钉在顶部的常用币种。
enum CurrencyCatalog {
    /// 顶部钉常用（含历史数据里出现过的 DKK/NOK）。
    static let pinned: [String] = [
        "SGD", "USD", "EUR", "GBP", "JPY", "CNY",
        "HKD", "MYR", "AUD", "THB", "KRW", "DKK", "NOK",
    ]

    /// 系统提供的全部常用 ISO 货币码，已排序、去重。
    static let all: [String] = {
        Set(Locale.commonISOCurrencyCodes).sorted()
    }()

    /// 给定搜索串，返回 (钉选区, 其余区)。空搜索时钉选在前、其余为完整列表去掉钉选。
    static func sections(matching query: String) -> (pinned: [String], others: [String]) {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        func match(_ code: String) -> Bool {
            q.isEmpty || code.contains(q) || displayName(code).uppercased().contains(q)
        }
        let p = pinned.filter(match)
        let o = all.filter { !pinned.contains($0) && match($0) }
        return (p, o)
    }

    /// "USD — 美元/US Dollar"（本地化货币名）。
    static func displayName(_ code: String) -> String {
        let name = Locale.current.localizedString(forCurrencyCode: code) ?? code
        return "\(code) — \(name)"
    }

    /// GN-024 — 显式、不歧义的币种前缀符号。用于 formatBase / 原币显示。
    /// 不用 `.currency` 的歧义 "$"（多种货币共用）；本位币 SGD = "S$"，保持原品牌。
    /// 未列出的币种 → 用 ISO 码 + 空格兜底（如 "SEK 123.00"），始终明确。
    static func symbol(_ code: String) -> String {
        switch code.uppercased() {
        case "SGD": return "S$"
        case "USD": return "US$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY": return "JP¥"
        case "CNY": return "CN¥"
        case "HKD": return "HK$"
        case "MYR": return "RM"
        case "AUD": return "A$"
        case "THB": return "฿"
        case "KRW": return "₩"
        case "DKK", "NOK": return "kr"
        default: return code + " "   // ISO 码前缀兜底
        }
    }
}
