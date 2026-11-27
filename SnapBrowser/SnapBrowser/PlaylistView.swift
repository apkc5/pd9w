import SwiftUI
import AVKit
import UIKit

/// Playlist screen (v0.4.6): the media shelf. Rows show thumbnail,
/// title and download state; tap plays (local file when downloaded,
/// streamed otherwise). Reached from the ⋯ menu like bookmarks and
/// history. The toolbar menu carries the URL-list import and the
/// only bulk wipe for downloaded files.
struct PlaylistView: View {
    @ObservedObject var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss

    @State private var playingItem: PlaylistItem?
    @State private var showAddURLs = false
    @State private var confirmDeleteAllDownloads = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(store.items) { item in
                                PlaylistRow(store: store, item: item,
                                            onPlay: { playingItem = item },
                                            onNotice: { notice = $0 })
                            }
                        } footer: {
                            Text("保存済み \(store.downloadedCount) 件 ・ 合計 \(byteText(store.totalDownloadedBytes))")
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showAddURLs = true
                        } label: {
                            Label("URLリストから追加", systemImage: "text.badge.plus")
                        }
                        Button(role: .destructive) {
                            confirmDeleteAllDownloads = true
                        } label: {
                            Label("ダウンロード済みを全削除", systemImage: "trash")
                        }
                        .disabled(store.downloadedCount == 0)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $playingItem) { item in
                if let url = store.playbackURL(for: item) {
                    PlaylistPlayerView(url: url)
                }
            }
            .sheet(isPresented: $showAddURLs) {
                AddURLsSheet(store: store) { summary in
                    notice = summary
                }
            }
            .confirmationDialog("ダウンロード済みファイルをすべて削除しますか？",
                                isPresented: $confirmDeleteAllDownloads,
                                titleVisibility: .visible) {
                Button("全削除", role: .destructive) {
                    store.deleteAllDownloads()
                    notice = "ダウンロード済みファイルを削除しました"
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("アイテム自体は残り、未ダウンロード状態に戻ります。")
            }
            .alert("Playlist", isPresented: noticeBinding) {
                Button("OK", role: .cancel) { notice = nil }
            } message: {
                Text(notice ?? "")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Playlistは空です")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text("動画のあるページで ⋯ メニューの「Playlistに追加」、\nまたは右上のメニューからURLリストで追加できます")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private var noticeBinding: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Row

private struct PlaylistRow: View {
    @ObservedObject var store: PlaylistStore
    let item: PlaylistItem
    var onPlay: () -> Void
    var onNotice: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                stateLine
            }
            Spacer(minLength: 0)
            stateButton
        }
        .contentShape(Rectangle())
        .onTapGesture { onPlay() }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.remove(item)
            } label: {
                Label("削除", systemImage: "trash")
            }
            stateSwipeAction
        }
        .swipeActions(edge: .leading) {
            Button {
                copyURL()
            } label: {
                Label("URLをコピー", systemImage: "doc.on.doc")
            }
            .tint(Theme.cobalt)
        }
        .contextMenu {
            Button { onPlay() } label: {
                Label("再生", systemImage: "play.fill")
            }
            stateMenuAction
            Button { copyURL() } label: {
                Label("URLをコピー", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) { store.remove(item) } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.surface)
            if let url = store.thumbnailURL(for: item),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    @ViewBuilder
    private var stateLine: some View {
        switch item.state {
        case .notDownloaded:
            Text("未ダウンロード")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading:
            let value = store.progress[item.id] ?? 0
            if value >= 0 {
                Text("ダウンロード中 \(Int(value * 100))%")
                    .font(.caption)
                    .foregroundStyle(Theme.cobalt)
            } else {
                Text("ダウンロード中…")
                    .font(.caption)
                    .foregroundStyle(Theme.cobalt)
            }
        case .downloaded:
            Text("保存済み ・ \(ByteCountFormatter.string(fromByteCount: item.fileBytes ?? 0, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Text("失敗: \(item.errorMessage ?? "不明なエラー")")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var stateButton: some View {
        switch item.state {
        case .notDownloaded:
            Button { store.startDownload(item) } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.cobalt)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .downloading:
            let value = store.progress[item.id] ?? 0
            ZStack {
                if value >= 0 {
                    ProgressView(value: value)
                        .progressViewStyle(.circular)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
                Button { store.cancelDownload(item) } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.bold())
                        .foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: 44, height: 44)
        case .failed:
            Button { store.startDownload(item) } label: {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.cobalt)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .downloaded:
            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(Theme.cobalt)
                .frame(width: 44, height: 44)
        }
    }

    @ViewBuilder
    private var stateSwipeAction: some View {
        switch item.state {
        case .notDownloaded:
            Button { store.startDownload(item) } label: {
                Label("ダウンロード", systemImage: "arrow.down.to.line")
            }
            .tint(Theme.cobalt)
        case .downloading:
            Button { store.cancelDownload(item) } label: {
                Label("キャンセル", systemImage: "xmark")
            }
        case .failed:
            Button { store.startDownload(item) } label: {
                Label("再試行", systemImage: "arrow.clockwise")
            }
            .tint(Theme.cobalt)
        case .downloaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private var stateMenuAction: some View {
        switch item.state {
        case .notDownloaded:
            Button { store.startDownload(item) } label: {
                Label("ダウンロード", systemImage: "arrow.down.to.line")
            }
        case .downloading:
            Button { store.cancelDownload(item) } label: {
                Label("ダウンロードをキャンセル", systemImage: "xmark")
            }
        case .failed:
            Button { store.startDownload(item) } label: {
                Label("再試行", systemImage: "arrow.clockwise")
            }
        case .downloaded:
            EmptyView()
        }
    }

    private func copyURL() {
        UIPasteboard.general.string = item.url
        onNotice("URLをコピーしました")
    }
}

// MARK: - Player (AVPlayerViewController sheet)

struct PlaylistPlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                AVPlayerController(player: player)
                    .ignoresSafeArea()
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                Spacer()
            }
        }
        .onAppear {
            let newPlayer = AVPlayer(url: url)
            player = newPlayer
            newPlayer.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

private struct AVPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}

// MARK: - Add by URL list

/// Paste-many-URLs sheet: one URL per line. This is the path for
/// importing an existing list (e.g. the user's 26 saved video URLs).
struct AddURLsSheet: View {
    @ObservedObject var store: PlaylistStore
    var onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .padding(8)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Divider()
                HStack {
                    Button {
                        if let pasted = UIPasteboard.general.string {
                            text = pasted
                        }
                    } label: {
                        Label("クリップボードから貼り付け", systemImage: "doc.on.clipboard")
                            .font(.subheadline)
                    }
                    Spacer()
                    Text("\(validCount) 件のURL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationTitle("URLリストから追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") { add() }
                        .disabled(validCount == 0)
                }
            }
        }
    }

    private var validCount: Int {
        text.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil else { return false }
            return true
        }.count
    }

    private func add() {
        let outcome = store.addFromList(text)
        dismiss()
        onDone("追加 \(outcome.added) 件 / 重複 \(outcome.duplicates) 件 / 無効 \(outcome.invalid) 件")
    }
}

