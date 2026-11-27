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
    let playlist = PlaylistStore()
    let settings = AppSettings()
    /// File downloads handed over by tabs (v0.4.9).
    let downloads = DownloadStore()

    /// Set by ContentView so closed archive tabs can be restored
    /// and tear-offs can resolve (the store lives in the view tree).
    weak var snapshotStore: SnapshotStore?

    private static let sessionKey = "session.tabs.v2"
    private static let closedTabsKey = "session.closedTabs.v1"
    private var didResolveArchives = false

    // MARK: - Closed tabs (v0.4.9)

    struct ClosedTab: Codable {
        var title: String
        var url: String?
        var archiveFolder: String?
    }

    /// Most-recent-first stack of closed tabs (max 20), persisted so
    /// Cmd+Shift+T also works after a relaunch. Private tabs are
    /// never recorded — restoring one would leak its URL.
    @Published private(set) var closedTabs: [ClosedTab] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(closedTabs) {
                UserDefaults.standard.set(data, forKey: Self.closedTabsKey)
            }
        }
    }

    /// Monotonic counter bumped when a keyboard shortcut asks the
    /// active tab's view to focus the address bar (Cmd+L).
    @Published var addressFocusRequest: Int = 0

    var activeTab: BrowserTab {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.closedTabsKey),
           let decoded = try? JSONDecoder().decode([ClosedTab].self, from: data) {
            closedTabs = decoded
        }
        restoreSession()
        if tabs.isEmpty {
            let tab = makeTab()
            tabs = [tab]
            activeTabID = tab.id
        }
    }

    // MARK: - Tab operations

    private func makeTab(startURL: URL? = nil, isPrivate: Bool = false) -> BrowserTab {
        let tab = BrowserTab(startURL: startURL, settings: settings, isPrivate: isPrivate)
        tab.onVisit = { [weak self, weak tab] title, url in
            guard let self, let tab, !tab.isPrivate else { return }
            self.history.record(title: title, url: url)
            self.persistSession()
        }
        // window.open / target=_blank / context-menu "open in new
        // tab" all land here (v0.4.9).
        tab.onOpenInNewTab = { [weak self] url in
            self?.newTab(url: url)
        }
        tab.downloadHandler = { [weak self] download in
            self?.downloads.attach(download)
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

    /// Private tab (v0.4): non-persistent data store, no history, and
    /// its URL is never written into the saved session.
    @discardableResult
    func newPrivateTab() -> BrowserTab {
        activeTab.capturePreview()
        let tab = makeTab(isPrivate: true)
        tabs.append(tab)
        activeTabID = tab.id
        persistSession()
        return tab
    }

    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let wasActive = tab.id == activeTabID
        recordClosedTab(tab)
        tab.teardown()
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

    // MARK: - Closed-tab restore + tab cycling (v0.4.9)

    private func recordClosedTab(_ tab: BrowserTab) {
        guard !tab.isPrivate else { return }
        if let snapshot = tab.archiveSnapshot {
            closedTabs.insert(ClosedTab(title: snapshot.title,
                                        url: nil,
                                        archiveFolder: snapshot.folderName), at: 0)
        } else if !tab.showsStartPage, let url = tab.webView.url?.absoluteString {
            let title = tab.pageTitle.isEmpty ? url : tab.pageTitle
            closedTabs.insert(ClosedTab(title: title, url: url, archiveFolder: nil), at: 0)
        } else {
            return // a blank start-page tab leaves nothing to restore
        }
        if closedTabs.count > 20 {
            closedTabs.removeLast(closedTabs.count - 20)
        }
    }

    /// Reopens the most recently closed tab as a normal tab.
    func restoreClosedTab() {
        guard let closed = closedTabs.first else { return }
        closedTabs.removeFirst()
        if let folder = closed.archiveFolder {
            if let store = snapshotStore,
               let item = store.items.first(where: { $0.folderName == folder }) {
                openArchive(item: item, store: store)
            } else if let url = closed.url, let url = URL(string: url) {
                newTab(url: url)
            } else {
                newTab()
            }
        } else if let urlString = closed.url, let url = URL(string: urlString) {
            newTab(url: url)
        } else {
            newTab()
        }
    }

    func selectNextTab() { cycleTab(by: 1) }
    func selectPreviousTab() { cycleTab(by: -1) }

    private func cycleTab(by delta: Int) {
        guard tabs.count > 1,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        let next = tabs[(index + delta + tabs.count) % tabs.count]
        selectTab(next)
    }

    func captureAllPreviews() {
        // Background previews are captured at the active tab's real
        // (window) size so their aspect matches what the user sees —
        // see BrowserTab.capturePreview(matching:).
        let reference = activeTab.webView.bounds.size
        for tab in tabs { tab.capturePreview(matching: reference) }
    }

    // MARK: - Settings support (v0.4)

    /// Applies the settings text size (page zoom) to every open tab.
    func applyTextSizeToAllTabs() {
        for tab in tabs { tab.applyTextSize() }
    }

    /// Removes all website data (cookies, caches, storage) from the
    /// default store. Bookmarks, history records and snapshots are
    /// app data, not website data, and are handled separately.
    func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, modifiedSince: Date.distantPast) {
                continuation.resume()
            }
        }
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
                if tab.isPrivate {
                    // Private tabs restore as a plain start page.
                    return SessionTab(url: nil, archiveFolder: nil)
                }
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
