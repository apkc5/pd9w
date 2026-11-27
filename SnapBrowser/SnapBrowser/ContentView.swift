import SwiftUI

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

    var body: some View {
        VStack(spacing: 0) {
            addressBar
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
                }
            } else if !tab.showsStartPage {
                Button { tab.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Theme.ink)
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
            }
            Button { runFind(backwards: false) } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(Theme.ink)
            }
            Button("完了") {
                findActive = false
                findQuery = ""
                findCount = nil
                findMiss = false
            }
            .foregroundStyle(Theme.cobalt)
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
            }
            .disabled(!tab.canGoBack)

            Spacer()

            Button { tab.goForward() } label: {
                Image(systemName: "chevron.forward")
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
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
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
