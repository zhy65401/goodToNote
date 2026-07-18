//
//  SmsTemplateMigrator.swift
//  GoodToNote
//
//  GN-052 (Task 1, Step 4) — ONE-SHOT recompile of already-stored templates under the new
//  tail-anchor strategy.
//
//  WHY THIS EXISTS: GN-052 changed SmsTemplateCompiler's tail anchor (it no longer bakes the
//  40 verbatim characters that follow the merchant into the pattern) and its
//  suggestedTriggerKeyword rule. Those changes only affect templates compiled from then on —
//  the template ALREADY in the user's store still carries the old over-fitted pattern
//  (". If unauthorised, call 24/7 Fraud Hotli", truncated mid-word) and would keep failing on
//  any reworded/rewrapped message. Shipping the compiler fix without this migration would fix
//  nothing for the very user who reported the bug.
//
//  HOW (spec GN-052 Task 1 Step 4): for each template that stored its `exampleText`,
//    1. run the template's CURRENT rule over its own example to recover the slot spans
//       (SmsTemplateMatcher.matchSpans — the same read-only recovery GN-032/GN-034 use),
//    2. recompile those spans with the NEW compiler,
//    3. SELF-CHECK the result over the runtime path (SmsTemplateMatcher.matchOne), and only
//    4. overwrite compiledPattern / slotMapJSON / suggestedTriggerKeyword when the self-check
//       passes AND the new rule reads the example EXACTLY as the old rule did.
//
//  ★ SAFETY NET — a template that fails ANY of those gates is LEFT COMPLETELY UNTOUCHED. It
//  keeps working exactly as well (or as badly) as it did before the update. This migration can
//  only ever move a template from "over-fitted" to "verified-equivalent-but-more-tolerant";
//  it can never leave one in a state that was not proven to still recognize its own example.
//  Identity/ordering fields (id / orderIndex / isEnabled / isBuiltInPreset / createdAt / name /
//  exampleText / inputKind) are never written — mirroring SmsTemplateEditorView.applyEdits.
//
//  Runs once, gated by a UserDefaults flag (same idiom as SmsTemplatePresets.seedIfNeeded's
//  `smsDemoPresetSeeded`), from GoodToNoteApp.init after the preset seed.
//

import Foundation
import SwiftData

enum SmsTemplateMigrator {
    /// One-shot flag (mirrors SmsTemplatePresets' `smsDemoPresetSeeded` idiom).
    ///
    /// ★ GN-053 BUMPED THIS KEY (was `gn052TemplatesRecompiled`). The gate is what makes the pass
    /// one-shot, so a store migrated under GN-052 is frozen at whatever the GN-052 compiler
    /// produced. GN-053 changed the compiler again — a volatile digit run right after a trailing
    /// merchant (a running balance, a transaction reference) is now wildcarded instead of baked in
    /// verbatim — and those already-migrated templates would never see the improvement. A new key
    /// re-opens the gate exactly once more.
    ///
    /// Re-running is safe by construction, and deliberately so: every gate in `recompiledRule` is
    /// re-applied from scratch, a template that fails ANY of them is left byte-for-byte untouched,
    /// and a template already carrying new-compiler output returns `.skippedUnchanged` and is not
    /// rewritten. The pass is therefore idempotent — running it twice is indistinguishable from
    /// running it once (pinned by GN-052_migration_test S7.4/S7.5 and S9.5).
    ///
    /// FUTURE: any further change to SmsTemplateCompiler's emitted pattern needs this key bumped
    /// again, for the same reason. It is not a version stamp — it is "has THIS compiler's output
    /// been applied to the store yet".
    static let recompileFlagKey = "gn053TemplatesRecompiled"

    /// The three rule fields a successful recompile replaces. Nothing else is ever written.
    struct RecompiledRule: Equatable {
        let pattern: String
        let slotMapJSON: String
        let triggerKeyword: String?
    }

    /// The outcome for ONE template — `nil` rule means "leave it alone" and carries why.
    enum Outcome: Equatable {
        case skippedNoExample
        case skippedOldRuleCannotReadItsExample
        case skippedSelfCheckFailed
        case skippedUnchanged
        case upgraded(RecompiledRule)
    }

    // MARK: - Pure core (no SwiftData — unit-tested directly by GN-052_migration_test)

    /// PURE decision for one stored template: given what is persisted, either produce the new
    /// rule or refuse. Refusing is always safe — the caller then writes nothing.
    ///
    /// `now` is injected so the date-slot comparison is deterministic in tests (a year-less date
    /// like "18/07" resolves against the reference date).
    static func recompiledRule(exampleText: String,
                               compiledPattern: String,
                               slotMapJSON: String,
                               now: Date = Date()) -> Outcome {
        // (0) No stored example → nothing to recompile from. GN-032 added exampleText, so
        // templates built before it legitimately have none. Leave them alone.
        let example = exampleText
        guard !example.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .skippedNoExample
        }

