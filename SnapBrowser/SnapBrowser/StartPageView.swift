import SwiftUI

/// New-tab page in our own design system (layout inspiration from the
/// Brave new-tab page, but no Brave stats, wallpaper or assets):
/// app name up top, then bookmark shortcuts as tiles.
struct StartPageView: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var bookmarks: BookmarkStore
    var onShowBookmarks: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                brandHeader
                shortcutsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var shortcuts: [Bookmark] {
        Array(bookmarks.bookmarks.sorted { $0.addedAt > $1.addedAt }.prefix(12))
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        if shortcuts.isEmpty {
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
        } else {
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

    private func open(_ bookmark: Bookmark) {
        if bookmark.url.lowercased().hasPrefix("javascript:") {
            // Bookmarklets need a live page context; ignore on the start page.
            return
        }
        if let url = URL(string: bookmark.url) {
            tab.load(url)
        }
    }
}
