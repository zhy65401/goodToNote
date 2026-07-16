//
//  AboutView.swift
//  GoodToNote
//
//  GN-033 — "关于" drill-in page (moved out of the flat SettingsView): app name + version.
//  Owns the `Bundle.shortVersion` helper (single definition; removed from SettingsPlaceholderView).
//

import SwiftUI

struct AboutView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("App", value: Bundle.main.appDisplayName)
                LabeledContent("版本", value: Bundle.main.shortVersion)
            }
        }
        .navigationTitle(String(localized: "关于"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension Bundle {
    /// CFBundleShortVersionString (e.g. "1.13"), with an em-dash fallback.
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    /// Localized CFBundleDisplayName (en "5 cents" / zh-Hans "5分钱") — the same
    /// value shown under the home-screen icon. Prefers the per-language
    /// InfoPlist.strings override, falling back to the base Info.plist value.
    var appDisplayName: String {
        (localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? "5 cents"
    }
}

#Preview {
    NavigationStack { AboutView() }
}
