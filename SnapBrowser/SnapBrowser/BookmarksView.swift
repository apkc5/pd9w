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
    @State private var editingBookmark: Bookmark?

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
                            onDelete: { store.deleteBookmark(bookmark) },
                            onEdit: { editingBookmark = bookmark })
            }
        }
        .listStyle(.plain)
        .sheet(item: $editingBookmark) { bookmark in
            EditBookmarkView(store: store, bookmark: bookmark)
        }
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
    @State private var editingBookmark: Bookmark?

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
                                onDelete: { store.deleteBookmark(bookmark) },
                                onEdit: { editingBookmark = bookmark })
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
        .sheet(item: $editingBookmark) { bookmark in
            EditBookmarkView(store: store, bookmark: bookmark)
        }
    }
}

// MARK: - Rows

struct BookmarkRow: View {
    let bookmark: Bookmark
    var subtitle: String?
    var onOpen: (String) -> Void
    var onDelete: () -> Void
    var onEdit: () -> Void

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
            Button(action: onEdit) {
                Label("編集", systemImage: "pencil")
            }
            .tint(Theme.cobalt)
        }
        .contextMenu {
            Button(action: onEdit) {
                Label("編集", systemImage: "pencil")
            }
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

// MARK: - Add bookmark (folder picker, v0.4)

/// Add-bookmark sheet opened from the browser menu: editable title and
/// a folder picker over the whole folder tree (indented by depth).
struct AddBookmarkView: View {
    @ObservedObject var store: BookmarkStore
    let url: String
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var selectedFolderID: UUID?
    @State private var duplicate = false

    init(store: BookmarkStore, initialTitle: String, url: String) {
        self.store = store
        self.url = url
        _title = State(initialValue: initialTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("ページ") {
                    TextField("タイトル", text: $title)
                    Text(url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Section("保存先フォルダ") {
                    ForEach(flatFolders, id: \.folder.id) { entry in
                        Button {
                            selectedFolderID = entry.folder.id
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(Theme.cobalt)
                                Text(entry.folder.name)
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                if selectedFolderID == entry.folder.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.cobalt)
                                }
                            }
                            .padding(.leading, CGFloat(entry.depth) * 16)
                        }
                    }
                }
                if duplicate {
                    Section {
                        Text("このページはすでにブックマークされています")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("ブックマークに追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear {
                if selectedFolderID == nil {
                    selectedFolderID = store.defaultFolderID
                }
            }
        }
    }

    private struct FlatFolder {
        let folder: BookmarkFolder
        let depth: Int
    }

    private var flatFolders: [FlatFolder] {
        var out: [FlatFolder] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for folder in store.subfolders(of: parent) {
                out.append(FlatFolder(folder: folder, depth: depth))
                walk(folder.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    private func save() {
        if store.addBookmark(title: title, url: url, folderID: selectedFolderID) {
            dismiss()
        } else {
            duplicate = true
        }
    }
}

// MARK: - Edit bookmark (v0.4.2)

/// Edit sheet for an existing bookmark: name, URL and destination
/// folder. Reached from the row's 編集 swipe action or long-press menu.
/// Saving updates the bookmark in place — id and ADD_DATE are kept.
/// If the edited URL already belongs to another bookmark, the save is
/// refused with a plain inline notice (same dedupe convention as the
/// add flow: never silently merge); the user can fix the URL or cancel.
struct EditBookmarkView: View {
    @ObservedObject var store: BookmarkStore
    let bookmark: Bookmark
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var urlText: String
    @State private var selectedFolderID: UUID?
    @State private var conflictTitle: String?

    init(store: BookmarkStore, bookmark: Bookmark) {
        self.store = store
        self.bookmark = bookmark
        _title = State(initialValue: bookmark.title)
        _urlText = State(initialValue: bookmark.url)
        _selectedFolderID = State(initialValue: bookmark.folderID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名前") {
                    TextField("名前", text: $title)
                }
                Section {
                    TextField("URL", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                } header: {
                    Text("URL")
                } footer: {
                    if !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !Self.looksLikeURL(urlText) {
                        Text("URLとして解釈できませんでした。そのまま保存することもできます")
                    }
                }
                Section("保存先フォルダ") {
                    ForEach(flatFolders, id: \.folder.id) { entry in
                        Button {
                            selectedFolderID = entry.folder.id
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(Theme.cobalt)
                                Text(entry.folder.name)
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                if selectedFolderID == entry.folder.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.cobalt)
                                }
                            }
                            .padding(.leading, CGFloat(entry.depth) * 16)
                        }
                    }
                }
                if let conflictTitle {
                    Section {
                        Text("そのURLはすでに別のブックマーク「\(conflictTitle)」に登録されているため保存できませんでした")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("ブックマークを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private struct FlatFolder {
        let folder: BookmarkFolder
        let depth: Int
    }

    private var flatFolders: [FlatFolder] {
        var out: [FlatFolder] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for folder in store.subfolders(of: parent) {
                out.append(FlatFolder(folder: folder, depth: depth))
                walk(folder.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    private func save() {
        let url = Self.normalizedURL(urlText)
        if store.updateBookmark(id: bookmark.id,
                                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                url: url,
                                folderID: selectedFolderID) {
            dismiss()
        } else {
            conflictTitle = store.conflictingBookmarkTitle(forURL: url, excluding: bookmark.id)
                ?? "（不明なブックマーク）"
        }
    }

    /// Missing-scheme normalisation for hand-typed URLs. Anything that
    /// already carries an explicit scheme is returned untouched — in
    /// particular javascript: bookmarklets are never mangled — and text
    /// containing spaces (not URL-shaped at all) is kept exactly as
    /// typed instead of being blocked.
    static func normalizedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.contains("://") { return trimmed }
        if trimmed.contains(" ") { return trimmed }
        if let colon = trimmed.firstIndex(of: ":") {
            let scheme = trimmed[..<colon]
            if let first = scheme.first, first.isLetter, !scheme.contains("."),
               scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }) {
                return trimmed
            }
        }
        return "https://" + trimmed
    }

    static func looksLikeURL(_ raw: String) -> Bool {
        let normalized = normalizedURL(raw)
        if normalized.lowercased().hasPrefix("javascript:") { return true }
        guard let url = URL(string: normalized) else { return false }
        return url.host != nil
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