        let oldSlotMap = SmsTemplateMatcher.decodeSlotMap(slotMapJSON)
        guard !oldSlotMap.isEmpty else { return .skippedOldRuleCannotReadItsExample }

        // (1) Recover the spans by running the template's OWN current rule over its OWN example.
        // If the old rule cannot read its own example we have no trustworthy spans to recompile
        // from (and re-guessing with SmsExtractor would reintroduce the two-engine bug GN-052
        // exists to kill), so we refuse rather than guess.
        guard let oldFields = SmsTemplateMatcher.matchOne(example, pattern: compiledPattern,
                                                         slotMap: oldSlotMap, now: now) else {
            return .skippedOldRuleCannotReadItsExample
        }
        let spanMap = SmsTemplateMatcher.matchSpans(example, pattern: compiledPattern,
                                                    slotMap: oldSlotMap)
        guard !spanMap.isEmpty else { return .skippedOldRuleCannotReadItsExample }
        let spans = spanMap.map { (role: $0.key, range: $0.value) }
                           .sorted { $0.range.lowerBound < $1.range.lowerBound }

        // (2) Recompile. Preserve the card-digit wildcard setting: `\d{4}` is the compiler's
        // unique cardMask signature (the date wildcards emit \d{1,4} / \d{1,2} / \d{2,4} and the
        // amount class is [0-9]-based, so nothing else produces exactly \d{4}). Reading it back
        // off the old pattern keeps a user who turned the mask OFF from silently getting it on.
        let usedCardMask = compiledPattern.contains(#"\d{4}"#)
        let compiled = SmsTemplateCompiler.compile(example: example, spans: spans,
                                                   cardMask: usedCardMask)

        // (3) SELF-CHECK over the RUNTIME path. Three gates, all required:
        //   a. the new rule matches the example at all (matchOne also enforces the
        //      numberOfRanges == slotMap.count + 1 group-count invariant internally),
        //   b. it captures the same roles in the same capture order as before, and
        //   c. it reads the example to the SAME field values the old rule did — the strongest
        //      available proof that this is a widening, not a behavior change.
        guard compiled.slotMap == oldSlotMap else { return .skippedSelfCheckFailed }
        guard let newFields = SmsTemplateMatcher.matchOne(example, pattern: compiled.pattern,
                                                         slotMap: compiled.slotMap, now: now),
              newFields == oldFields else {
            return .skippedSelfCheckFailed
        }

        let rule = RecompiledRule(pattern: compiled.pattern,
                                  slotMapJSON: SmsTemplateMatcher.encodeSlotMap(compiled.slotMap),
                                  triggerKeyword: compiled.suggestedTriggerKeyword)
        // Nothing actually changed (already compiled by the new compiler) → no write.
        if rule.pattern == compiledPattern && rule.slotMapJSON == slotMapJSON {
            return .skippedUnchanged
        }
        return .upgraded(rule)
    }

    // MARK: - Store pass (one-shot)

    /// Recompile every stored template once. Idempotent + flag-gated: safe to call on each
    /// launch. Templates that fail the self-check keep their original rule byte-for-byte.
    /// Returns the number of templates actually upgraded (0 when the flag was already set).
    @MainActor
    @discardableResult
    static func recompileStoredTemplatesIfNeeded(_ ctx: ModelContext,
                                                 defaults: UserDefaults = .standard) -> Int {
        guard !defaults.bool(forKey: recompileFlagKey) else { return 0 }
        let upgraded = recompileAll(ctx)
        // Set the flag regardless of how many were upgraded — a template that failed the
        // self-check would fail it again next launch; retrying forever buys nothing and the
        // user can always re-edit that template by hand.
        defaults.set(true, forKey: recompileFlagKey)
        return upgraded
    }

    /// The un-gated pass (exposed for tests + any future manual re-run).
    @MainActor
    @discardableResult
    static func recompileAll(_ ctx: ModelContext) -> Int {
        let all = (try? ctx.fetch(FetchDescriptor<SmsTemplate>())) ?? []
        var upgraded = 0
        for t in all {
            guard case .upgraded(let rule) = recompiledRule(exampleText: t.exampleText,
                                                            compiledPattern: t.compiledPattern,
                                                            slotMapJSON: t.slotMapJSON) else {
                continue   // ★ untouched — original rule preserved exactly
            }
            t.compiledPattern = rule.pattern
            t.slotMapJSON = rule.slotMapJSON
            t.suggestedTriggerKeyword = rule.triggerKeyword
            upgraded += 1
        }
        if upgraded > 0 { try? ctx.save() }
        return upgraded
    }
}
