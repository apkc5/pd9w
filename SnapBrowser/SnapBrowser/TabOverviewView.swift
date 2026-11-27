import SwiftUI

/// Tab overview as a horizontal carousel of LARGE cards, app-switcher
/// style (the user's Brave-on-iPad reference photo): each card is most
/// of the screen, cards snap one-by-one as you swipe sideways, the
/// current tab is framed in cobalt, and a ＋ card at the end of the row
/// adds a tab. Layout inspiration only — no Brave assets.
///
/// v0.4 layout fix: EVERY metric below comes from the GeometryReader's
/// container size — the window this view is actually displayed in.
/// v0.3 derived card geometry in ways that broke inside iPad floating
/// windows (cards wider than the window, neighbours covering the edge,
/// distorted previews): the header gets an explicit top inset because
/// a fullScreenCover's safe area does not clear the iPadOS window
/// chrome (traffic-light buttons) the way the main window's does, and
/// previews are captured at the active window's size (see
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
            let cardWidth = container.width >= 700
                ? container.width * 0.62
                : container.width * 0.84
            let cardHeight = max(container.height - headerHeight - 32, 180)
            // Symmetric side padding lets the snapped card sit centred,
            // with both neighbours peeking in equally.
            let side = max((container.width - cardWidth) / 2, 12)

            VStack(spacing: 0) {
                header
                    .frame(height: headerHeight)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 16) {
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
                                    .frame(width: cardWidth, height: cardHeight)
                                    .id(tab.id)
                            }
                            newTabCard
                                .frame(width: cardWidth, height: cardHeight)
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, side)
                        .padding(.vertical, 16)
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .onAppear {
                        proxy.scrollTo(manager.activeTabID, anchor: .center)
                    }
                }
            }
        }
        .background(Theme.paper)
        .onAppear { manager.captureAllPreviews() }
    }

    // MARK: New tab card (end of the row)

    private var newTabCard: some View {
        Button {
            manager.newTab()
            dismiss()
        } label: {
            VStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 44, weight: .bold))
                Text("新しいタブ")
                    .font(.headline)
            }
            .foregroundStyle(Theme.cobalt)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}
