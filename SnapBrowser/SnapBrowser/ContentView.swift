import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var manager = BrowserModel()
    @StateObject private var store = SnapshotStore()
    @State private var sheet: SheetKind?
    @State private var showingTabs = false
    @State private var sharePayload: SharePayload?
    @State private var showingReader = false
    @State private var showingAddBookmark = false

    private enum SheetKind: String, Identifiable {
        case library, bookmarks, history, settings, playlist
        var id: String { rawValue }
    }

    var body: some View {
        BrowserTabView(
            tab: manager.activeTab,
            manager: manager,
            store: store,
            settings: manager.settings,
            onShowTabs: {
                manager.captureAllPreviews()
                showingTabs = true
            },
            onShowLibrary: { sheet = .library },
            onShowBookmarks: { sheet = .bookmarks },
            onShowHistory: { sheet = .history },
            onShowSettings: { sheet = .settings },
            onShowPlaylist: { sheet = .playlist },
            onAddBookmark: { showingAddBookmark = true },
            onShare: { shareCurrentPage() },
            onReader: { showingReader = true }
        )
        .id(manager.activeTabID)
        .background(Theme.paper)
        .fullScreenCover(isPresented: $showingTabs) {
            TabOverviewView(manager: manager)
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .library:
                NavigationStack {
                    SnapshotLibraryView(store: store,
                                        onOpenInBrowser: { item in
                                            manager.openArchive(item: item, store: store)
                                            sheet = nil
                                        },
                                        onOpenURL: { url in
                                            manager.openInActiveTab(url)
                                            sheet = nil
                                        })
                }
            case .bookmarks:
                BookmarksView(
                    store: manager.bookmarks,
                    currentPage: {
                        let tab = manager.activeTab
                        guard !tab.showsStartPage, let url = tab.currentURLString else { return nil }
                        return (tab.pageTitle, url)
                    },
                    onOpen: { url in
                        manager.openInActiveTab(url)
                        sheet = nil
                    },
                    onAddToPlaylist: { bookmark in
                        manager.playlist.add(title: bookmark.title,
                                             url: bookmark.url,
                                             pageURL: nil)
                    })
            case .history:
                HistoryView(store: manager.history,
                            onOpen: { url in
                                manager.openInActiveTab(url)
                                sheet = nil
                            })
            case .settings:
                SettingsView(manager: manager, settings: manager.settings)
            case .playlist:
                PlaylistView(store: manager.playlist)
            }
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items)
        }
        .sheet(isPresented: $showingReader) {
            ReaderView(tab: manager.activeTab)
        }
        .sheet(isPresented: $showingAddBookmark) {
            if let page = currentPageForBookmark {
                AddBookmarkView(store: manager.bookmarks,
                                initialTitle: page.title,
                                url: page.url)
            }
        }
        .onAppear {
            store.reload()
            manager.resolvePendingArchives(using: store)
        }
        .onContinueUserActivity(TabTearOff.activityType) { activity in
            handleTornOffTab(activity)
        }
    }

    /// Receiving end of the tab-strip tear-off: a scene created for a
    /// dragged-out tab lands here with the tab's URL (or archive
    /// folder) in the activity and opens it as a tab in this scene.
    private func handleTornOffTab(_ activity: NSUserActivity) {
        if let folder = activity.userInfo?[TabTearOff.archiveFolderKey] as? String {
            store.reload()
            if let item = store.items.first(where: { $0.folderName == folder }) {
                manager.openArchive(item: item, store: store)
            }
        } else if let urlString = activity.userInfo?[TabTearOff.urlKey] as? String,
                  let url = URL(string: urlString) {
            _ = manager.newTab(url: url)
        }
    }

    private var currentPageForBookmark: (title: String, url: String)? {
        let tab = manager.activeTab
        guard !tab.showsStartPage, let url = tab.currentURLString else { return nil }
        return (tab.pageTitle, url)
    }

    private func shareCurrentPage() {
        let tab = manager.activeTab
        guard !tab.showsStartPage,
              let urlString = tab.currentURLString,
              let url = URL(string: urlString) else { return }
        sharePayload = SharePayload(items: [url])
    }
}

