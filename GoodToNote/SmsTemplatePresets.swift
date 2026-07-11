//
//  SmsTemplatePresets.swift
//  GoodToNote
//
//  GN-025 (Phase B, Task B1) — Built-in SMS template preset seeding. The example-driven
//  SmsTemplate engine compiles ONE example SMS into a single SmsTemplate that is seeded
//  idempotently (only when no built-in preset exists yet — mirrors
//  PresetCategories.seedIfNeeded: a user who later disables/deletes the preset is NOT
//  re-seeded on relaunch).
//
//  GN-030 (de-branding, 2026-06-13): per the user, examples must NOT show a real brand —
//  a real-bank example made new users think the app was bank-specific / partnered. The
//  built-in preset is now a NEUTRAL, DISABLED placeholder DEMO ("示例模版") so new users
//  simply see "what a template looks like" without a real bank rule that participates in
//  matching. The seed stays idempotent (库空才种), so an EXISTING user's real preset is
//  PRESERVED untouched (the GN-028 in-place upgrade/overwrite block was removed — see
//  seedIfNeeded).
//
//  The spans (currency / amount / merchant / date) are derived by running SmsExtractor.extract
//  on the example and taking its best-guess spans — exactly how the Phase-A tests feed the
//  compiler, and how the Phase-C confirm UI does. cardMask:true wildcards the card digits;
//  GN-028 makes the date a real .date SLOT, so the draft carries the SMS transaction date
//  while a second SMS with a different card/date/amount/merchant still matches.
//

import Foundation
import SwiftData

enum SmsTemplatePresets {
    /// GN-030: a generic placeholder demo SMS with NO real brand. Used only so the built-in
    /// "示例模版" demonstrates what a template looks like + as the onboarding send-test sample.
    /// Obviously fake data, but still shaped like a bank transaction SMS so the demo reads true.
    static let demoExample =
        "xx Bank: you spent SGD 12.34 at Test Merchant on 30/05/26."

    /// Build the currency/amount/merchant spans from the extractor's best guesses for
    /// `example` (same shape the Phase-C confirm UI hands the compiler; mirrors the
    /// test harness `exSpans`).
    private static func bestSpans(for example: String) -> [(role: SlotRole, range: Range<String.Index>)] {
        let er = SmsExtractor.extract(example)
        var out: [(role: SlotRole, range: Range<String.Index>)] = []
        if let cur = er.currencyCandidates.first(where: { $0.code == er.bestCurrency }) {
            out.append((.currency, cur.span.range))
        }
        if let amt = er.amountCandidates.first(where: { AmountParser.parse($0.text) == er.bestAmount }) {
            out.append((.amount, amt.range))
        }
        if let merch = er.merchantCandidates.first {
            out.append((.merchant, merch.range))
        }
        // GN-028: include the transaction-date span so the demo preset also extracts the date
        // (e.g. "30/05/26"). bestDateText is the first date-shaped span DateParser accepts;
        // map it back to its range the same way the C1 confirm UI does. Date is OPTIONAL — if
        // the example carried no parseable date the slot is simply omitted.
        if let dt = er.bestDateText, let dr = example.range(of: dt) {
            out.append((.date, dr))
        }
        return out
    }

    /// GN-030: compile the neutral placeholder example into ONE built-in DEMO SmsTemplate
    /// (not yet inserted). It is DISABLED (isEnabled:false) — a pure "what a template looks
    /// like" demo that does NOT participate in matching. orderIndex 0; currencyFallback SGD;
    /// transactionTypeRaw "expense".
    static func makeDemoPreset() -> SmsTemplate {
        let compiled = SmsTemplateCompiler.compile(
            example: demoExample,
            spans: bestSpans(for: demoExample),
            cardMask: true
        )
        // Encode the slotMap (capture-group order → role rawValues) as JSON, e.g.
        // ["currency","amount","merchant"]. This is what SmsTemplate.slotMapJSON stores
        // and what B2 decodes back into [SlotRole] before calling the matcher.
        let roleStrings = compiled.slotMap.map { $0.rawValue }
        let slotMapJSON = (try? JSONEncoder().encode(roleStrings))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return SmsTemplate(
            name: String(localized: "示例模版"),   // 中性名(catalog en "Example Template")
            orderIndex: 0,
            isEnabled: false,                       // ★ GN-030: 默认禁用——纯演示,不参与匹配
            compiledPattern: compiled.pattern,
            slotMapJSON: slotMapJSON,
            transactionTypeRaw: "expense",
            currencyFallback: "SGD",
            suggestedTriggerKeyword: compiled.suggestedTriggerKeyword,
            isBuiltInPreset: true,
            // GN-032: store the demo SMS so the built-in preset's metadata sheet also shows the
            // highlighted example + legend (instead of the fallback hint).
            exampleText: demoExample
        )
    }

    /// One-shot first-launch seed: insert the built-in DEMO preset ONLY when NO built-in
    /// preset exists yet (库空才种), and at most once EVER. A fresh install gets the disabled
    /// "示例模版" demo; a user who already has a built-in preset is NOT seeded.
    ///
    /// GN-031: a one-shot `smsDemoPresetSeeded` UserDefaults flag gates this. GN-031 made the
    /// built-in deletable (SmsTemplateListView); without the flag, deleting the demo would let
    /// the old `guard builtIns.isEmpty` re-seed it on the next launch (zombie). The flag is set
    /// to true at the END regardless of whether anything was seeded — so an EXISTING user who
    /// already has a real preset also gets the flag (no future re-seed) while their preset is
    /// preserved (seed is skipped because builtIns is non-empty). Net: seed at most once, delete
    /// without resurrection, existing real presets untouched.
    ///
    /// GN-030: the GN-028 in-place upgrade/overwrite block was REMOVED. Direction changed to a
    /// neutral placeholder DEMO, so the built-in example must never overwrite ANY existing
    /// preset's pattern/slotMap — otherwise an EXISTING user's real preset would be clobbered
    /// by the placeholder ("xx Bank … Test Merchant") and stop recognizing their real bank SMS.
    static func seedIfNeeded(_ context: ModelContext) {
        // 一次性:种过(或已判定无需种)就永不再种 → 用户删掉占位演示后不会复活。
        let key = "smsDemoPresetSeeded"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var descriptor = FetchDescriptor<SmsTemplate>(
            predicate: #Predicate { $0.isBuiltInPreset == true }
        )
        descriptor.fetchLimit = 1
        let builtIns = (try? context.fetch(descriptor)) ?? []
        if builtIns.isEmpty {                     // 全新库 → 种禁用占位演示
            context.insert(makeDemoPreset())
            try? context.save()
        }
        // 老用户已有真实内置预置(builtIns 非空)→ 不种,但同样置 flag(不未来复活)。
        UserDefaults.standard.set(true, forKey: key)
    }
}
