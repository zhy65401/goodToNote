//
//  ShortcutsLauncher.swift
//  GoodToNote
//
//  GN-036 — REUSABLE "open Shortcuts and jump back" infrastructure (GN-037 SMS onboarding will
//  reuse it verbatim). Two pieces:
//
//   1. ShortcutsLauncher — thin wrappers over the documented Shortcuts URL schemes:
//        • openShortcutsApp()      → shortcuts://                (land the user in the app)
//        • openAutomationTab()     → shortcuts://create-automation (best-effort; falls back to
//                                     shortcuts:// — there is NO documented deep link straight into
//                                     the Automation tab, GN-022, so the guide cards do the rest)
//        • runShortcut(name:xSuccess:) → shortcuts://x-callback-url/run-shortcut?name=…&x-success=…
//                                     runs a named shortcut and, when it finishes, iOS opens the
//                                     x-success URL — point it at goodtonote://… to auto-return.
//      All percent-encode their inputs and open via UIApplication.
//
//   2. DeepLinkRoute — parses an incoming goodtonote:// URL (handled in RootView.onOpenURL) into a
//      typed route. v1 knows the wallet-setup callbacks; unknown URLs → nil (ignored safely).
//
//  Why this matters (GN-036 Task 4 / GN-035 §D2): the floor "user hand-builds one automation"
//  cannot be removed, but bouncing the user back into the app automatically after each Shortcuts
//  step removes the "now switch back and tap Next" friction. The x-success callback ONLY works if
//  the app registers the goodtonote:// scheme (Info.plist CFBundleURLTypes) AND routes it — both
//  done in GN-036.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum ShortcutsLauncher {
    /// The app's custom URL scheme (registered in Info.plist CFBundleURLTypes).
    static let appScheme = "goodtonote"

    /// Open the Shortcuts app at its root (the only universally-documented door — GN-022).
    static func openShortcutsApp() {
        open("shortcuts://")
    }

    /// Best-effort: open Shortcuts' "create automation" surface. iOS exposes no guaranteed deep
    /// link to the Automation tab, so if this scheme isn't honored the system simply opens
    /// Shortcuts (handled by the fallback) and the step cards guide the user the rest of the way.
    static func openAutomationTab() {
        // shortcuts://create-automation is honored on recent iOS; fall back to the root.
        if !open("shortcuts://create-automation") {
            open("shortcuts://")
        }
    }

    /// Run a named shortcut and auto-return to the app when it finishes, by passing an x-success
    /// callback URL (must be a goodtonote:// URL the app routes). Use this for the "一键导入/运行"
    /// convenience once the user has the import shortcut installed.
    /// - Parameters:
    ///   - name: the exact shortcut name to run.
    ///   - xSuccess: the callback URL opened on success (e.g. "goodtonote://walletsetup/next").
    @discardableResult
    static func runShortcut(name: String, xSuccess: String) -> Bool {
        let n = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let s = xSuccess.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? xSuccess
        return open("shortcuts://x-callback-url/run-shortcut?name=\(n)&x-success=\(s)")
    }

    /// Build a goodtonote:// callback URL string for a given path (DRY for callers building
    /// x-success targets). e.g. callbackURL("walletsetup/next") → "goodtonote://walletsetup/next".
    static func callbackURL(_ path: String) -> String {
        "\(appScheme)://\(path)"
    }

    /// Open a URL string via UIApplication; returns whether the system accepted it. No-op (false)
    /// on platforms without UIKit (keeps this file linkable in pure-Foundation test harnesses).
    @discardableResult
    static func open(_ urlString: String) -> Bool {
        #if canImport(UIKit)
        guard let url = URL(string: urlString) else { return false }
        guard UIApplication.shared.canOpenURL(url) else {
            // canOpenURL may be false for x-callback-url without the scheme declared; still try.
            UIApplication.shared.open(url)
            return true
        }
        UIApplication.shared.open(url)
        return true
        #else
        return false
        #endif
    }
}

/// A typed route parsed from an incoming goodtonote:// deep link. Pure value type (no UIKit) so it
/// is unit-testable. Add cases as more callbacks are needed (GN-037 will add SMS-setup routes).
enum DeepLinkRoute: Equatable {
    /// goodtonote://walletsetup/next — advance the Apple Pay setup guide to the next card.
    case walletSetupNext
    /// goodtonote://walletsetup/done — the import/run finished; mark the guide complete.
    case walletSetupDone
    /// GN-039: goodtonote://emailsetup/next — advance the EMAIL setup guide to the next card.
    case emailSetupNext
    /// GN-039: goodtonote://emailsetup/done — the import/run finished; mark the email guide complete.
    case emailSetupDone

    /// Parse a URL into a route, or nil if it isn't a recognized goodtonote:// deep link.
    /// Robust to the host living in either `host` or the first path segment, and ignores a
    /// trailing slash / query (x-callback-url appends x-source etc.).
    init?(url: URL) {
        guard url.scheme?.lowercased() == ShortcutsLauncher.appScheme else { return nil }
        // Normalize "goodtonote://walletsetup/next" → ["walletsetup","next"].
        var segments: [String] = []
        if let host = url.host, !host.isEmpty { segments.append(host.lowercased()) }
        segments.append(contentsOf:
            url.path.split(separator: "/").map { $0.lowercased() })
        switch segments {
        case ["walletsetup", "next"]: self = .walletSetupNext
        case ["walletsetup", "done"]: self = .walletSetupDone
        case ["emailsetup", "next"]:  self = .emailSetupNext
        case ["emailsetup", "done"]:  self = .emailSetupDone
        default: return nil
        }
    }
}
