import SwiftUI

struct ContentView: View {
    @StateObject private var manager = BrowserModel()
    @StateObject private var store = SnapshotStore()
    @State private var sheet: SheetKind?
    @State private var showingTabs = false
    @State private var showingBookmarkAdded = false

    private enum SheetKind: String, Identifiable {
        case library, bookmarks, history
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
            onAddBookmark: { addCurrentPageBookmark() }
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
            }
        }
        .alert("ブックマークに追加しました", isPresented: $showingBookmarkAdded) {
            Button("OK", role: .cancel) {}
        }
        .onAppear {
            store.reload()
            manager.resolvePendingArchives(using: store)
        }
    }

    private func addCurrentPageBookmark() {
        let tab = manager.activeTab
        guard !tab.showsStartPage, let url = tab.currentURLString else { return }
        if manager.bookmarks.addBookmark(title: tab.pageTitle, url: url, folderID: nil) {
            showingBookmarkAdded = true
        }
    }
}

// MARK: - One tab's chrome (address bar / banner / page / toolbar)

private struct BrowserTabView: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var manager: BrowserModel
    @ObservedObject var store: SnapshotStore
    var onShowTabs: () -> Void
    var onShowLibrary: () -> Void
    var onShowBookmarks: () -> Void
    var onShowHistory: () -> Void
    var onAddBookmark: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            if let item = tab.archiveSnapshot {
                archiveBanner(item)
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
            Image(systemName: tab.archiveSnapshot != nil ? "archivebox" : "lock.fill")
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
                Button {
                    manager.newTab()
                } label: {
                    Label("新しいタブ", systemImage: "plus")
                }
                Button(action: onShowBookmarks) {
                    Label("ブックマーク", systemImage: "bookmark")
                }
                Button(action: onShowHistory) {
                    Label("履歴", systemImage: "clock.arrow.circlepath")
                }
                Button(action: onShowLibrary) {
                    Label("ライブラリ", systemImage: "books.vertical")
                }
                Divider()
                Button(action: onAddBookmark) {
                    Label("現在のページをブックマーク", systemImage: "bookmark.fill")
                }
                .disabled(tab.showsStartPage)
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
