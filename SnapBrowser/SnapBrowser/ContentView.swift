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
        case library, bookmarks, history, settings
        var id: String { rawValue }
    }

    var body: some View {
        BrowserTabView(
            tab: manager.activeTab,
            manager: manager,
            store: store,
            onShowTabs: {
                manager.captureAllPreviews()
                showingTabs = true
            },
            onShowLibrary: { sheet = .library },
            onShowBookmarks: { sheet = .bookmarks },
            onShowHistory: { sheet = .history },
            onShowSettings: { sheet = .settings },
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
                    })
            case .history:
                HistoryView(store: manager.history,
                            onOpen: { url in
                                manager.openInActiveTab(url)
                                sheet = nil
                            })
            case .settings:
                SettingsView(manager: manager, settings: manager.settings)
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
    var onShowTabs: () -> Void
    var onShowLibrary: () -> Void
    var onShowBookmarks: () -> Void
    var onShowHistory: () -> Void
    var onShowSettings: () -> Void
    var onAddBookmark: () -> Void
    var onShare: () -> Void
    var onReader: () -> Void

    @State private var findActive = false
    @State private var findQuery = ""
    @State private var findCount: Int?
    @State private var findMiss = false
    @State private var stripFrame: CGRect = .zero

    var body: some View {
        GeometryReader { geo in
        VStack(spacing: 0) {
            addressBar
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
        }
        .background(Theme.paper)
        .alert("スナップ結果", isPresented: snapAlertBinding) {
            Button("OK", role: .cancel) { tab.lastSnapResult = nil }
        } message: {
            if let result = tab.lastSnapResult {
                Text(snapMessage(result))
            }
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
                .onSubmit { tab.loadAddressBar() }
            if tab.isLoading {
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
