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
                LabeledContent("App", value: "Good to note")
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
}

#Preview {
    NavigationStack { AboutView() }
}
