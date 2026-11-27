import SwiftUI

/// Date-grouped snapshot library (timeline first, like the Android version).
/// Tapping a row opens the snapshot in a normal browser tab (with the
/// 保存版 banner); the 詳細 button opens the 3-mode viewer instead.
struct SnapshotLibraryView: View {
    @ObservedObject var store: SnapshotStore
    var onOpenInBrowser: (SnapshotItem) -> Void
    var onOpenURL: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var viewerItem: SnapshotItem?
    @State private var sharePayload: SharePayload?

    var body: some View {
        Group {
            if store.items.isEmpty {
                ContentUnavailableView("スナップはまだありません",
                                       systemImage: "camera.aperture",
                                       description: Text("ページを開いて SNAP を押すと、ここに日付順で並びます。"))
            } else {
                List {
                    ForEach(groupedDays) { group in
                        Section {
                            ForEach(group.items) { item in
                                SnapshotRow(item: item,
                                            onOpen: { onOpenInBrowser(item) },
                                            onDetail: { viewerItem = item },
                                            onShare: { share(item) },
                                            onDelete: { store.delete(item) })
                            }
                        } header: {
                            Text(group.day)
                        }
                    }
                }
            }
        }
        .navigationTitle("ライブラリ")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("閉じる") { dismiss() }
            }
        }
        .navigationDestination(item: $viewerItem) { item in
            SnapshotViewerView(store: store, item: item, onOpenURL: onOpenURL)
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items)
        }
        .onAppear { store.reload() }
    }

    /// Shares the snapshot's saved files (image / self-contained HTML /
    /// web archive — whichever exist) via the system share sheet.
    private func share(_ item: SnapshotItem) {
        let fm = FileManager.default
        let files = ["image.png", "full.html", "archive.webarchive"]
            .map { store.fileURL(for: item, name: $0) }
            .filter { fm.fileExists(atPath: $0.path) }
        if !files.isEmpty {
            sharePayload = SharePayload(items: files)
        }
    }

    private struct DayGroup: Identifiable {
        let day: String
        let items: [SnapshotItem]
        var id: String { day }
    }

    private var groupedDays: [DayGroup] {
        let groups = Dictionary(grouping: store.items, by: { store.dayKey(for: $0) })
        return groups.keys.sorted(by: >).map { day in
            DayGroup(day: day, items: groups[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }
}

private struct SnapshotRow: View {
    let item: SnapshotItem
    var onOpen: () -> Void
    var onDetail: () -> Void
    var onShare: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Text(item.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let b = item.imageBytes { badge("画像 \(shortSize(b))") }
                        if let b = item.archiveBytes { badge("アーカイブ \(shortSize(b))") }
                        if let b = item.fullHTMLBytes { badge("自己完結 \(shortSize(b))") }
                        if let c = item.textChars { badge("テキスト \(c)文字") }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button(action: onDetail) {
                Text("詳細")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.cobalt)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("削除", systemImage: "trash")
            }
            Button(action: onShare) {
                Label("共有", systemImage: "square.and.arrow.up")
            }
            .tint(Theme.cobalt)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
    }

    private func shortSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
