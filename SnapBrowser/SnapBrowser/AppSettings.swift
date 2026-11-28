import Foundation
import SwiftUI
import UIKit

/// Search engines the address bar can resolve plain text with (v0.4).
/// Brave Search stays the default, matching the Android version.
enum SearchEngine: String, CaseIterable, Identifiable {
    case brave, google, duckduckgo, bing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brave: return "Brave Search"
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }

    func searchURL(for query: String) -> URL? {
        var components: URLComponents?
        switch self {
        case .brave: components = URLComponents(string: "https://search.brave.com/search")
        case .google: components = URLComponents(string: "https://www.google.com/search")
        case .duckduckgo: components = URLComponents(string: "https://duckduckgo.com/")
        case .bing: components = URLComponents(string: "https://www.bing.com/search")
        }
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

/// The start page's walking pet (v0.4.9, item 9). All artwork is
/// bundled external material — see PetAssets.swift for the source
/// and license of each animal. `.none` hides the pet entirely.
enum HomePet: String, CaseIterable, Identifiable {
    case cat, dog, duck, penguin, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cat: return "猫"
        case .dog: return "犬"
        case .duck: return "あひる"
        case .penguin: return "ペンギン"
        case .none: return "なし"
        }
    }
}

/// User preferences (v0.4). UserDefaults only — no Keychain anywhere in
/// this app (AltStore re-signing breaks Keychain access).
final class AppSettings: ObservableObject {
    private enum Keys {
        static let searchEngine = "settings.searchEngine"
        static let desktopDefault = "settings.desktopByDefault"
        static let textSize = "settings.textSizePercent"
        static let searchSuggestions = "settings.searchSuggestionsEnabled"
        static let suggestPromptDismissed = "settings.suggestPromptDismissed"
        static let hiddenSuggestionURLs = "settings.hiddenSuggestionURLs"
        static let homePet = "settings.homePet"
        static let hiddenShortcutURLs = "settings.hiddenShortcutURLs"
        static let shieldsEnabled = "settings.shieldsEnabled"
        static let shieldsDisabledSites = "settings.shieldsDisabledSites"
    }

    @Published var searchEngine: SearchEngine {
        didSet { UserDefaults.standard.set(searchEngine.rawValue, forKey: Keys.searchEngine) }
    }

    /// New tabs start in desktop mode when this is on.
    @Published var desktopByDefault: Bool {
        didSet { UserDefaults.standard.set(desktopByDefault, forKey: Keys.desktopDefault) }
    }

    /// Page zoom applied to every tab (WKWebView.pageZoom), in percent.
    @Published var textSizePercent: Int {
        didSet { UserDefaults.standard.set(textSizePercent, forKey: Keys.textSize) }
    }

    /// Search suggestions in the address-bar panel (v0.4.5). OFF by
    /// default: while on, the typed text is sent to the selected
    /// search engine on every keystroke, so — exactly like Brave —
    /// this is an explicit opt-in, never silently enabled.
    @Published var searchSuggestionsEnabled: Bool {
        didSet { UserDefaults.standard.set(searchSuggestionsEnabled, forKey: Keys.searchSuggestions) }
    }

    /// Set when the user answers 「無効にする」 on the panel's opt-in
    /// prompt (v0.4.5). The prompt never comes back afterwards, but
    /// the Settings toggle can still turn suggestions on later.
    @Published var suggestPromptDismissed: Bool {
        didSet { UserDefaults.standard.set(suggestPromptDismissed, forKey: Keys.suggestPromptDismissed) }
    }

    /// URLs hidden from the address-bar panel's 「お使いのデバイス」
    /// section via its per-row × button (v0.4.8). Hide-only: the
    /// history and bookmark stores are NEVER touched — a hidden entry
    /// stays fully visible in the History / Bookmarks screens, and
    /// this set only filters what the panel offers. Persisted in
    /// UserDefaults; Settings can reset it back to empty.
    @Published private(set) var hiddenSuggestionURLs: Set<String> {
        didSet {
            UserDefaults.standard.set(hiddenSuggestionURLs.sorted(),
                                      forKey: Keys.hiddenSuggestionURLs)
        }
    }

