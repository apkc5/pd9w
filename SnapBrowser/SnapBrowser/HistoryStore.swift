import Foundation

/// Browsing history, Brave-style: date-grouped, per-item delete, search.
/// Persistence: a single JSON file in Documents. No Keychain.
struct HistoryItem: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var url: String
    var visitedAt: Date

    var host: String {
        URL(string: url)?.host ?? url
    }
}

final class HistoryStore: ObservableObject {
    @Published private(set) var items: [HistoryItem] = []

    private static let cap = 2000

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("history.json")
    }

    init() {
        load()
    }

    /// Records a finished live navigation. Consecutive visits to the same
    /// URL refresh the existing entry instead of piling up duplicates.
    func record(title: String, url: String) {
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return }
        if var first = items.first, first.url == url {
            first.title = title.isEmpty ? first.title : title
            first.visitedAt = Date()
            items[0] = first
        } else {
            items.insert(HistoryItem(id: UUID(),
                                     title: title.isEmpty ? url : title,
                                     url: url,
                                     visitedAt: Date()), at: 0)
        }
        if items.count > Self.cap {
            items.removeLast(items.count - Self.cap)
        }
        save()
    }

    func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clearAll() {
        items = []
        save()
    }

    func search(_ query: String) -> [HistoryItem] {
        let q = query.lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
