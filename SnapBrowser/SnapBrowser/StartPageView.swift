import SwiftUI

/// New-tab page in our own design system (layout inspiration from the
/// Brave new-tab page, but no Brave stats, wallpaper or assets):
/// brand header, frequent sites, bookmark shortcuts, recent pages —
/// and, since v0.4.9, a small pet strolling along the bottom edge.
///
/// v0.4.9 (items 8+9): the page used to be just the brand header and
/// bookmark tiles. Frequent/recent sections are derived from the
/// history store and are hidden entirely when there is no history;
/// on private tabs they never appear (a private tab must not surface
/// the user's history). Shortcut tiles can be removed from THIS page
/// via long-press — hide-only, the bookmark itself is never deleted,
/// exactly like the address-bar panel's ×.
struct StartPageView: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var bookmarks: BookmarkStore
    @ObservedObject var history: HistoryStore
    @ObservedObject var settings: AppSettings
    var onShowBookmarks: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    brandHeader
                    if !tab.isPrivate {
                        frequentSection
                    }
                    shortcutsSection
                    if !tab.isPrivate {
                        recentSection
                    }
                }
                .padding(20)
                // Clearance so the last section is never hidden
                // behind the walking pet's strip.
                .padding(.bottom, 56)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if settings.homePet != .none {
                WalkingPetView(pet: settings.homePet)
                    .frame(height: 60)
                    .padding(.bottom, 2)
            }
        }
        .background(Theme.paper)
    }

    private var brandHeader: some View {
        HStack(spacing: 12) {
            ApertureIcon(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("スナップブラウザ")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.ink)
                Text("見たページを、そのまま保存する。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 12)
    }

    // MARK: - Frequent sites (v0.4.9)

    private struct FrequentSite: Identifiable {
        var host: String
        var count: Int
        var latest: HistoryItem
        var id: String { host }
    }

    /// Most-visited hosts from history: grouped by host, ordered by
    /// visit count (then recency), 8 at most.
    private var frequentSites: [FrequentSite] {
        var byHost: [String: (count: Int, latest: HistoryItem)] = [:]
        for item in history.items {
            let host = item.host
            if let existing = byHost[host] {
                byHost[host] = (existing.count + 1, existing.latest)
            } else {
                // history.items is newest-first, so the first item
                // seen for a host is also its most recent visit.
                byHost[host] = (1, item)
            }
        }
        return byHost
            .map { FrequentSite(host: $0.key, count: $0.value.count, latest: $0.value.latest) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.latest.visitedAt > $1.latest.visitedAt
            }
            .prefix(8)
            .map { $0 }
    }

    @ViewBuilder
    private var frequentSection: some View {
        let sites = frequentSites
        if !sites.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("よく見るサイト")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                          spacing: 12) {
                    ForEach(sites) { site in
                        Button {
                            loadString(site.latest.url)
                        } label: {
                            HStack(spacing: 10) {
                                LetterAvatar(text: site.host, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(site.host)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    Text("\(site.count)回")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Theme.hairline, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Bookmark shortcuts

    private var shortcuts: [Bookmark] {
        Array(bookmarks.bookmarks
            .filter { !settings.isShortcutHidden($0.url) }
            .sorted { $0.addedAt > $1.addedAt }
            .prefix(12))
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        if bookmarks.bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("ブックマーク")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text("まだブックマークがありません。Braveなどから書き出したHTMLを取り込むと、ここにショートカットが並びます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(action: onShowBookmarks) {
                    Text("ブックマークを開く")
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.cobalt)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.hairline, lineWidth: 0.5))
        } else if !shortcuts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("ブックマーク")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                          spacing: 12) {
                    ForEach(shortcuts) { bookmark in
                        Button {
                            open(bookmark)
                        } label: {
                            shortcutTile(bookmark)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                settings.hideShortcutURL(bookmark.url)
                            } label: {
                                Label("ショートカットから外す", systemImage: "eye.slash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func shortcutTile(_ bookmark: Bookmark) -> some View {
        HStack(spacing: 10) {
            LetterAvatar(text: bookmark.title.isEmpty ? bookmark.url : bookmark.title,
                         size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(URL(string: bookmark.url)?.host ?? bookmark.url)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    private func loadString(_ urlString: String) {
        if let url = URL(string: urlString) {
            tab.load(url)
        }
    }

    private func open(_ bookmark: Bookmark) {
        if bookmark.url.lowercased().hasPrefix("javascript:") {
            // Bookmarklets need a live page context; ignore on the start page.
            return
        }
        if let url = URL(string: bookmark.url) {
            tab.load(url)
        }
    }

    // MARK: - Recent pages (v0.4.9)

    @ViewBuilder
    private var recentSection: some View {
        let recent = Array(history.items.prefix(6))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("最近見たページ")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, item in
                        Button {
                            loadString(item.url)
                        } label: {
                            HStack(spacing: 10) {
                                LetterAvatar(text: item.title.isEmpty ? item.host : item.title,
                                             size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    Text(item.host)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.forward")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < recent.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5))
            }
        }
    }
}
