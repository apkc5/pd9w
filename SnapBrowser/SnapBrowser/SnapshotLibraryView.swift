import SwiftUI

/// Date-grouped snapshot library (timeline first, like the Android version).
struct SnapshotLibraryView: View {
    @ObservedObject var store: SnapshotStore
    var onOpenURL: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if store.items.isEmpty {
                ContentUnavailableView("スナップはまだありません",
                                       systemImage: "camera.aperture",
                                       description: Text("ページを開いて SNAP を押すと、ここに日付順で並びます。"))
            } else {
                List {
                    ForEach(groupedDays, id: \.day) { group in
                        Section(group.day) {
                            ForEach(group.items) { item in
                                NavigationLink {
                                    SnapshotViewerView(store: store, item: item,
                                                       onOpenURL: onOpenURL)
                                } label: {
                                    SnapshotRow(item: item)
                                }
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    store.delete(group.items[index])
                                }
                            }
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
        .onAppear { store.reload() }
    }

    private var groupedDays: [(day: String, items: [SnapshotItem])] {
        let groups = Dictionary(grouping: store.items, by: { store.dayKey(for: $0) })
        return groups.keys.sorted(by: >).map { day in
            (day: day, items: groups[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }
}

private struct SnapshotRow: View {
    let item: SnapshotItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.headline)
                .lineLimit(2)
            Text(item.url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                if let b = item.imageBytes { badge("画像 \(shortSize(b))") }
                if let b = item.archiveBytes { badge("アーカイブ \(shortSize(b))") }
                if let c = item.textChars { badge("テキスト \(c)文字") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
