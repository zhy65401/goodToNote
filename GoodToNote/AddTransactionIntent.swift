//
//  AddTransactionIntent.swift
//  GoodToNote
//
//  GN-004 — App Intent that silently writes one transaction (no app launch),
//  callable from the Shortcuts app / SMS automation. Category is chosen inside
//  Shortcuts via CategoryEntity. Foreign amounts are auto-converted to SGD via the
//  shared CurrencyConverter (live API + same-day cache + last-successful downgrade);
//  on FX failure the txn is still written with a placeholder rate + needsFxRate=true
//  so we NEVER lose a transaction. Writes to the SAME store as the app via
//  AppModelContainer.shared. Free Apple ID: App Intents need no paid entitlement.
//

import Foundation
import AppIntents
import SwiftData

enum TransactionTypeAppEnum: String, AppEnum {
    case expense
    case income

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "收支类型"
    static var caseDisplayRepresentations: [TransactionTypeAppEnum: DisplayRepresentation] = [
        .expense: "支出",
        .income: "收入",
    ]
}

struct AddTransactionIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Transaction"
    static var description = IntentDescription("记一笔交易到 Good to note（外币自动换算成 SGD）。")
    /// Stay in the background — don't force the app to the foreground.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "金额")
    var amount: Double

    @Parameter(title: "币种", default: "SGD")
    var currencyCode: String?

    @Parameter(title: "分类")
    var category: CategoryEntity?

    @Parameter(title: "收支类型", default: .expense)
    var type: TransactionTypeAppEnum

    @Parameter(title: "商户")
    var merchant: String?

    @Parameter(title: "备注")
    var note: String?

    @Parameter(title: "日期")
    var date: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("记一笔 \(\.$amount) \(\.$currencyCode) 到 \(\.$category)") {
            \.$type
            \.$merchant
            \.$note
            \.$date
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 1) Validate amount.
        guard amount > 0, let amt = Decimal(string: String(amount)), amt > 0 else {
            // GN-023: needsValueError 收 IntentDialog（LocalizedStringResource 背书），字面量
            // 自动进 catalog 并本地化 → 保留字面量，键 "金额必须大于 0。" 已在 catalog。
            throw $amount.needsValueError("金额必须大于 0。")
        }
        let code = (currencyCode?.trimmingCharacters(in: .whitespaces).uppercased()).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "SGD"

        // 3) SAME store the app uses — read the configured base currency from it
        //    (cross-process via AppModelContainer.shared()).
        let container = try AppModelContainer.shared()
        let ctx = container.mainContext
        let base = AppSettings.current(in: ctx).baseCurrencyCode

        // 2) Convert to base (never throws; downgrades + flags on failure).
        let conv = CurrencyConverter.live()
        let result = await conv.convert(amount: amt, currencyCode: code, base: base)

        var cat: Category? = nil
        if let pickedID = category?.id {
            let all = try ctx.fetch(FetchDescriptor<Category>())
            cat = all.first { $0.id == pickedID }
        }

        // 4) Build via the GN-002 initializer (sgdAmount recompute-correct), insert + save.
        let txnType: TransactionType = (type == .income) ? .income : .expense
        let m = merchant?.trimmingCharacters(in: .whitespacesAndNewlines)
        let txn = Transaction(
            type: txnType,
            originalAmount: amt,
            currencyCode: code,
            fxRateToSGD: result.fxRateToBase,   // @Model 字段保留 sgdAmount/fxRateToSGD 名;语义=到本位币
            date: date ?? .now,
            note: note ?? "",
            merchant: (m?.isEmpty ?? true) ? nil : m,
            needsFxRate: result.needsFxRate,
            category: cat
        )
        ctx.insert(txn)
        try ctx.save()

        // 5) Confirmation dialog shown in Shortcuts.
        // GN-023/024: 运行时拼的 dialog 是纯 String → 显式 String(localized:)；金额走 formatBase
        // (Decimal direct, 显式币种前缀；本位币 SGD → "S$")。
        var line = String(localized: "已记录：\(formatBase(result.baseAmount, code: base))")
        if let m, !m.isEmpty { line += " \(m)" }
        if let c = cat { line += " · \(c.icon)\(c.name)" }
        if result.needsFxRate { line += String(localized: "（汇率待补）") }
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

/// Makes AddTransactionIntent discoverable in the Shortcuts app.
struct GoodToNoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTransactionIntent(),
            phrases: [
                "用 \(.applicationName) 记一笔",
                "Add a transaction to \(.applicationName)",
            ],
            shortTitle: "记一笔",
            systemImageName: "plus.circle"
        )
        // GN-005: silent bank-SMS ingest for the Messages automation. GN-030: phrases/shortTitle
        // de-branded to neutral "处理银行短信 / Ingest bank SMS" (the class name / Intent identifier
        // IngestUOBMessageIntent is PRESERVED — renaming it breaks the user's existing Shortcut).
        AppShortcut(
            intent: IngestUOBMessageIntent(),
            phrases: [
                "用 \(.applicationName) 处理银行短信",
                "Ingest bank SMS to \(.applicationName)",
            ],
            shortTitle: "处理银行短信",
            systemImageName: "tray.and.arrow.down"
        )
        // GN-036: silent Apple Pay /「钱包」direct-ingest for the Shortcuts "Transaction" automation.
        // A SEPARATE Intent (IngestWalletTransactionIntent) — the existing two Intents' class names /
        // identifiers are left untouched (renaming them would break users' configured automations).
        // Installing the app makes this action selectable in the Shortcuts "Transaction" trigger.
        AppShortcut(
            intent: IngestWalletTransactionIntent(),
            phrases: [
                "用 \(.applicationName) 记一笔 Apple Pay",
                "Record Apple Pay transaction in \(.applicationName)",
            ],
            shortTitle: "记录 Apple Pay 交易",
            systemImageName: "creditcard"
        )
        // GN-039: silent bank-EMAIL ingest for the「邮件 / Email」automation. A SEPARATE Intent
        // (IngestEmailIntent, source=="email") — the existing three Intents' class names /
        // identifiers are left untouched. Installing the app makes this action selectable in the
        // user's Email-automation Shortcut (after a "Get Text from Input" step extracts the body).
        AppShortcut(
            intent: IngestEmailIntent(),
            phrases: [
                "用 \(.applicationName) 处理银行邮件",
                "Ingest bank email to \(.applicationName)",
            ],
            shortTitle: "处理银行邮件",
            systemImageName: "envelope"
        )
    }
}
