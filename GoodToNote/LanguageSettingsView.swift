//
//  LanguageSettingsView.swift
//  GoodToNote
//
//  GN-033 — In-app language picker (跟随系统 / 简体中文 / English). Writes the chosen
//  override via LanguageManager (AppleLanguages UserDefaults key) and prompts the user to
//  restart, since the bundle's localization is fixed for the running process. We do NOT
//  attempt a hot language swap; the current screen stays in its current language until relaunch.
//

import SwiftUI

struct LanguageSettingsView: View {
    /// Re-read on appear so the checkmark reflects what is actually pinned.
    @State private var selection: LanguageManager.AppLanguage = LanguageManager.current()
    @State private var showRestartPrompt = false

    var body: some View {
        List {
            Section {
                ForEach(LanguageManager.AppLanguage.allCases) { lang in
                    Button {
                        choose(lang)
                    } label: {
                        HStack {
                            Text(lang.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if lang == selection {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())   // memory: tappable-row-contentshape
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("切换语言后需重启 App 才会生效。")
            }
        }
        .navigationTitle(String(localized: "语言"))
        .navigationBarTitleDisplayMode(.inline)
        .alert("语言已切换,重启 App 后生效", isPresented: $showRestartPrompt) {
            // Gentle by default: just acknowledge. Second button restarts immediately
            // (same exit(0) style as GN-014 restore), for users who want it now.
            Button("好", role: .cancel) {}
            Button("立即重启") { exit(0) }
        }
    }

    private func choose(_ lang: LanguageManager.AppLanguage) {
        // Reapply even if equal is harmless, but only prompt when the choice changed.
        let changed = lang != selection
        LanguageManager.apply(lang)
        selection = lang
        if changed { showRestartPrompt = true }
    }
}

#Preview {
    NavigationStack { LanguageSettingsView() }
}
