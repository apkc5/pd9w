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

/// User preferences (v0.4). UserDefaults only — no Keychain anywhere in
/// this app (AltStore re-signing breaks Keychain access).
final class AppSettings: ObservableObject {
    private enum Keys {
        static let searchEngine = "settings.searchEngine"
        static let desktopDefault = "settings.desktopByDefault"
        static let textSize = "settings.textSizePercent"
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

    init() {
        let defaults = UserDefaults.standard
        searchEngine = SearchEngine(rawValue: defaults.string(forKey: Keys.searchEngine) ?? "") ?? .brave
        desktopByDefault = defaults.bool(forKey: Keys.desktopDefault)
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