    /// Which animal walks along the start page's bottom edge
    /// (v0.4.9, item 9). Defaults to the cat.
    @Published var homePet: HomePet {
        didSet { UserDefaults.standard.set(homePet.rawValue, forKey: Keys.homePet) }
    }

    /// Bookmark URLs removed from the start page's shortcut grid via
    /// its long-press menu (v0.4.9, item 8). Same hide-only rule as
    /// the panel's hidden suggestions: the bookmark itself is never
    /// deleted and stays in the Bookmarks screen.
    @Published private(set) var hiddenShortcutURLs: Set<String> {
        didSet {
            UserDefaults.standard.set(hiddenShortcutURLs.sorted(),
                                      forKey: Keys.hiddenShortcutURLs)
        }
    }

    /// Shields master switch (v0.4.14). ON by default: unlike the
    /// search suggestions nothing leaves the device, so there is
    /// no opt-in reason to default off (Brave ships Shields on).
    @Published var shieldsEnabled: Bool {
        didSet { UserDefaults.standard.set(shieldsEnabled, forKey: Keys.shieldsEnabled) }
    }

    /// Site keys (host with a leading "www." stripped) where the
    /// user turned Shields off for that site (v0.4.14). The set is
    /// compiled into the rule list as ignore-previous-rules
    /// entries by ShieldsController; persisted in UserDefaults.
    @Published private(set) var shieldsDisabledSites: Set<String> {
        didSet {
            UserDefaults.standard.set(shieldsDisabledSites.sorted(),
                                      forKey: Keys.shieldsDisabledSites)
        }
    }

    /// The per-site key for a host: "www.example.com" and
    /// "example.com" are the same site for exemption purposes.
    static func shieldsSiteKey(host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Whether blocking is in force for a page on this host:
    /// the master switch is on and the site is not exempted.
    func isShieldsActive(forHost host: String) -> Bool {
        shieldsEnabled && !shieldsDisabledSites.contains(Self.shieldsSiteKey(host: host))
    }

    func setShieldsActive(_ active: Bool, forHost host: String) {
        let key = Self.shieldsSiteKey(host: host)
        if active {
            shieldsDisabledSites.remove(key)
        } else {
            shieldsDisabledSites.insert(key)
        }
    }

    func resetShieldsDisabledSites() {
        shieldsDisabledSites = []
    }

    func hideShortcutURL(_ url: String) {
        hiddenShortcutURLs.insert(url)
    }

    func isShortcutHidden(_ url: String) -> Bool {
        hiddenShortcutURLs.contains(url)
    }

    func hideSuggestionURL(_ url: String) {
        hiddenSuggestionURLs.insert(url)
    }

    func isSuggestionHidden(_ url: String) -> Bool {
        hiddenSuggestionURLs.contains(url)
    }

    func resetHiddenSuggestions() {
        hiddenSuggestionURLs = []
    }

    init() {
        let defaults = UserDefaults.standard
        searchEngine = SearchEngine(rawValue: defaults.string(forKey: Keys.searchEngine) ?? "") ?? .brave
        desktopByDefault = defaults.bool(forKey: Keys.desktopDefault)
        searchSuggestionsEnabled = defaults.bool(forKey: Keys.searchSuggestions)
        suggestPromptDismissed = defaults.bool(forKey: Keys.suggestPromptDismissed)
        hiddenSuggestionURLs = Set(defaults.stringArray(forKey: Keys.hiddenSuggestionURLs) ?? [])
        homePet = HomePet(rawValue: defaults.string(forKey: Keys.homePet) ?? "") ?? .cat
        hiddenShortcutURLs = Set(defaults.stringArray(forKey: Keys.hiddenShortcutURLs) ?? [])
        // Shields defaults ON: only an explicitly stored value
        // can turn it off.
        shieldsEnabled = defaults.object(forKey: Keys.shieldsEnabled) == nil
            ? true : defaults.bool(forKey: Keys.shieldsEnabled)
        shieldsDisabledSites = Set(defaults.stringArray(forKey: Keys.shieldsDisabledSites) ?? [])
        let storedSize = defaults.integer(forKey: Keys.textSize)
        textSizePercent = storedSize == 0 ? 100 : storedSize
    }
}

// MARK: - System share sheet

struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// UIActivityViewController wrapper (page share / snapshot file share).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
