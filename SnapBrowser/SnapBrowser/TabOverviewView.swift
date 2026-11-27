import SwiftUI

/// Tab overview as a horizontal carousel of LARGE cards, app-switcher
/// style (the user's Brave-on-iPad reference photo): each card is most of
/// the screen, cards snap one-by-one as you swipe sideways, the current
/// tab is framed in cobalt, and a ＋ card at the end of the row adds a
/// tab. Layout inspiration only — no Brave assets.
struct TabOverviewView: View {
    @ObservedObject var manager: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            carousel
        }
        .background(Theme.paper)
        .onAppear { manager.captureAllPreviews() }
    }

    // MARK: Carousel

    private var carousel: some View {
        GeometryReader { geo in
            // iPad (wide): card ≈ 62% of the width so neighbours peek in
            // from both sides. iPhone: near-full-width cards.
            let cardWidth = geo.size.width >= 700
                ? geo.size.width * 0.62
                : geo.size.width * 0.84
            let cardHeight = max(geo.size.height - 32, 200)
            // Symmetric side padding lets the snapped card sit centred.
            let side = max((geo.size.width - cardWidth) / 2, 16)

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
        .padding(.vertical, 10)
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
