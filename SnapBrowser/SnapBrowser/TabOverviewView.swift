import SwiftUI

/// Tab overview as a GRID of small cards — the user's reference changed
/// from the Brave app-switcher carousel to Chrome on iPad's tab grid:
/// many tabs visible at once (4 columns on a full-screen iPad), each
/// card a header (title + ×) over a wide-ish (4:3) preview, the current
/// tab framed in cobalt, and a ＋ card at the end of the grid adding a
/// tab. Layout inspiration only — no Chrome assets.
///
/// All metrics derive from the GeometryReader's container size (the
/// window the view is actually in) — v0.4 removed every UIScreen-based
/// measurement after the carousel broke inside iPad floating windows,
/// and the header keeps its explicit top inset because a
/// fullScreenCover's safe area does not clear the iPadOS window chrome
/// (traffic-light buttons) the way the main window's does. Previews are
/// captured at the active window's size (see
/// BrowserTab.capturePreview(matching:)).
struct TabOverviewView: View {
    @ObservedObject var manager: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            let container = geo.size
            // Header slot includes the top inset that clears the window
            // chrome overlaying the cover.
            let headerHeight: CGFloat = 76
            // Adaptive columns: ~260pt minimum card width gives 4
            // columns on a full-screen iPad and automatically fewer
            // (3, then 2) as the window narrows.
            let columns = [GridItem(.adaptive(minimum: 260), spacing: 16)]

            VStack(spacing: 0) {
                header
                    .frame(height: headerHeight)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(manager.tabs) { tab in
                            TabCard(tab: tab,
                                    isActive: tab.id == manager.activeTabID,
                                    onSelect: {
                                        manager.selectTab(tab)
                                        dismiss()
                                    },
                                    onClose: {
                                        manager.closeTab(tab)
                                    })
                        }
                        newTabCard
                    }
                    .padding(16)
                }
            }
            .frame(width: container.width, height: container.height)
        }
        .background(Theme.paper)
        .onAppear { manager.captureAllPreviews() }
    }

    // MARK: New tab card (end of the grid)

    private var newTabCard: some View {
        Button {
            manager.newTab()
            dismiss()
        } label: {
            VStack(spacing: 0) {
                // Spacer row matching TabCard's header height so the
                // card lines up with its neighbours in the grid row.
                Color.clear
                    .frame(height: 44)
                VStack(spacing: 12) {
                    Image(systemName: "plus")
                        .font(.system(size: 40, weight: .bold))
                    Text("新しいタブ")
                        .font(.headline)
                }
                .foregroundStyle(Theme.cobalt)
                .frame(maxWidth: .infinity)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.cobalt.opacity(0.45),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("タブ")
                .font(.title2.bold())
                .foregroundStyle(Theme.ink)
            Text("\(manager.tabs.count)件")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.bold())
                    .foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 16)
        // Extra top padding: inside a fullScreenCover the iPadOS window
        // controls overlay the top-left corner (v0.3's header collided
        // with them in floating windows).
        .padding(.top, 20)
        .padding(.bottom, 10)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let isActive: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            cardHeader
            preview
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isActive ? Theme.cobalt : Theme.hairline,
                              lineWidth: isActive ? 2.5 : 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { onSelect() }
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            if tab.archiveSnapshot != nil {
                ApertureIcon(size: 16)
            } else {
                LetterAvatar(text: tab.pageTitle.isEmpty ? (tab.addressText) : tab.pageTitle,
                             size: 22)
            }
            Text(cardTitle)
                .font(.subheadline.bold())
                .foregroundStyle(isActive ? Theme.cobalt : Theme.ink)
                .lineLimit(1)
            Spacer()
            if tab.isPrivate {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private var cardTitle: String {
        if tab.showsStartPage { return "新しいタブ" }
        if !tab.pageTitle.isEmpty { return tab.pageTitle }
        if !tab.addressText.isEmpty { return tab.addressText }
        return "新しいタブ"
    }

    private var preview: some View {
        ZStack {
            Theme.paper
            if tab.showsStartPage {
                VStack(spacing: 8) {
                    ApertureIcon(size: 36)
                    Text("スナップブラウザ")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                }
            } else if let image = tab.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "globe")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        // Wide-ish 4:3 preview window like the Chrome grid reference;
        // the image fills it and is clipped (no letterboxing).
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipped()
    }
}
