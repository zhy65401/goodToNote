//
//  LanguageManager.swift
//  GoodToNote
//
//  GN-033 — In-app language override (跟随系统 / 简体中文 / English) on top of the
//  existing String Catalog (en + zh-Hans). Pure Foundation logic over the
//  `AppleLanguages` UserDefaults key, so it is unit-testable without UIKit/SwiftUI.
//
//  Mechanics: iOS reads the per-app preferred-language order from the `AppleLanguages`
//  UserDefaults key at launch and resolves the bundle's localization from its first
//  entry. Writing ["zh-Hans"] / ["en"] pins the app; removing the key restores
//  "follow the system language order". The change takes effect on the NEXT launch
//  (the bundle's localization is cached for the running process) — callers prompt the
//  user to restart; we deliberately do NOT attempt a hot swap.
//

import Foundation

enum LanguageManager {

    /// The three user-selectable options. Raw values are EXACTLY the catalog / `.lproj`
    /// language codes so they can be written straight into `AppleLanguages`.
    enum AppLanguage: String, CaseIterable, Identifiable {
        case system          // follow the system language order (no override)
        case zhHans = "zh-Hans"
        case en

        var id: String { rawValue }
    }

    private static let key = "AppleLanguages"

    /// The currently-applied override, derived from the PRIMARY (first) preferred language.
    /// Any value that is not a localization we ship (or a missing/empty key) → `.system`.
    static func current(defaults: UserDefaults = .standard) -> AppLanguage {
        guard let first = (defaults.array(forKey: key) as? [String])?.first else {
            return .system
        }
        switch first {
        case AppLanguage.zhHans.rawValue: return .zhHans
        case AppLanguage.en.rawValue:     return .en
        default:                          return .system   // robust fallback (e.g. "fr")
        }
    }

    /// Apply an override. `.system` REMOVES the key (so the app follows the system
    /// language and keeps tracking later system changes) — it must never pin the
    /// current system value, which would lock the choice in.
    static func apply(_ lang: AppLanguage, defaults: UserDefaults = .standard) {
        switch lang {
        case .system:
            defaults.removeObject(forKey: key)
        case .zhHans, .en:
            defaults.set([lang.rawValue], forKey: key)
        }
    }
}

extension LanguageManager.AppLanguage {
    /// Human-readable label for the picker. Language endonyms (简体中文 / English) are
    /// intentionally shown in their own script; "跟随系统" is localized.
    var displayName: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .zhHans: return String(localized: "简体中文")
        case .en:     return String(localized: "English")
        }
    }
}
