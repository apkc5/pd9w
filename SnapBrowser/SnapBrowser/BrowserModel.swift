import Foundation
import WebKit
import UIKit

/// Tab manager for the browser (v0.2: multi-tab, matching the Android
/// version's model — every tab keeps its WKWebView alive for the session).
///
/// Persistence rule for this app: files + UserDefaults only.
/// No Keychain anywhere (AltStore re-signing breaks Keychain access —
/// that is what kept logging the user out of another sideloaded app).
@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var activeTabID: UUID = UUID()

    let bookmarks = BookmarkStore()
    let history = HistoryStore()

    private static let sessionKey = "session.tabs.v2"
    private var didResolveArchives = false

    var activeTab: BrowserTab {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    init() {
        restoreSession()
        if tabs.isEmpty {
            let tab = makeTab()
            tabs = [tab]
            activeTabID = tab.id
        }
    }

    // MARK: - Tab operations

    private func makeTab(startURL: URL? = nil) -> BrowserTab {
        let tab = BrowserTab(startURL: startURL)
        tab.onVisit = { [weak self] title, url in
            self?.history.record(title: title, url: url)
            self?.persistSession()
        }
        return tab
    }

    @discardableResult
    func newTab(url: URL? = nil) -> BrowserTab {
        activeTab.capturePreview()
        let tab = makeTab(startURL: url)
        tabs.append(tab)
        activeTabID = tab.id
        persistSession()
        return tab
    }

    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let wasActive = tab.id == activeTabID
        tabs.remove(at: index)
        if tabs.isEmpty {
            let fresh = makeTab()
            tabs = [fresh]
            activeTabID = fresh.id
        } else if wasActive {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        persistSession()
    }

    func selectTab(_ tab: BrowserTab) {
        guard tab.id != activeTabID else { return }
        activeTab.capturePreview()
        activeTabID = tab.id
        persistSession()
    }

    func captureAllPreviews() {
        for tab in tabs { tab.capturePreview() }
    }

    /// Opens a URL in the active tab (used by bookmarks / history / library).
    func openInActiveTab(_ urlString: String) {
        if urlString.lowercased().hasPrefix("javascript:") {
            activeTab.runBookmarklet(urlString)
            return
        }
        guard let url = URL(string: urlString) else { return }
        activeTab.load(url)
        persistSession()
    }

    /// Opens a saved snapshot in a fresh tab, like the Android version.
    func openArchive(item: SnapshotItem, store: SnapshotStore) {
        let tab = newTab()
        tab.openArchive(item: item, store: store)
        persistSession()
    }

    // MARK: - Session persistence (URLs only; web views rebuild on launch)

    private struct SessionTab: Codable {
        var url: String?
        var archiveFolder: String?
    }

    private struct SessionState: Codable {
        var tabs: [SessionTab]
        var activeIndex: Int
    }

    private func persistSession() {
        let state = SessionState(
            tabs: tabs.map { tab in
                if let snapshot = tab.archiveSnapshot {
                    return SessionTab(url: nil, archiveFolder: snapshot.folderName)
                }
                if tab.showsStartPage {
                    return SessionTab(url: nil, archiveFolder: nil)
                }
                return SessionTab(url: tab.webView.url?.absoluteString, archiveFolder: nil)
            },
            activeIndex: tabs.firstIndex { $0.id == activeTabID } ?? 0)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        }
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: Self.sessionKey),
              let state = try? JSONDecoder().decode(SessionState.self, from: data),
              !state.tabs.isEmpty else { return }
        var restored: [BrowserTab] = []
        for entry in state.tabs {
            if let folder = entry.archiveFolder {
                let tab = makeTab()
                tab.pendingArchiveFolderName = folder
                restored.append(tab)
            } else if let urlString = entry.url, let url = URL(string: urlString) {
                restored.append(makeTab(startURL: url))
            } else {
                restored.append(makeTab())
            }
        }
        tabs = restored
        let index = min(max(state.activeIndex, 0), restored.count - 1)
        activeTabID = restored[index].id
    }

    /// Archive tabs restored from a previous session only know their folder
    /// name; resolve them against the store once it is available.
    func resolvePendingArchives(using store: SnapshotStore) {
        guard !didResolveArchives else { return }
        didResolveArchives = true
        for tab in tabs {
            guard let folder = tab.pendingArchiveFolderName else { continue }
            tab.pendingArchiveFolderName = nil
            if let item = store.items.first(where: { $0.folderName == folder }) {
                tab.openArchive(item: item, store: store)
            } else {
                tab.showStartPage()
            }
        }
    }
}