// MARK: - One tab's chrome (address bar / banners / page / find bar / toolbar)

private struct BrowserTabView: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var manager: BrowserModel
    @ObservedObject var store: SnapshotStore
    @ObservedObject var settings: AppSettings
    var onShowTabs: () -> Void
    var onShowLibrary: () -> Void
    var onShowBookmarks: () -> Void
    var onShowHistory: () -> Void
    var onShowSettings: () -> Void
    var onShowPlaylist: () -> Void
    var onAddBookmark: () -> Void
    var onShare: () -> Void
    var onReader: () -> Void

    @State private var findActive = false
    @State private var findQuery = ""
    @State private var findCount: Int?
    @State private var findMiss = false
    @State private var showMediaPicker = false
    @State private var mediaPickerItems: [DetectedMedia] = []
    @State private var playlistNotice: String?
    @State private var toastText: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var stripFrame: CGRect = .zero
    @FocusState private var addressFocused: Bool
    @State private var suggestions: [String] = []
    @State private var suggestTask: Task<Void, Never>?
    /// Measured height of the suggestion panel's rows (v0.4.7). The
    /// panel lives in an overlay on the address bar, whose layout
    /// proposal is the bar's own size — left to itself the panel's
    /// ScrollView collapsed to ~2 rows and everything below (the
    /// remaining suggestions, the whole on-device section) sat
    /// hidden under the fold. The rows' real height is measured and
    /// fed back as an explicit frame height, capped relative to
    /// the window height.
    @State private var panelRowsHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
        VStack(spacing: 0) {
            addressBar
                .overlay(alignment: .topLeading) {
                    // Address-bar panel (v0.4.5): suggestions / find /
                    // on-device matches, dropped from the bar over the
                    // strip and page like Brave's. An overlay (not a
                    // VStack row) so the web view is never resized —
                    // and reflown — while the user is typing.
                    if addressFocused {
                        suggestionPanel(containerHeight: geo.size.height)
                            .frame(width: geo.size.width)
                            .offset(y: 62)
                    }
                }
                .zIndex(20)
            if geo.size.width >= 700 {
                tabStrip
            }
            if let item = tab.archiveSnapshot {
                archiveBanner(item)
            } else if tab.isPrivate {
                privateStrip
            }
            if tab.isLoading {
                ProgressView(value: tab.estimatedProgress)
                    .progressViewStyle(.linear)
                    .tint(Theme.cobalt)
            }
            ZStack {
                WebView(webView: tab.webView)
                    .opacity(tab.showsStartPage ? 0 : 1)
                    .allowsHitTesting(!tab.showsStartPage)
                if tab.showsStartPage {
                    StartPageView(tab: tab, bookmarks: manager.bookmarks,
                                  onShowBookmarks: onShowBookmarks)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            if findActive {
                findBar
            }
            toolbar
        }
        .overlay(alignment: .bottom) {
            if let toastText {
                Text(toastText)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .padding(.bottom, 64)
                    .transition(.opacity)
            }
        }
        }
        .background(Theme.paper)
        .onChange(of: tab.addressText) { _ in refreshSuggestions() }
        .onChange(of: settings.searchEngine) { _ in refreshSuggestions() }
        .onChange(of: settings.searchSuggestionsEnabled) { _ in refreshSuggestions() }
        .onChange(of: addressFocused) { focused in
            if focused {
                refreshSuggestions()
            } else {
                suggestTask?.cancel()
                suggestions = []
            }
        }
        .alert("スナップ結果", isPresented: snapAlertBinding) {
            Button("OK", role: .cancel) { tab.lastSnapResult = nil }
        } message: {
            if let result = tab.lastSnapResult {
                Text(snapMessage(result))
            }
        }
        .sheet(isPresented: $showMediaPicker) {
            DetectedMediaSheet(playlist: manager.playlist,
                               items: mediaPickerItems,
                               pageTitle: tab.pageTitle,
                               onAdded: { count in
                                   showToast("Playlistに \(count) 件追加しました")
                               })
        }
        .confirmationDialog("この動画をPlaylistに追加しますか？",
                            isPresented: pendingLongPressBinding,
                            titleVisibility: .visible) {
            Button("Playlistに追加") {
                if let media = tab.pendingLongPress {
                    addToPlaylist(title: tab.pageTitle, url: media.url,
                                  pageURL: tab.currentURLString)
                }
                tab.pendingLongPress = nil
            }
            Button("キャンセル", role: .cancel) { tab.pendingLongPress = nil }
        } message: {
            Text(tab.pendingLongPress?.url ?? "")
        }
        .alert("動画の保存", isPresented: mediaNoticeBinding) {
            Button("OK", role: .cancel) { tab.mediaNotice = nil }
        } message: {
            Text(tab.mediaNotice ?? "")
        }
        .alert("Playlist", isPresented: playlistNoticeBinding) {
            Button("OK", role: .cancel) { playlistNotice = nil }
        } message: {
            Text(playlistNotice ?? "")
        }
    }

    // MARK: Address bar (M3-style full pill)

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: addressBarIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("URLまたは検索", text: $tab.addressText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit {
                    addressFocused = false
                    tab.loadAddressBar()
                }
            if addressFocused && !tab.addressText.isEmpty {
                // Clear button (v0.4.7): while the field is being
                // edited and holds text, a × inside the pill's right
                // end wipes it. The panel reacts through the usual
                // addressText onChange (suggestions clear, the
                // empty-query recent-history state returns). Outside
                // editing the stop / reload buttons below keep the
                // slot, untouched.
                Button { tab.addressText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
            } else if tab.isLoading {
                Button { tab.stop() } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            } else if !tab.showsStartPage {
                Button { tab.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var addressBarIcon: String {
        if tab.archiveSnapshot != nil { return "archivebox" }
        if tab.isPrivate { return "eye.slash" }
        return "lock.fill"
    }

    // MARK: Address-bar panel (v0.4.5: suggestions / find / on-device)

    /// The trimmed text currently in the address field.
    private var panelQuery: String {
        tab.addressText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True once the user has typed something that is not simply the
    /// loaded page's own URL — merely tapping the bar (which leaves
    /// the current URL in the field) must not fire suggestion fetches
    /// or pop the opt-in prompt for the URL itself.
    private var hasFreshQuery: Bool {
        !panelQuery.isEmpty && panelQuery != tab.currentURLString
    }

    private var showSuggestPrompt: Bool {
        !settings.searchSuggestionsEnabled
            && !settings.suggestPromptDismissed
            && hasFreshQuery
    }

    /// Brave-shaped dropdown under the address bar: the suggestions
    /// opt-in prompt (while off), engine suggestions (while on), a
    /// find-in-page row, and on-device matches (bookmarks first, then
    /// history). With an empty field it lists recent history instead.
    private func suggestionPanel(containerHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            if showSuggestPrompt {
                suggestPromptRow
                Divider()
            }
            ScrollView {
                VStack(spacing: 0) {
                    if settings.searchSuggestionsEnabled && hasFreshQuery {
                        panelRow(icon: "magnifyingglass", title: panelQuery) {
                            submitPanelText(panelQuery)
                        }
                        ForEach(suggestions, id: \.self) { suggestion in
                            panelRow(icon: "magnifyingglass", title: suggestion) {
                                submitPanelText(suggestion)
                            }
                        }
                    }
                    if hasFreshQuery && !tab.showsStartPage && tab.archiveSnapshot == nil {
                        panelRow(icon: "doc.text.magnifyingglass",
                                 title: "「\(panelQuery)」をページ内検索") {
                            openFindFromPanel()
                        }
                    }
                    if !deviceMatches.isEmpty {
                        deviceSectionHeader
                        ForEach(deviceMatches) { match in
                            panelRow(icon: match.isBookmark ? "bookmark.fill" : "clock.arrow.circlepath",
                                     title: match.title,
                                     subtitle: match.url) {
                                addressFocused = false
                                manager.openInActiveTab(match.url)
                            }
                        }
                    }
                }
                // Report the rows' true height (v0.4.7): inside a
                // ScrollView the content is laid out unbounded, so
                // this is the height the panel actually needs.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    panelRowsHeight = newHeight
                }
            }
            .frame(height: panelScrollHeight(containerHeight: containerHeight))
        }
        .background(Theme.paper)
        .overlay(alignment: .bottom) { Divider() }
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 6)
    }

    /// Height of the panel's scroll region (v0.4.7): the measured
    /// rows height, capped so the whole panel — opt-in prompt row
    /// included — stays within ~68% of the window height. Short
    /// content keeps the panel short; it never stretches to the
    /// cap. Before the first measurement lands, fall back to the
    /// smaller of the old 360 cap and the same window-relative cap.
    private func panelScrollHeight(containerHeight: CGFloat) -> CGFloat {
        let promptAllowance: CGFloat = showSuggestPrompt ? 60 : 0
        let cap = max(120, containerHeight * 0.68 - promptAllowance)
        guard panelRowsHeight > 0 else { return min(360, cap) }
        return min(panelRowsHeight, cap)
    }

    /// Brave's opt-in card, mirrored: suggestions stay OFF until the
    /// user explicitly enables them, because the typed text is sent
    /// to the search engine. 「無効にする」 dismisses the prompt for
    /// good (Settings can still turn the feature on later).
    private var suggestPromptRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("検索候補を有効にしますか？")
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.ink)
                Text("入力中の文字が \(settings.searchEngine.title) に送信されます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("有効化") { settings.searchSuggestionsEnabled = true }
                .font(.subheadline.bold())
                .foregroundStyle(Theme.cobalt)
                .frame(height: 44)
                .contentShape(Rectangle())
            Button("無効にする") { settings.suggestPromptDismissed = true }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.surface)
    }

    private var deviceSectionHeader: some View {
        HStack {
            Text("お使いのデバイス")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func panelRow(icon: String, title: String, subtitle: String? = nil,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private struct PanelMatch: Identifiable {
        let id: String
        let title: String
        let url: String
        let isBookmark: Bool
    }

    /// On-device matches for the typed text: bookmarks first, then
    /// history (title or URL contains the text, case-insensitive),
    /// de-duplicated by URL, 8 rows max. With an empty field this is
    /// simply the most recent history, like Brave's panel.
    private var deviceMatches: [PanelMatch] {
        let query = panelQuery
        if query.isEmpty {
            return manager.history.items.prefix(8).map {
                PanelMatch(id: "h-\($0.id.uuidString)",
                           title: $0.title, url: $0.url, isBookmark: false)
            }
        }
        var results: [PanelMatch] = []
        var seen = Set<String>()
        for bookmark in manager.bookmarks.search(query) {
            results.append(PanelMatch(id: "b-\(bookmark.id.uuidString)",
                                      title: bookmark.title, url: bookmark.url,
                                      isBookmark: true))
            seen.insert(bookmark.url)
        }
        for item in manager.history.search(query) where !seen.contains(item.url) {
            results.append(PanelMatch(id: "h-\(item.id.uuidString)",
                                      title: item.title, url: item.url,
                                      isBookmark: false))
        }
        return Array(results.prefix(8))
    }

    /// Debounced (~200ms) suggestion fetch. Stale responses are
    /// discarded by re-checking the query after the await, and any
    /// focus loss / submit cancels the in-flight task.
    private func refreshSuggestions() {
        suggestTask?.cancel()
        guard addressFocused, settings.searchSuggestionsEnabled, hasFreshQuery else {
            suggestions = []
            return
        }
        let query = panelQuery
        let engine = settings.searchEngine
        suggestTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let results = await SearchSuggestions.fetch(engine: engine, query: query)
            if Task.isCancelled { return }
            if panelQuery == query {
                suggestions = results
            }
        }
    }

    private func submitPanelText(_ text: String) {
        addressFocused = false
        if text != tab.addressText {
            tab.addressText = text
        }
        // loadAddressBar resolves domains to URLs and everything
        // else to a search with the current engine — exactly the
        // behaviour a suggestion tap needs.
        tab.loadAddressBar()
    }

    private func openFindFromPanel() {
        findQuery = panelQuery
        findActive = true
        addressFocused = false
        runFind(backwards: false)
    }

    // MARK: Archive banner (slim strip, flush under the address bar)

    private func archiveBanner(_ item: SnapshotItem) -> some View {
        HStack(spacing: 6) {
            ApertureIcon(size: 14)
            Text("保存版")
                .font(.caption.bold())
                .foregroundStyle(Theme.cobalt)
            Text("・ \(DateFormatters.banner.string(from: item.createdAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Private strip (same slim-strip language as the archive banner)

    private var privateStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.caption)
                .foregroundStyle(Theme.cobalt)
            Text("プライベート")
                .font(.caption.bold())
                .foregroundStyle(Theme.cobalt)
            Text("・ 履歴に残りません")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Tab strip (wide windows only, Brave-style tab bar)

    /// Flush strip directly under the address bar, shown only when the
    /// window is wide (≥700pt — full-screen / large floating windows on
    /// iPad). Narrow windows keep the tab-count button + grid overview.
    /// Order in the column: address bar → tab strip → archive/private
    /// banner → progress → page, so the banners never fight the strip.
    private var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(manager.tabs) { t in
                        TabStripChip(tab: t,
                                     isActive: t.id == manager.activeTabID,
                                     stripFrame: stripFrame,
                                     onSelect: { manager.selectTab(t) },
                                     onClose: { manager.closeTab(t) },
                                     onTearOff: { tearOff(t) })
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }
            Button {
                _ = manager.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider() }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { stripFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        stripFrame = frame
                    }
            }
        }
    }

    /// Tear-off: ask UIKit for a NEW scene carrying this tab. The
    /// error handler is the only failure signal the API gives, so the
    /// original tab is closed (move, not copy) by a work item that the
    /// error handler cancels if activation fails.
    private func tearOff(_ tab: BrowserTab) {
        let activity = NSUserActivity(activityType: TabTearOff.activityType)
        activity.title = "タブを新しいウィンドウで開く"
        if let item = tab.archiveSnapshot {
            activity.userInfo = [TabTearOff.archiveFolderKey: item.folderName]
        } else if let urlString = tab.currentURLString {
            activity.userInfo = [TabTearOff.urlKey: urlString]
        } else {
            return // start-page tab: nothing to carry over
        }
        let closeWork = DispatchWorkItem { manager.closeTab(tab) }
        UIApplication.shared.requestSceneSessionActivation(
            nil, userActivity: activity, options: nil
        ) { error in
            if error != nil { closeWork.cancel() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: closeWork)
    }

    // MARK: Find bar (slim strip above the toolbar while searching)

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("ページ内検索", text: $findQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { runFind(backwards: false) }
                .onChange(of: findQuery) { _ in runFind(backwards: false) }
            if findMiss {
                Text("見つかりません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let count = findCount {
                Text("\(count)件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button { runFind(backwards: true) } label: {
                Image(systemName: "chevron.up")
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Button { runFind(backwards: false) } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Button("完了") {
                findActive = false
                findQuery = ""
                findCount = nil
                findMiss = false
            }
            .foregroundStyle(Theme.cobalt)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
    }

    private func runFind(backwards: Bool) {
        let query = findQuery
        guard !query.isEmpty else {
            findCount = nil
            findMiss = false
            return
        }
        tab.findInPage(query, backwards: backwards) { found in
            findMiss = !found
        }
        Task {
            let count = await tab.countMatches(of: query)
            if query == findQuery {
                findCount = count
            }
        }
    }

    // MARK: Bottom toolbar (flush bar, line icons)

    private var toolbar: some View {
        HStack {
            Button { tab.goBack() } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!tab.canGoBack)

            Spacer()

            Button { tab.goForward() } label: {
                Image(systemName: "chevron.forward")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!tab.canGoForward)

            Spacer()

            // SNAP — aperture line icon, tiny red centre dot only.
            Button {
                tab.snap(store: store)
            } label: {
                VStack(spacing: 2) {
                    ApertureIcon(size: 22)
                    Text("SNAP")
                        .font(.caption2.bold())
                }
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .disabled(tab.isSnapping || tab.showsStartPage || tab.archiveSnapshot != nil)

            // Save badge (v0.4.6): appears ONLY when the page has
            // saveable media. Sits next to SNAP without changing the
            // bar's layout for pages without videos.
            if detectedSaveableCount > 0 {
                Spacer()

                Button {
                    mediaPickerItems = tab.detectedMedia
                    showMediaPicker = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "arrow.down.to.line")
                            .font(.body)
                            .foregroundStyle(Theme.ink)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                        Text("\(detectedSaveableCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.cobalt))
                            .offset(x: 2, y: 4)
                    }
                }
            }

            Spacer()

            // Tabs button with count, Brave-style.
            Button(action: onShowTabs) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.ink, lineWidth: 1.5)
                        .frame(width: 24, height: 24)
                    Text("\(manager.tabs.count)")
                        .font(.caption2.bold())
                        .foregroundStyle(Theme.ink)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }

            Spacer()

            Menu {
                Section {
                    Button {
                        manager.newTab()
                    } label: {
                        Label("新しいタブ", systemImage: "plus")
                    }
                    Button {
                        manager.newPrivateTab()
                    } label: {
                        Label("新しいプライベートタブ", systemImage: "eye.slash")
                    }
                }
                Section {
                    Button(action: onShare) {
                        Label("共有…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(tab.showsStartPage)
                    Button {
                        findActive = true
                    } label: {
                        Label("ページ内検索", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(tab.showsStartPage || tab.archiveSnapshot != nil)
                    Button(action: onReader) {
                        Label("リーダーモード", systemImage: "doc.plaintext")
                    }
                    .disabled(tab.showsStartPage || tab.archiveSnapshot != nil)
                    Toggle(isOn: desktopBinding) {
                        Label("PC版サイト", systemImage: "desktopcomputer")
                    }
                    Button(action: onAddBookmark) {
                        Label("ブックマークに追加…", systemImage: "bookmark")
                    }
                    .disabled(tab.showsStartPage)
                    Button {
                        addCurrentPageToPlaylist()
                    } label: {
                        Label("Playlistに追加", systemImage: "video.badge.plus")
                    }
                    .disabled(tab.showsStartPage || tab.archiveSnapshot != nil || tab.isPrivate)
                }
                Section {
                    Button(action: onShowBookmarks) {
                        Label("ブックマーク", systemImage: "bookmark.fill")
                    }
                    Button(action: onShowHistory) {
                        Label("履歴", systemImage: "clock.arrow.circlepath")
                    }
                    Button(action: onShowLibrary) {
                        Label("ライブラリ", systemImage: "books.vertical")
                    }
                    Button(action: onShowPlaylist) {
                        Label("Playlist", systemImage: "play.rectangle.on.rectangle")
                    }
                }
                Section {
                    Button(action: onShowSettings) {
                        Label("設定", systemImage: "gearshape")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
    }

    private var desktopBinding: Binding<Bool> {
        Binding(get: { tab.desktopMode },
                set: { tab.setDesktopMode($0) })
    }

    // MARK: Playlist add flows (v0.4.6)

    /// Saveable (http/https) media count for the toolbar badge.
    /// blob:-only pages keep the badge hidden — the long-press
    /// notice covers that case honestly instead.
    private var detectedSaveableCount: Int {
        tab.detectedMedia.filter { $0.isHTTP }.count
    }

    private var pendingLongPressBinding: Binding<Bool> {
        Binding(get: { tab.pendingLongPress != nil },
                set: { if !$0 { tab.pendingLongPress = nil } })
    }

    private var mediaNoticeBinding: Binding<Bool> {
        Binding(get: { tab.mediaNotice != nil },
                set: { if !$0 { tab.mediaNotice = nil } })
    }

    private var playlistNoticeBinding: Binding<Bool> {
        Binding(get: { playlistNotice != nil },
                set: { if !$0 { playlistNotice = nil } })
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation { toastText = text }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if Task.isCancelled { return }
            withAnimation { toastText = nil }
        }
    }

    private func addToPlaylist(title: String, url: String, pageURL: String?) {
        if manager.playlist.add(title: title, url: url, pageURL: pageURL) {
            showToast("Playlistに追加しました")
        } else {
            showToast("すでにPlaylistにあります")
        }
    }

    /// ⋯ menu 「Playlistに追加」: a media-file page adds itself;
    /// otherwise the page is (re)scanned and its media are added —
    /// directly when there is exactly one, via the picker sheet
    /// when there are several, and with an honest notice when there
    /// are none (or only unsaveable blob: media).
    private func addCurrentPageToPlaylist() {
        if let current = tab.currentURLString, PlaylistMedia.isMediaURL(current) {
            addToPlaylist(title: tab.pageTitle, url: current, pageURL: nil)
            return
        }
        Task {
            await tab.refreshDetectedMedia()
            let found = tab.detectedMedia
            let saveable = found.filter { $0.isHTTP }
            if saveable.isEmpty {
                playlistNotice = found.isEmpty
                    ? "このページに動画が見つかりませんでした"
                    : "このページの動画は保存できません（blob:）"
            } else if saveable.count == 1 {
                addToPlaylist(title: tab.pageTitle, url: saveable[0].url,
                              pageURL: tab.currentURLString)
            } else {
                mediaPickerItems = found
                showMediaPicker = true
            }
        }
    }

    // MARK: Snap result

    private var snapAlertBinding: Binding<Bool> {
        Binding(
            get: { tab.lastSnapResult != nil },
            set: { if !$0 { tab.lastSnapResult = nil } }
        )
    }

    private func snapMessage(_ result: BrowserTab.SnapResult) -> String {
        func fmt(_ bytes: Int?) -> String {
            guard let bytes else { return "失敗" }
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        var lines = [
            "画像: \(fmt(result.imageBytes))",
            "アーカイブ(.webarchive): \(fmt(result.archiveBytes))",
            "HTML: \(fmt(result.htmlBytes))",
            "自己完結HTML: \(fmt(result.fullHTMLBytes))" + (result.assetsInlined.map { " (資源 \($0) 内包)" } ?? ""),
            "テキスト: \(result.textChars.map { "\($0)文字" } ?? "失敗")"
        ]
        if !result.failures.isEmpty {
            lines.append("—")
            lines.append(contentsOf: result.failures)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Tab tear-off (drag a strip tab out → new window)

/// Shared keys for the tear-off NSUserActivity. The receiving scene
/// (ContentView.onContinueUserActivity) opens a tab from these.
enum TabTearOff {
    static let activityType = "jp.anko.snapbrowser.openTab"
    static let urlKey = "url"
    static let archiveFolderKey = "archiveFolder"
}

/// One chip in the tab strip: letter tile / aperture + title + ×.
/// The main area selects the tab (tap), the × closes it, and a
/// LONG-PRESS-initiated drag that ends well OUTSIDE the strip's frame
/// tears the tab off into a new window (see BrowserTabView.tearOff).
/// v0.4.3 used a plain DragGesture on the chip, which the strip's
/// horizontal ScrollView almost always claimed first — the chip just
/// scrolled inside the strip and the tear-off never fired. The
/// long-press gate (finger held still ~0.3s) means a plain swipe
/// still scrolls the strip, while a held-then-moved finger belongs
/// to the chip: it visibly lifts (offset + scale + shadow) and
/// follows the finger in global coordinates. A long-press context
/// menu with 「新しいウィンドウで開く」 is kept as a fallback path
/// to the same tearOff flow. This is a gesture-based tear-off, not
/// system drag & drop.
private struct TabStripChip: View {
    @ObservedObject var tab: BrowserTab
    let isActive: Bool
    let stripFrame: CGRect
    var onSelect: () -> Void
    var onClose: () -> Void
    var onTearOff: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 4) {
                if tab.archiveSnapshot != nil {
                    ApertureIcon(size: 12)
                } else {
                    LetterAvatar(text: tab.pageTitle.isEmpty ? tab.addressText : tab.pageTitle,
                                 size: 16)
                }
                Text(chipTitle)
                    .font(.caption2.weight(isActive ? .bold : .regular))
                    .foregroundStyle(isActive ? Theme.cobalt : Theme.ink)
                    .lineLimit(1)
                if tab.isPrivate {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    // Visual glyph stays tiny; the hit frame is wider
                    // than the glyph (36pt) while matching the compact
                    // strip height (32pt).
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .frame(width: 180, height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Theme.paper : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isActive ? Theme.cobalt : Theme.hairline,
                              lineWidth: isActive ? 1.5 : 0.5)
        )
        .offset(dragOffset)
        .scaleEffect(isDragging ? 1.05 : 1)
        .opacity(isDragging ? 0.92 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.3 : 0),
                radius: 8, x: 0, y: 4)
        .zIndex(isDragging ? 10 : 0)
        .gesture(tearOffGesture)
        .contextMenu {
            Button {
                onTearOff()
            } label: {
                Label("新しいウィンドウで開く", systemImage: "macwindow.badge.plus")
            }
            .disabled(!canTearOff)
        }
    }

    private var chipTitle: String {
        if tab.showsStartPage { return "新しいタブ" }
        if !tab.pageTitle.isEmpty { return tab.pageTitle }
        if !tab.addressText.isEmpty { return tab.addressText }
        return "新しいタブ"
    }

    private var canTearOff: Bool {
        tab.archiveSnapshot != nil || tab.currentURLString != nil
    }

    /// Long-press (≈0.3s, finger held still) sequenced into a drag.
    /// The hold is what separates tear-off from strip scrolling: a
    /// moving finger scrolls the ScrollView as before, a held finger
    /// "picks up" the chip. The drag is tracked in global coordinates
    /// so the release test can compare against the strip's global
    /// frame. Release counts as "out" only when the pointer is at
    /// least 40pt beyond the strip frame in some direction (usually
    /// downward into the page) — anything closer snaps back.
    private var tearOffGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0,
                                            coordinateSpace: .global))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    isDragging = true
                    dragOffset = drag.translation
                }
            }
            .onEnded { value in
                let releasedOutside: Bool = {
                    guard case .second(true, let drag?) = value,
                          canTearOff, stripFrame != .zero else { return false }
                    return !stripFrame.insetBy(dx: -40, dy: -40)
                        .contains(drag.location)
                }()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    dragOffset = .zero
                    isDragging = false
                }
                if releasedOutside { onTearOff() }
            }
    }
}
