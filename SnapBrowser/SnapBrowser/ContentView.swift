import SwiftUI
import UIKit

struct ContentView: View {
    /// Payload when this scene is a tear-off / split-view window
    /// (v0.4.13): the App's value-carrying WindowGroup hands the
    /// moved tab's payload (URL / archive folder / privacy) to the
    /// new scene's root view. nil for ordinary windows.
    var windowPayload: TabWindowPayload? = nil
    @State private var didApplyWindowPayload = false
    @StateObject private var manager = BrowserModel()
    @StateObject private var store = SnapshotStore()
    @State private var sheet: SheetKind?
    @State private var showingTabs = false
    @State private var sharePayload: SharePayload?
    @State private var showingReader = false
    @State private var showingAddBookmark = false

    private enum SheetKind: String, Identifiable {
        case library, bookmarks, history, settings, playlist, downloads
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
            onShowDownloads: { sheet = .downloads },
            onAddBookmark: { showingAddBookmark = true },
            onShare: { shareCurrentPage() },
            onReader: { showingReader = true },
            shortcutsEnabled: sheet == nil && !showingTabs && !showingReader && !showingAddBookmark
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
            case .downloads:
                DownloadsView(store: manager.downloads)
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
            manager.snapshotStore = store
            manager.resolvePendingArchives(using: store)
            wire(manager.activeTab)
            applyWindowPayloadIfNeeded()
        }
        .onChange(of: manager.activeTabID) { _ in
            wire(manager.activeTab)
        }
    }

    /// Receiving end of tear-off / split view (v0.4.13): a scene
    /// created for a moved tab carries the tab's payload — URL, or
    /// archive folder, plus the privacy flag — and opens it as a
    /// tab in this scene. The privacy flag has ridden along since
    /// v0.4.12: a private tab torn off (or fanned out by split
    /// view) reopens as a PRIVATE tab here — before that, the flag
    /// was dropped and the URL landed in a normal, history-recorded
    /// tab. A payload with neither URL nor folder is a start-page
    /// tab (a moved blank tab, or a split-view filler slot): open
    /// a fresh tab of the requested kind so the window count still
    /// matches. Applied at most once per scene; ordinary windows
    /// carry no payload and skip this entirely.
    private func applyWindowPayloadIfNeeded() {
        guard let payload = windowPayload, !didApplyWindowPayload else { return }
        didApplyWindowPayload = true
        if let folder = payload.archiveFolder {
            store.reload()
            if let item = store.items.first(where: { $0.folderName == folder }) {
                manager.openArchive(item: item, store: store, isPrivate: payload.isPrivate)
                return
            }
            // The snapshot vanished between send and receive; fall
            // through to a fresh tab rather than an empty window.
            openFreshTab(isPrivate: payload.isPrivate)
        } else if let urlString = payload.url,
                  let url = URL(string: urlString) {
            _ = manager.newTab(url: url, isPrivate: payload.isPrivate)
        } else {
            openFreshTab(isPrivate: payload.isPrivate)
        }
    }

    private func openFreshTab(isPrivate: Bool) {
        if isPrivate {
            _ = manager.newPrivateTab()
        } else {
            _ = manager.newTab()
        }
    }

    private var currentPageForBookmark: (title: String, url: String)? {
        let tab = manager.activeTab
        guard !tab.showsStartPage, let url = tab.currentURLString else { return nil }
        return (tab.pageTitle, url)
    }

    /// Connects the active tab's context-menu callbacks (v0.4.9) to
    /// this scene's UI: share sheet, SNAP (needs the snapshot store),
    /// and Playlist adds for media links.
    private func wire(_ tab: BrowserTab) {
        tab.shareHandler = { items in
            sharePayload = SharePayload(items: items)
        }
        tab.snapHandler = { [weak tab] in
            tab?.snap(store: store)
        }
        tab.playlistLinkHandler = { url in
            manager.playlist.add(title: "", url: url, pageURL: nil)
        }
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
    var onShowDownloads: () -> Void
    var onAddBookmark: () -> Void
    var onShare: () -> Void
    var onReader: () -> Void
    /// Keyboard shortcuts (v0.4.9) are live only while no sheet or
    /// cover is up, so they can never fire into another screen's
    /// text fields.
    var shortcutsEnabled: Bool = true

    /// SwiftUI's window opener (v0.4.13): tear-off and split view
    /// open their windows through TabWindows with this action.
    @Environment(\.openWindow) private var openWindow
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
    /// Strip chip frames in the strip content's coordinate space
    /// (v0.4.11), reported by each chip as it is laid out — the
    /// drag-reorder maths works from the snapshot taken when a
    /// drag starts, so mid-drag layout changes can't skew it.
    @State private var stripChipFrames: [UUID: CGRect] = [:]
    /// Strip drag-reorder state (v0.4.11): which chip is being
    /// dragged, the slot it started in, and the slot it would land
    /// in if released now. The model is NOT moved during the drag;
    /// the other chips shift sideways to open the gap (see
    /// stripReorderShift) and the move commits on release.
    @State private var stripDragID: UUID?
    @State private var stripDragStartIndex = 0
    @State private var stripDragTargetIndex = 0
    @State private var stripDragStartFrames: [UUID: CGRect] = [:]
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
            tabStrip(chipWidth: geo.size.width >= 700
                        ? 180
                        : max(104, min(160, geo.size.width * 0.45)))
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
                                  history: manager.history,
                                  settings: settings,
                                  onShowBookmarks: onShowBookmarks)
                }
                if let message = tab.loadError, !tab.showsStartPage {
                    loadErrorCard(message)
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
        // Keyboard (v0.4.7): the browser chrome must never be
        // pushed up or shrunk by the keyboard's safe area. With a
        // floating keyboard the whole layout used to jump the
        // moment the keyboard opened, reflowing the page behind
        // it. Ignoring the keyboard safe area on the browser
        // screen's root keeps the address bar, tab strip and
        // WebView at exactly the same position and size whether
        // the keyboard is up or down; the suggestion panel stays
        // an overlay (it may overlap the keyboard) and its height
        // cap keeps using the full window height. Sheets with
        // their own text fields are separate presentations and
        // keep the standard avoidance.
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
        // JavaScript panels (v0.4.9): alert / confirm as a native
        // alert; prompt gets its own sheet with a text field below.
        .alert("ページからのメッセージ", isPresented: jsAlertBinding) {
            if let panel = tab.jsPanel {
                if panel.kind == .confirm {
                    Button("OK") {
                        panel.respondConfirm(true)
                        tab.jsPanel = nil
                    }
                    Button("キャンセル", role: .cancel) {
                        panel.respondConfirm(false)
                        tab.jsPanel = nil
                    }
                } else {
                    Button("OK", role: .cancel) {
                        panel.respondAlert()
                        tab.jsPanel = nil
                    }
                }
            }
        } message: {
            Text(tab.jsPanel?.message ?? "")
        }
        .sheet(item: promptPanelBinding) { panel in
            PromptSheet(message: panel.message, initialText: panel.defaultText) { value in
                panel.respondPrompt(value)
                tab.jsPanel = nil
            }
        }
        .sheet(item: $tab.authRequest) { request in
            AuthSheet(request: request) {
                tab.authRequest = nil
            }
        }
        .onChange(of: tab.tabNotice) { notice in
            if let notice {
                showToast(notice)
                tab.tabNotice = nil
            }
        }
        // Download start / completion / failure (v0.4.10): a
        // download is no longer silent — the toast says what
        // happened, and the file is in ⋯ → ダウンロード.
        .onChange(of: manager.downloadNotice) { notice in
            if let notice {
                showToast(notice)
                manager.downloadNotice = nil
            }
        }
        // Window-opening failures (v0.4.13): a tear-off / split
        // request that verifiably produced no window speaks up
        // here instead of failing silently like the old route.
        .onChange(of: manager.windowNotice) { notice in
            if let notice {
                showToast(notice)
                manager.windowNotice = nil
            }
        }
        .onChange(of: manager.addressFocusRequest) { _ in
            addressFocused = true
        }
        .background {
            if shortcutsEnabled {
                keyboardShortcuts
            }
        }
    }

    // MARK: Load error card (v0.4.9)

    /// Shown over the page area when a main-frame load fails, with
    /// the error's own message and a reload button — the page never
    /// just goes blank any more.
    private func loadErrorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("ページを読み込めませんでした")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                tab.loadError = nil
                tab.reload()
            } label: {
                Text("再読み込み")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .background(Capsule().fill(Theme.cobalt))
                    .contentShape(Capsule())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }

    // MARK: JS panel / auth presentation (v0.4.9)

    private var jsAlertBinding: Binding<Bool> {
        Binding(
            get: { tab.jsPanel != nil && tab.jsPanel?.kind != .prompt },
            set: { presented in
                if !presented, let panel = tab.jsPanel {
                    // Dismissed without a button (should not happen
                    // for alerts, but never leave WebKit hanging).
                    switch panel.kind {
                    case .alert: panel.respondAlert()
                    case .confirm: panel.respondConfirm(false)
                    case .prompt: break
                    }
                    tab.jsPanel = nil
                }
            })
    }

    private var promptPanelBinding: Binding<JSPanelRequest?> {
        Binding(
            get: { tab.jsPanel?.kind == .prompt ? tab.jsPanel : nil },
            set: { tab.jsPanel = $0 })
    }

    // MARK: Hardware keyboard shortcuts (v0.4.9, iPad)
    //
    // Zero-size invisible buttons carrying the shortcuts — the
    // standard SwiftUI way to bind keys without a menu. The layer
    // exists only while `shortcutsEnabled` (no sheet/cover up), so
    // keys typed into other screens' fields never trigger browser
    // actions. The address bar itself is a text field, but browsers
    // treat these keys as commands there too, and so do we.

    private var keyboardShortcuts: some View {
        Group {
            Button("新規タブ") { manager.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("タブを閉じる") { manager.closeTab(tab) }
                .keyboardShortcut("w", modifiers: .command)
            Button("アドレスバー") { addressFocused = true }
                .keyboardShortcut("l", modifiers: .command)
            Button("再読み込み") { tab.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Button("ページ内検索") { findActive = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("ブックマークに追加") { onAddBookmark() }
                .keyboardShortcut("d", modifiers: .command)
            Button("閉じたタブを開く") { manager.restoreClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("戻る") { tab.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("進む") { tab.goForward() }
                .keyboardShortcut("]", modifiers: .command)
            Button("次のタブ") { manager.selectNextTab() }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("前のタブ") { manager.selectPreviousTab() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("タブ一覧") { onShowTabs() }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
        // Leading inset (v0.4.11): the iPadOS window buttons
        // (traffic lights) overlay the window's top-left corner and
        // used to sit ON the pill — over its icon and text — in
        // floating windows. The pill now starts to the right of the
        // button cluster at every window size, the way Brave's iPad
        // toolbar reserves that space: one layout, never a collision.
        .padding(.leading, 72)
        .padding(.trailing, 12)
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
                            devicePanelRow(match)
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

    /// A device-match row with its own × at the right end (v0.4.8).
    /// The × and the row body are sibling buttons — never nested —
    /// so a tap on × can only hide, never navigate. Hiding is
    /// panel-only: the URL is recorded in
    /// `settings.hiddenSuggestionURLs` and the row disappears at
    /// once (the settings change re-renders the panel); the history
    /// and bookmark stores are left completely untouched, so the
    /// entry remains visible in its own screen.
    private func devicePanelRow(_ match: PanelMatch) -> some View {
        HStack(spacing: 0) {
            Button {
                addressFocused = false
                manager.openInActiveTab(match.url)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: match.isBookmark ? "bookmark.fill" : "clock.arrow.circlepath")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(match.title)
                            .font(.body)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text(match.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                settings.hideSuggestionURL(match.url)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("この候補を隠す")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(minHeight: 44)
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
    /// simply the most recent history, like Brave's panel. URLs the
    /// user hid with a row's × (v0.4.8) are filtered out here — the
    /// underlying history / bookmark entries are never deleted.
    private var deviceMatches: [PanelMatch] {
        let query = panelQuery
        if query.isEmpty {
            return manager.history.items
                .filter { !settings.isSuggestionHidden($0.url) }
                .prefix(8).map {
                    PanelMatch(id: "h-\($0.id.uuidString)",
                               title: $0.title, url: $0.url, isBookmark: false)
                }
        }
        var results: [PanelMatch] = []
        var seen = Set<String>()
        for bookmark in manager.bookmarks.search(query)
        where !settings.isSuggestionHidden(bookmark.url) {
            results.append(PanelMatch(id: "b-\(bookmark.id.uuidString)",
                                      title: bookmark.title, url: bookmark.url,
                                      isBookmark: true))
            seen.insert(bookmark.url)
        }
        for item in manager.history.search(query)
        where !seen.contains(item.url) && !settings.isSuggestionHidden(item.url) {
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

    // MARK: Tab strip (always visible, Brave-style tab bar)

    /// Flush strip directly under the address bar, ALWAYS visible
    /// (v0.4.11 — the ≥700pt gate is gone): like Brave on iPad, the
    /// strip survives even the smallest floating window, the chips
    /// just get narrower and scroll sideways, and the active chip is
    /// kept scrolled into view. Even a single tab keeps its chip.
    /// Order in the column: address bar → tab strip → archive/private
    /// banner → progress → page, so the banners never fight the strip.
    private func tabStrip(chipWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(manager.tabs.enumerated()), id: \.element.id) { index, t in
                            TabStripChip(tab: t,
                                         isActive: t.id == manager.activeTabID,
                                         stripFrame: stripFrame,
                                         chipWidth: chipWidth,
                                         reorderShift: stripReorderShift(for: index, chipWidth: chipWidth),
                                         onSelect: { manager.selectTab(t) },
                                         onClose: { manager.closeTab(t) },
                                         onTearOff: { tearOff(t) },
                                         onReportFrame: { stripChipFrames[t.id] = $0 },
                                         onDragChanged: { tab, translation, location in
                                             stripDragChanged(tab: tab, translation: translation, location: location)
                                         },
                                         onDragEnded: { tab, releasedOutside in
                                             stripDragEnded(tab: tab, releasedOutside: releasedOutside)
                                         },
                                         onDragCancelled: { stripDragReset() })
                                .id(t.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .coordinateSpace(name: "tabStripContent")
                }
                .onAppear {
                    proxy.scrollTo(manager.activeTabID, anchor: .center)
                }
                .onChange(of: manager.activeTabID) { _, id in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
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
        .onDisappear { stripDragReset() }
    }

    // MARK: Strip drag-reorder (v0.4.11)

    /// How far the chip at `index` slides sideways to open the gap
    /// while another chip is being drag-reordered: chips between the
    /// dragged chip's start slot and its current target slot shift
    /// by exactly one chip step toward the start slot, so the hole
    /// the dragged chip will land in is always visible. The dragged
    /// chip itself never gets a shift — it follows the finger.
    private func stripReorderShift(for index: Int, chipWidth: CGFloat) -> CGFloat {
        guard stripDragID != nil, index != stripDragStartIndex else { return 0 }
        let step = chipWidth + 5
        if stripDragStartIndex < stripDragTargetIndex,
           index > stripDragStartIndex, index <= stripDragTargetIndex {
            return -step
        }
        if stripDragTargetIndex < stripDragStartIndex,
           index < stripDragStartIndex, index >= stripDragTargetIndex {
            return step
        }
        return 0
    }

    /// Feeds the dragged chip's gesture into the reorder state. The
    /// first call of a drag snapshots the chips' frames; later calls
    /// only recompute the landing slot from the dragged chip's
    /// centre (start-frame centre + finger translation, which is the
    /// same vector in the content space as in the gesture's global
    /// space). The landing slot is the count of other chips whose
    /// start centres the dragged centre has crossed — with
    /// moveTab's remove-and-insert semantics that is exactly the
    /// index the dragged tab ends up at. Reordering is computed
    /// only while the pointer stays inside the strip's tear-off
    /// band (±40pt): outside it the gesture is a tear-off, and the
    /// order must not churn under a chip that is leaving.
    private func stripDragChanged(tab: BrowserTab, translation: CGSize, location: CGPoint) {
        if stripDragID == nil {
            guard let index = manager.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            stripDragID = tab.id
            stripDragStartIndex = index
            stripDragTargetIndex = index
            stripDragStartFrames = stripChipFrames
        }
        guard stripDragID == tab.id,
              let startFrame = stripDragStartFrames[tab.id] else { return }
        if stripFrame != .zero,
           !stripFrame.insetBy(dx: -40, dy: -40).contains(location) { return }
        let centerX = startFrame.midX + translation.width
        var target = 0
        for other in manager.tabs where other.id != tab.id {
            if let frame = stripDragStartFrames[other.id], frame.midX < centerX {
                target += 1
            }
        }
        if target != stripDragTargetIndex {
            withAnimation(.easeInOut(duration: 0.18)) {
                stripDragTargetIndex = target
            }
        }
    }

    /// Release inside the strip: commit the move. Release outside
    /// is the tear-off path — the chip fires onTearOff itself, and
    /// a torn-off tab must not also reorder. Either way the drag
    /// state resets in the same animation, so the shifted chips
    /// settle into the final layout instead of snapping.
    private func stripDragEnded(tab: BrowserTab, releasedOutside: Bool) {
        let shouldCommit = !releasedOutside
            && stripDragID == tab.id
            && stripDragTargetIndex != stripDragStartIndex
        let from = stripDragStartIndex
        let to = stripDragTargetIndex
        withAnimation(.easeInOut(duration: 0.18)) {
            if shouldCommit {
                manager.moveTab(fromIndex: from, toIndex: to)
            }
            stripDragReset()
        }
    }

    private func stripDragReset() {
        stripDragID = nil
        stripDragStartFrames = [:]
        stripDragTargetIndex = stripDragStartIndex
    }

    /// Tear-off: open a NEW window carrying this tab (move, not
    /// copy). The shared implementation lives in TabWindows so
    /// split view moves tabs exactly the same way.
    private func tearOff(_ tab: BrowserTab) {
        TabWindows.moveToNewWindow(tab, manager: manager, openWindow: openWindow)
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
                    Button {
                        manager.restoreClosedTab()
                    } label: {
                        Label("閉じたタブを開く", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(manager.closedTabs.isEmpty)
                    // One-tap split view (v0.4.12): fan this tab's
                    // tray out into separate windows — see
                    // TabWindows.splitWindows. The submenu's two
                    // rows are the 2/3 choice.
                    Menu {
                        Button {
                            TabWindows.splitWindows(count: 2, isPrivate: tab.isPrivate, manager: manager, openWindow: openWindow)
                        } label: {
                            Label("2分割", systemImage: "rectangle.split.2x1")
                        }
                        Button {
                            TabWindows.splitWindows(count: 3, isPrivate: tab.isPrivate, manager: manager, openWindow: openWindow)
                        } label: {
                            Label("3分割", systemImage: "rectangle.split.3x1")
                        }
                    } label: {
                        Label("タブを分割表示", systemImage: "rectangle.split.2x1")
                    }
                }
                Section {
                    Button(action: onShare) {
                        Label("共有…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(tab.showsStartPage)
                    // Shown only while the tab displays a document
                    // inline (a PDF link opens in the viewer instead
                    // of downloading — v0.4.10 gives it a save path).
                    if tab.currentDocumentName != nil {
                        Button {
                            tab.downloadCurrentDocument()
                        } label: {
                            Label("このファイルをダウンロード", systemImage: "arrow.down.doc")
                        }
                    }
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
                    Button(action: onShowDownloads) {
                        Label("ダウンロード", systemImage: "arrow.down.circle")
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
            "自己完結HTML: \(fmt(result.fullHTMLBytes))" + (result.assetsInlined.map { " (リソース \($0) 件を取り込み)" } ?? ""),
            "テキスト: \(result.textChars.map { "\($0)文字" } ?? "失敗")"
        ]
        if !result.failures.isEmpty {
            lines.append("—")
            lines.append(contentsOf: result.failures)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Tab windows (tear-off & split view)

/// The value a tear-off / split-view window is opened with
/// (v0.4.13): the tab's archive folder, else its URL, else
/// neither (a start-page tab). The privacy flag always rides
/// along so the receiving scene rebuilds the tab in the same
/// class — a private tab moved into a new window must never come
/// back as a normal, history-recorded tab (that was a real bug
/// up to v0.4.11, fixed in v0.4.12).
struct TabWindowPayload: Codable, Hashable {
    var url: String? = nil
    var archiveFolder: String? = nil
    var isPrivate: Bool = false
}

/// Opening tabs in NEW windows: tear-off (drag a strip chip out
/// of the strip, its long-press menu, or drop a tab-overview card
/// on the drop zone) and one-tap split view all go through here.
///
/// v0.4.13 rewrote the mechanism. Up to v0.4.12 this used
/// UIApplication.requestSceneSessionActivation with an
/// NSUserActivity of type jp.anko.snapbrowser.openTab — a type
/// that was NEVER declared in the app's Info.plist
/// NSUserActivityTypes (the key is absent from the shipped
/// v0.4.12 IPA; verified by dumping its plist). The system
/// rejected every activation request, and the only failure
/// signal — the API's error handler — was swallowed: the filler
/// spawner ignored it outright, and tear-off used it only to
/// suppress the source tab's close. On device the buttons
/// therefore did literally nothing: no window, no close, no
/// message (BUILD_LOG 第22次）. The route now is SwiftUI's
/// openWindow into the value-carrying WindowGroup declared in
/// SnapBrowserApp — no plist declaration to miss, and the
/// payload is typed instead of a userInfo dictionary.
///
/// openWindow has no error channel either, so success is
/// VERIFIED instead of assumed: a request counts as successful
/// only once the app's scene-session count has actually grown.
/// A moved tab closes only after its window exists, and any
/// shortfall is surfaced through BrowserModel.windowNotice
/// (BrowserTabView's toast) — a window request must never fail
/// silently again. NOTE: no public API lets an app propose a
/// window frame on iPadOS, so the windows open wherever the
/// system puts them; the final snap into a tile stays an OS
/// gesture (unchanged from v0.4.12).
enum TabWindows {
    static let windowGroupID = "tab-window"

    /// The payload that carries one tab into a new scene: its
    /// archive folder, else its URL, else nothing (a start-page
    /// tab reopens as a start page). @MainActor because
    /// BrowserTab's state is main-actor isolated.
    @MainActor
    static func payload(for tab: BrowserTab) -> TabWindowPayload {
        var payload = TabWindowPayload(isPrivate: tab.isPrivate)
        if let item = tab.archiveSnapshot {
            payload.archiveFolder = item.folderName
        } else if let urlString = tab.currentURLString {
            payload.url = urlString
        }
        return payload
    }

    private static var sceneSessionCount: Int {
        UIApplication.shared.openSessions.count
    }

    /// Tear-off proper: open a new window carrying this tab, and
    /// close the original (move, not copy) once the new scene
    /// session verifiably exists. If no session appears within
    /// the grace period, the tab stays where it is and the user
    /// gets a notice — never a silent nothing.
    @MainActor
    static func moveToNewWindow(_ tab: BrowserTab, manager: BrowserModel,
                                openWindow: OpenWindowAction) {
        let baseline = sceneSessionCount
        openWindow(id: windowGroupID, value: payload(for: tab))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if sceneSessionCount > baseline {
                manager.closeTab(tab)
            } else {
                manager.windowNotice = "新しいウィンドウを開けませんでした"
            }
        }
    }

    /// One-tap split view: fan one tray's tabs out into separate
    /// windows so the user can tile them 2- or 3-across. This
    /// window keeps the tray's active tab (or its first tab, when
    /// the active tab belongs to the other tray); the tabs AFTER
    /// it, in tray order, move — one per new window — and any
    /// slots still unfilled get fresh start-page windows of the
    /// same class. Splitting never crosses the privacy line: the
    /// private tray only ever spawns private windows. Requests
    /// are staggered so the system takes them one at a time, and
    /// one verification pass at the end closes as many moved
    /// tabs as windows actually appeared (requests were fired in
    /// order) and reports any shortfall by toast.
    @MainActor
    static func splitWindows(count: Int, isPrivate: Bool, manager: BrowserModel,
                             openWindow: OpenWindowAction) {
        let tray = manager.tabs.filter { $0.isPrivate == isPrivate }
        guard count >= 2, !tray.isEmpty else { return }
        let keep = manager.activeTab.isPrivate == isPrivate
            ? manager.activeTab
            : tray[0]
        guard let keepIndex = tray.firstIndex(where: { $0.id == keep.id })
        else { return }
        let followers = Array(tray.dropFirst(keepIndex + 1))
        let slots = count - 1
        let baseline = sceneSessionCount
        for slot in 0..<slots {
            let delay = UInt64(slot) * 250_000_000
            let payload: TabWindowPayload
            if slot < followers.count {
                payload = self.payload(for: followers[slot])
            } else {
                payload = TabWindowPayload(isPrivate: isPrivate)
            }
            Task { @MainActor in
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                openWindow(id: windowGroupID, value: payload)
            }
        }
        Task { @MainActor in
            let wait = UInt64(slots - 1) * 250_000_000 + 1_500_000_000
            try? await Task.sleep(nanoseconds: wait)
            let gained = sceneSessionCount - baseline
            let moved = followers.prefix(min(max(gained, 0), followers.count))
            for tab in moved { manager.closeTab(tab) }
            if gained < slots {
                manager.windowNotice = gained <= 0
                    ? "分割できませんでした（ウィンドウが開きませんでした）"
                    : "分割が一部失敗しました（\(gained)/\(slots) ウィンドウ）"
            }
        }
    }
}

/// One chip in the tab strip: letter tile / aperture + title + ×.
/// The main area selects the tab (tap), the × closes it, and a
/// LONG-PRESS-initiated drag does two jobs (v0.4.11): dragged
/// SIDEWAYS inside the strip it reorders the tabs — the parent
/// shifts the other chips to open the gap and commits the move on
/// release (see BrowserTabView.stripDragChanged) — while a drag
/// that ends well OUTSIDE the strip's frame tears the tab off into
/// a new window (see BrowserTabView.tearOff). Horizontal = reorder,
/// out = tear-off; the two never compete because the reorder maths
/// only runs while the pointer is inside the strip's band.
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
    /// Chip width for the current window size (v0.4.11): 180pt in
    /// wide windows, narrower in small floating windows so titles
    /// stay partly readable instead of the strip vanishing.
    let chipWidth: CGFloat
    /// Sideways shift that opens the landing gap while ANOTHER chip
    /// is being drag-reordered (0 for the dragged chip itself and
    /// whenever no reorder is in flight).
    var reorderShift: CGFloat
    var onSelect: () -> Void
    var onClose: () -> Void
    var onTearOff: () -> Void
    /// Reports this chip's layout frame in the strip content's
    /// coordinate space (the reorder maths' raw material). Offsets
    /// do not affect layout frames, so reports stay slot-true even
    /// mid-drag.
    var onReportFrame: (CGRect) -> Void
    /// Drag lifecycle for the parent's reorder state.
    var onDragChanged: (BrowserTab, CGSize, CGPoint) -> Void
    var onDragEnded: (BrowserTab, Bool) -> Void
    var onDragCancelled: () -> Void

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
        .frame(width: chipWidth, height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Theme.paper : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isActive ? Theme.cobalt : Theme.hairline,
                              lineWidth: isActive ? 1.5 : 0.5)
        )
        .offset(x: dragOffset.width + reorderShift, y: dragOffset.height)
        .scaleEffect(isDragging ? 1.05 : 1)
        .opacity(isDragging ? 0.92 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.3 : 0),
                radius: 8, x: 0, y: 4)
        .zIndex(isDragging ? 10 : 0)
        .gesture(tearOffGesture)
        // Drag-state hygiene (v0.4.10): the offset/scale/zIndex above
        // were previously reset ONLY in the gesture's onEnded. When
        // the sequenced gesture is CANCELLED instead — the strip's
        // ScrollView reclaiming the touch, the chip being rebuilt
        // mid-drag — onEnded never runs, and the chip kept its last
        // dragOffset at zIndex 10 indefinitely: rendered shifted on
        // top of its neighbours with its × floating over the next
        // chip (the user's screenshot). Disappearing — and
        // (re)appearing — always starts from a clean drag state.
        .onDisappear {
            dragOffset = .zero
            isDragging = false
            onDragCancelled()
        }
        .onAppear {
            dragOffset = .zero
            isDragging = false
        }
        // Frame reporting for the reorder maths (v0.4.11): the
        // layout frame in the strip content's coordinate space,
        // re-reported whenever layout moves this chip. A cancelled
        // drag also surfaces here as a disappearance, which is how
        // the parent's reorder state gets its cancel signal above.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        onReportFrame(proxy.frame(in: .named("tabStripContent")))
                    }
                    .onChange(of: proxy.frame(in: .named("tabStripContent"))) { _, frame in
                        onReportFrame(frame)
                    }
            }
        }
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
                    onDragChanged(tab, drag.translation, drag.location)
                }
            }
            .onEnded { value in
                let releasedOutside: Bool = {
                    guard case .second(true, let drag?) = value,
                          canTearOff, stripFrame != .zero else { return false }
                    return !stripFrame.insetBy(dx: -40, dy: -40)
                        .contains(drag.location)
                }()
                // The parent's reorder commit runs first, while its
                // drag state is still intact; a release outside the
                // strip tells it not to commit (tear-off instead).
                onDragEnded(tab, releasedOutside)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    dragOffset = .zero
                    isDragging = false
                }
                if releasedOutside { onTearOff() }
            }
    }
}

// MARK: - JavaScript prompt sheet (v0.4.9)

/// The text-input panel for JS prompt(): message, one text field
/// pre-filled with the page's default, OK returns the text and
/// キャンセル returns nil — the exact semantics WebKit expects.
private struct PromptSheet: View {
    let message: String
    let initialText: String
    var onDone: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("入力", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .onSubmit { finish(text) }
                } header: {
                    Text(message.isEmpty ? "ページからの入力要求" : message)
                }
            }
            .navigationTitle("入力")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { finish(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { finish(text) }
                }
            }
            .onAppear {
                text = initialText
                fieldFocused = true
            }
        }
    }

    private func finish(_ value: String?) {
        dismiss()
        onDone(value)
    }
}

// MARK: - HTTP authentication sheet (v0.4.9)

/// Credential dialog for Basic/Digest challenges. The password is
/// handed straight to WebKit's credential (session persistence) and
/// is never stored by the app — no Keychain, no files.
private struct AuthSheet: View {
    let request: AuthRequest
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ユーザー名", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("パスワード", text: $password)
                } header: {
                    Text("\(request.host) がサインインを求めています")
                } footer: {
                    if let realm = request.realm, !realm.isEmpty {
                        Text(realm)
                    }
                }
            }
            .navigationTitle("認証")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        request.cancel()
                        dismiss()
                        onDone()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("サインイン") {
                        request.respond(user: user, password: password)
                        dismiss()
                        onDone()
                    }
                    .disabled(user.isEmpty)
                }
            }
        }
    }
}
