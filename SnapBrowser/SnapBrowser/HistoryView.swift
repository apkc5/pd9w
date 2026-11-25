import SwiftUI

/// Brave-style history: day-grouped sections with headers like
/// 「今日 - 2026年11月25日」, letter-avatar rows, per-item × delete,
/// search, and a clear-all entry at the top.
struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    var onOpen: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView("履歴はまだありません",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("開いたページがここに日付順で並びます。"))
                } else {
                    List {
                        Section {
                            Button(role: .destructive) {
                                showClearConfirm = true
                            } label: {
                                HStack {
                                    Text("閲覧履歴データを削除…")
                                    Spacer()
                                }
                            }
                        }
                        ForEach(dayGroups) { group in
                            Section {
                                ForEach(group.items) { item in
                                    HistoryRow(item: item,
                                               onOpen: onOpen,
                                               onDelete: { store.delete(item) })
                                }
                            } header: {
                                Text(group.title)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("履歴")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "履歴を検索")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .confirmationDialog("閲覧履歴をすべて削除しますか？",
                                isPresented: $showClearConfirm,
                                titleVisibility: .visible) {
                Button("すべて削除", role: .destructive) { store.clearAll() }
                Button("キャンセル", role: .cancel) {}
            }
        }
    }

    // MARK: Grouping

    private struct DayGroup: Identifiable {
        let day: Date
        let title: String
        let items: [HistoryItem]
        var id: Date { day }
    }

    private var dayGroups: [DayGroup] {
        let calendar = Calendar.current
        let visible = store.search(searchText)
        let grouped = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.visitedAt) }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(day: day,
                     title: title(for: day, calendar: calendar),
                     items: (grouped[day] ?? []).sorted { $0.visitedAt > $1.visitedAt })
        }
    }

    private func title(for day: Date, calendar: Calendar) -> String {
        let dateText = DateFormatters.dayTitle.string(from: day)
        if calendar.isDateInToday(day) { return "今日 - \(dateText)" }
        if calendar.isDateInYesterday(day) { return "昨日 - \(dateText)" }
        return dateText
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    var onOpen: (String) -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onOpen(item.url)
            } label: {
                HStack(spacing: 10) {
                    LetterAvatar(text: item.title.isEmpty ? item.host : item.title, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text(item.host)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("削除", systemImage: "trash")
            }
        }
    }
}
