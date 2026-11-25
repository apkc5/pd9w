import SwiftUI
import UniformTypeIdentifiers

/// Brave-style bookmarks: folder rows with counts at the root, drill-in
/// per folder, a search pill that searches across all folders, folder
/// creation, and Netscape HTML import/export via the file picker.
struct BookmarksView: View {
    @ObservedObject var store: BookmarkStore
    var currentPage: () -> (title: String, url: String)?
    var onOpen: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var notice: String?
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            Group {
                if searchText.isEmpty {
                    FolderContentsView(store: store, folderID: nil, onOpen: onOpen)
                } else {
                    searchResults
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "ブックマークを検索")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            newFolderName = ""
                            showNewFolder = true
                        } label: {
                            Label("フォルダを作成", systemImage: "folder.badge.plus")
                        }
                        Button {
                            addCurrentPage()
                        } label: {
                            Label("現在のページを追加", systemImage: "bookmark.fill")
                        }
                        Divider()
                        Button {
                            showImporter = true
                        } label: {
                            Label("読み込み (HTML)", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            showExporter = true
                        } label: {
                            Label("書き出し (HTML)", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("新しいフォルダ", isPresented: $showNewFolder) {
                TextField("フォルダ名", text: $newFolderName)
                Button("作成") {
                    store.createFolder(name: newFolderName, parentID: nil)
                }
                Button("キャンセル", role: .cancel) {}
            }
            .alert("ブックマーク", isPresented: noticeBinding) {
                Button("OK", role: .cancel) { notice = nil }
            } message: {
                Text(notice ?? "")
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.html, .text, .data]) { result in
                handleImport(result)
            }
            .fileExporter(isPresented: $showExporter,
                          document: HTMLFileDocument(text: store.exportNetscape()),
                          contentType: .html,
                          defaultFilename: "bookmarks.html") { _ in }
        }
    }

    // MARK: Search

    private var searchResults: some View {
        List {
            ForEach(store.search(searchText)) { bookmark in
                BookmarkRow(bookmark: bookmark,
                            subtitle: store.folderName(for: bookmark.folderID),
                            onOpen: onOpen,
                            onDelete: { store.deleteBookmark(bookmark) })
            }
        }
        .listStyle(.plain)
    }

    // MARK: Actions

    private var noticeBinding: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    private func addCurrentPage() {
        guard let page = currentPage() else {
            notice = "追加できるページが開かれていません"
            return
        }
        if store.addBookmark(title: page.title, url: page.url, folderID: nil) {
            notice = "「\(store.folderName(for: store.defaultFolderID))」に追加しました"
        } else {
            notice = "すでに追加されています"
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            notice = "読み込みに失敗: \(error.localizedDescription)"
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let outcome = try store.importNetscape(data: data)
                notice = "追加 \(outcome.added) 件 / 重複スキップ \(outcome.skipped) 件"
            } catch BookmarkStore.ImportError.noBookmarksFound {
                notice = "ブックマークが1件も見つかりませんでした"
            } catch {
                notice = "読み込みに失敗: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Folder contents (recursive drill-in)

struct FolderContentsView: View {
    @ObservedObject var store: BookmarkStore
    let folderID: UUID?
    var onOpen: (String) -> Void

    @State private var showNewFolder = false
    @State private var newFolderName = ""

    var body: some View {
        List {
            if !store.subfolders(of: folderID).isEmpty {
                Section {
                    ForEach(store.subfolders(of: folderID)) { folder in
                        NavigationLink {
                            FolderContentsView(store: store, folderID: folder.id, onOpen: onOpen)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder")
                                    .foregroundStyle(Theme.cobalt)
                                Text(folder.name)
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Text("(\(store.count(in: folder.id)))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                ForEach(store.bookmarks(in: folderID)) { bookmark in
                    BookmarkRow(bookmark: bookmark,
                                subtitle: nil,
                                onOpen: onOpen,
                                onDelete: { store.deleteBookmark(bookmark) })
                }
            }
            if store.subfolders(of: folderID).isEmpty && store.bookmarks(in: folderID).isEmpty {
                Text("このフォルダは空です")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .navigationTitle(folderID == nil ? "ブックマーク" : store.folderName(for: folderID))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if folderID != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newFolderName = ""
                        showNewFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
        }
        .alert("新しいフォルダ", isPresented: $showNewFolder) {
            TextField("フォルダ名", text: $newFolderName)
            Button("作成") {
                store.createFolder(name: newFolderName, parentID: folderID)
            }
            Button("キャンセル", role: .cancel) {}
        }
    }
}

// MARK: - Rows

struct BookmarkRow: View {
    let bookmark: Bookmark
    var subtitle: String?
    var onOpen: (String) -> Void
    var onDelete: () -> Void

    var body: some View {
        Button {
            onOpen(bookmark.url)
        } label: {
            HStack(spacing: 10) {
                LetterAvatar(text: bookmark.title.isEmpty ? bookmark.url : bookmark.title,
                             size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bookmark.title)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Text(subtitle ?? hostText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("削除", systemImage: "trash")
            }
        }
    }

    private var hostText: String {
        if bookmark.url.lowercased().hasPrefix("javascript:") { return "ブックマレット" }
        return URL(string: bookmark.url)?.host ?? bookmark.url
    }
}

// MARK: - Export document

struct HTMLFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.html] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
