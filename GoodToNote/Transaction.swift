//
//  Transaction.swift
//  GoodToNote
//
//  GN-002 — @Model Transaction, the core ledger row. Flat ledger (no accounts/transfers).
//  Multi-currency = redundant storage (方案 A): originalAmount + currencyCode +
//  fxRateToSGD snapshot + redundant sgdAmount for direct report summation.
//  Base currency SGD => fxRateToSGD = 1 and sgdAmount == originalAmount.
//

import Foundation
import SwiftData

@Model
final class Transaction {
    var id: UUID
    /// 支出 / 收入。
    var typeRaw: String
    /// 原币种金额（正数；支出/收入由 type 区分，不用负号）。
    var originalAmount: Decimal
    /// ISO 4217 原币码，如 "SGD" / "USD"。
    var currencyCode: String
    /// 成交时 1 单位原币 = 多少 SGD 的快照汇率。SGD 交易为 1。
    var fxRateToSGD: Decimal
    /// 冗余存储的 SGD 折算金额 = originalAmount * fxRateToSGD。报表直接求和此字段。
    var sgdAmount: Decimal
    /// 交易发生日期（用户/短信提供）。
    var date: Date
    var note: String
    /// 商户名（短信自动录入会带；手动可空）。GN-005 用它做 merchant→category 记忆。
    var merchant: String?
    /// GN-004:汇率待补标记。外币自动换算失败（无网/API 失败）时用占位汇率写入并置 true,
    /// 用户可在编辑界面补全后清掉。SGD 永不待补。带默认值 → SwiftData 轻量自动迁移,
    /// 既有 321 条数据打开后此字段默认 false,不破坏旧数据。
    var needsFxRate: Bool = false
    /// GN-005:待确认草稿标记。短信自动录入(IngestUOBMessageIntent)落盘时置 true,
    /// 用户在「待确认收件箱」接受后置 false(转正进流水)、拒绝则删除整笔。
    /// **isPending==true 的草稿一律不计入流水列表/月度总额/分类小计/任何统计口径。**
    /// 带默认值的新属性 → 叠加在已含 needsFxRate 的 schema 上仍是 SwiftData 轻量自动迁移,
    /// 既有 321 条数据打开后此字段默认 false,照常出现在流水,不破坏旧数据。
    /// 与 needsFxRate 独立:一笔外币待确认草稿可同时 isPending + needsFxRate。
    var isPending: Bool = false
    /// GN-036:录入来源标签。语义枚举(String 标量,便于迁移): "manual" / "sms" / "applePay" /
    /// "recurring"。**默认 "manual"** → 历史 321 笔 + 旧短信/周期入账迁移后皆为 "manual",不影响
    /// 去重(DuplicateDetector 只匹配 source=="applePay" 的入账)。带默认值的新属性叠加在已含
    /// needsFxRate/isPending 的 schema 上仍是 SwiftData 轻量自动迁移,老库打开此字段默认 "manual",
    /// 不破坏既有数据。Apple Pay 自动化路径(IngestWalletTransactionIntent)写 "applePay" 作去重锚点。
    var source: String = "manual"
    var createdAt: Date

    /// 所属分类。删除分类时置空（见 Category.transactions 的 .nullify）。
    var category: Category?

    var type: TransactionType {
        get { TransactionType(rawValue: typeRaw) ?? .expense }
        set { typeRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        type: TransactionType,
        originalAmount: Decimal,
        currencyCode: String = "SGD",
        fxRateToSGD: Decimal = 1,
        date: Date = .now,
        note: String = "",
        merchant: String? = nil,
        needsFxRate: Bool = false,
        isPending: Bool = false,
        source: String = "manual",
        category: Category? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.typeRaw = type.rawValue
        self.originalAmount = originalAmount
        self.currencyCode = currencyCode
        self.fxRateToSGD = fxRateToSGD
        self.sgdAmount = originalAmount * fxRateToSGD   // 冗余折算，构造时算好
        self.date = date
        self.note = note
        self.merchant = merchant
        self.needsFxRate = needsFxRate
        self.isPending = isPending
        self.source = source
        self.category = category
        self.createdAt = createdAt
    }

    /// 编辑金额/汇率后重算 SGD 折算值（保持冗余字段一致）。
    func recomputeSGDAmount() {
        sgdAmount = originalAmount * fxRateToSGD
    }
}