// MARK: - Detected media picker (save badge / ⋯ menu)

/// Lists the media detected on the current page so the user can pick
/// which ones go into the playlist (or take them all). blob: rows are
/// shown but disabled, with the honest reason — a blob URL is a
/// page-session handle (MSE) and cannot be saved from the URL.
struct DetectedMediaSheet: View {
    @ObservedObject var playlist: PlaylistStore
    let items: [DetectedMedia]
    let pageTitle: String
    var onAdded: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    private var httpItems: [DetectedMedia] { items.filter { $0.isHTTP } }
    private var blockedItems: [DetectedMedia] { items.filter { !$0.isHTTP } }

    var body: some View {
        NavigationStack {
            List {
                if !httpItems.isEmpty {
                    Section("このページの動画") {
                        ForEach(httpItems) { media in
                            row(for: media)
                        }
                    }
                }
                if !blockedItems.isEmpty {
                    Section {
                        ForEach(blockedItems) { media in
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(media.isBlob ? "保存できません（blob:）" : "保存できません")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(media.url)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    } footer: {
                        Text("blob: の動画はページ内再生専用（MSE）のため、URLからは保存できません。")
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Playlistに追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加（\(selectedNewCount)）") { addSelected() }
                        .disabled(selectedNewCount == 0)
                }
            }
            .onAppear {
                selected = Set(httpItems.map { $0.url }
                    .filter { !playlist.contains(url: $0) })
            }
        }
    }

    private var selectedNewCount: Int {
        selected.filter { !playlist.contains(url: $0) }.count
    }

    private func row(for media: DetectedMedia) -> some View {
        let alreadyAdded = playlist.contains(url: media.url)
        return HStack(spacing: 10) {
            Button {
                if selected.contains(media.url) {
                    selected.remove(media.url)
                } else {
                    selected.insert(media.url)
                }
            } label: {
                Image(systemName: selected.contains(media.url)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(alreadyAdded ? .secondary : Theme.cobalt)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(alreadyAdded)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: media))
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(media.url)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if alreadyAdded {
                Text("追加済み")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Page title, numbered when the page offered several videos —
    /// same convention as the ⋯ menu add.
    private func title(for media: DetectedMedia) -> String {
        let base = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = base.isEmpty ? PlaylistMedia.defaultTitle(for: media.url) : base
        guard httpItems.count > 1,
              let index = httpItems.firstIndex(of: media) else { return resolved }
        return "\(resolved) (\(index + 1))"
    }

    private func addSelected() {
        var added = 0
        for media in httpItems where selected.contains(media.url) {
            if playlist.add(title: title(for: media), url: media.url, pageURL: nil) {
                added += 1
            }
        }
        dismiss()
        if added > 0 { onAdded(added) }
    }
}
