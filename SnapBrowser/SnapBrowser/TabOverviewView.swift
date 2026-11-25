import SwiftUI

/// Brave-style tab overview: large preview cards in a grid (2 columns on
/// iPhone, 3+ across on iPad), each with a title header and a × close
/// button, the current tab framed in cobalt, and a ＋ new-tab button at
/// the bottom centre. Layout inspiration only — no Brave assets.
struct TabOverviewView: View {
    @ObservedObject var manager: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            header
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
                }
                .padding(16)
            }
            newTabBar
        }
        .background(Theme.paper)
        .onAppear { manager.captureAllPreviews() }
    }

    private var columns: [GridItem] {
        if sizeClass == .regular {
            return [GridItem(.adaptive(minimum: 300), spacing: 16)]
        }
        return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

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

    private var newTabBar: some View {
        HStack {
            Spacer()
            Button {
                manager.newTab()
                dismiss()
            } label: {
                Image(systemName: "plus")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.cobalt))
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
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
        .frame(maxWidth: .infinity)
        .aspectRatio(0.78, contentMode: .fit)
        .clipped()
    }
}
