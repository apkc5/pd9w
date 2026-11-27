import SwiftUI
import UniformTypeIdentifiers

/// Tab overview as a GRID of small cards, modelled on Chrome on
/// iPad's tab screen: fixed-feeling cards (2 columns in a narrow
/// floating window, 4 on a full-screen iPad), a round ＋ button at
/// the bottom centre for a new tab, and a 「完了」 button at the
/// bottom right to close — no ＋ card in the grid, no × in the
/// header (closing happens via 完了 or by tapping a card). Each card
/// keeps its header band (favicon tile + title + ×) over a preview,
/// the current tab framed in cobalt. Layout inspiration only — no
/// Chrome assets, and the ＋ is Cobalt, not Chrome blue.
///
/// v0.4.5 column-count post-mortem: v0.4.3/v0.4.4 used
/// `GridItem(.adaptive(minimum: 170))`, which on the user's device
/// collapsed to ONE full-width column in his ~380pt floating window.
/// That was arithmetic, not a stale build (the 170 minimum was
/// verified in the shipped source): two adaptive columns need
/// 2×170 + 16 spacing = 356pt of content width, i.e. a window of at
/// least 388pt once the grid's 16pt side padding is counted — his
/// window is just under that, so adaptive legitimately computed one
/// column and then stretched it to the full content width, and the
/// portrait 3:4 preview made the single card fill the screen. The
/// fix is to stop asking adaptive: the column count is decided
/// explicitly from the container width (see columnCount(forWidth:)),
/// and fixed flexible tracks mean a lone tab keeps its column width
/// instead of stretching — exactly what Chrome's grid does.
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
    /// Tab search (v0.4.9): filters the grid by title / URL,
    /// case-insensitive substring — same rule as the other searches.
    @State private var query = ""
    /// Card drag-reorder (v0.4.10): the tab currently being dragged,
    /// for the dimmed-source-card effect and the drop delegates.
    @State private var draggingTabID: UUID?

    /// Reorder is only offered on the full, unfiltered list:
    /// reordering a filtered subset would move cards the user can't
    /// see and scramble the real order, so searching disables it.
    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleTabs: [BrowserTab] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return manager.tabs }
        return manager.tabs.filter { tab in
            tab.pageTitle.lowercased().contains(q)
                || tab.addressText.lowercased().contains(q)
                || (tab.currentURLString?.lowercased().contains(q) ?? false)
        }
    }

    /// Column count from the container width — explicit, never
    /// adaptive. Card width = (width − 32 padding − 16×(n−1) spacing) / n:
    ///   ~380pt window → 2 cols × ~166pt    ~430pt → 2 × ~191pt
    ///   ~520pt window → 2 cols × ~236pt    ~700pt → 3 × ~212pt
    ///   ~900pt        → 4 cols × ~205pt    full iPad (1376pt) → 4 × ~324pt
    /// Below 340pt (phone-width Slide Over) a single column of
    /// readable cards beats two slivers.
    static func columnCount(forWidth width: CGFloat) -> Int {
        if width < 340 { return 1 }
        if width < 560 { return 2 }
        if width < 900 { return 3 }
        return 4
    }

    var body: some View {
        GeometryReader { geo in
            let container = geo.size
            // Header slot includes the top inset that clears the window
            // chrome overlaying the cover.
            let headerHeight: CGFloat = 76
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 16),
                count: Self.columnCount(forWidth: container.width))
            // Preview aspect follows the container like Chrome's grid:
            // portrait windows get portrait (3:4) cards, landscape
            // windows get wide (4:3) cards. Previews are captured at
            // the window's real size, so matching the frame to the
            // container's orientation also reduces cropping.
            let previewAspect: CGFloat = container.height > container.width
                ? 3.0 / 4.0 : 4.0 / 3.0

            VStack(spacing: 0) {
                header
                    .frame(height: headerHeight)
                searchField
                ScrollView {
                    if visibleTabs.isEmpty {
                        Text("「\(query)」に一致するタブがありません")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(visibleTabs) { tab in
                            TabCard(tab: tab,
                                    isActive: tab.id == manager.activeTabID,
                                    previewAspect: previewAspect,
                                    onSelect: {
                                        manager.selectTab(tab)
                                        dismiss()
                                    },
                                    onClose: {
                                        manager.closeTab(tab)
                                    })
                                // The dragged card dims; the OTHER
                                // cards slide aside live as the drag
                                // crosses them (the drop delegate
                                // reorders the model mid-drag), which
                                // is the insertion feedback.
                                .opacity(draggingTabID == tab.id ? 0.35 : 1)
                                .tabReorderDragDrop(
                                    enabled: !isSearching,
                                    tab: tab,
                                    manager: manager,
                                    draggingID: $draggingTabID)
                        }
                    }
                    .padding(16)
                    // Drops that land on grid gaps (not on a card)
                    // still end the drag cleanly.
                    .onDrop(of: [.text],
                            delegate: TabGridCatchAllDropDelegate(draggingID: $draggingTabID))
                }
                bottomBar
            }
            .frame(width: container.width, height: container.height)
        }
        .background(Theme.paper)
        .onAppear {
            draggingTabID = nil
            manager.captureAllPreviews()
        }
        .onChange(of: query) { _ in draggingTabID = nil }
    }

    // MARK: Search field (v0.4.9)

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("タブを検索", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Capsule().fill(Theme.paper))
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Bottom bar (Chrome layout: round ＋ centre, 完了 right)

    /// The round ＋ is a deliberate, single-screen exception to the
    /// app's no-floating-buttons rule — Chrome's tab screen has it,
    /// the user asked for Chrome's structure, and it lives in this
    /// flush bottom bar rather than floating over content.
    private var bottomBar: some View {
        ZStack {
            HStack {
                Spacer()
                Button("完了") { dismiss() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.cobalt)
                    .frame(height: 44)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            Button {
                manager.newTab()
                dismiss()
            } label: {
                Image(systemName: "plus")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Theme.cobalt))
                    .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
                    .contentShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Header (title only — closing lives in the bottom bar)

    private var header: some View {
        HStack(spacing: 10) {
            Text("タブ")
                .font(.title2.bold())
                .foregroundStyle(Theme.ink)
            Text("\(manager.tabs.count)件")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
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
    let previewAspect: CGFloat
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
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
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
        // Preview window follows the container's orientation (4:3
        // landscape / 3:4 portrait, decided by the parent grid); the
        // image fills it and is clipped (no letterboxing).
        .aspectRatio(previewAspect, contentMode: .fit)
        .clipped()
    }
}

// MARK: - Card drag-reorder (v0.4.10)

/// Per-card drop target. The reorder happens LIVE in dropEntered —
/// as the dragged card crosses a target, the model moves the dragged
/// tab to the target's slot and the grid animates the other cards
/// out of the way, so the insertion point is always visible. The
/// indices are recomputed inside the MainActor hop at execution
/// time (never captured at event time), so a burst of dropEntered
/// events from a fast drag still converges on the pointer's card.
/// iOS's drag interaction itself starts on long-press, which is
/// what keeps plain taps (select) and the × button unaffected.
private struct TabReorderDropDelegate: DropDelegate {
    let target: BrowserTab
    let manager: BrowserModel
    @Binding var draggingID: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != target.id else { return }
        let targetID = target.id
        Task { @MainActor in
            guard let from = manager.tabs.firstIndex(where: { $0.id == dragging }),
                  let to = manager.tabs.firstIndex(where: { $0.id == targetID }),
                  from != to else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                manager.moveTab(fromIndex: from, toIndex: to)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

/// Catch-all for drops that land on the grid's gaps rather than on
/// a card: just end the drag state cleanly.
private struct TabGridCatchAllDropDelegate: DropDelegate {
    @Binding var draggingID: UUID?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

private extension View {
    /// Attaches drag-reorder only when `enabled` (i.e. the grid is
    /// not being search-filtered). A disabled card is a plain card:
    /// tap selects, × closes, exactly as before.
    @ViewBuilder
    func tabReorderDragDrop(enabled: Bool,
                            tab: BrowserTab,
                            manager: BrowserModel,
                            draggingID: Binding<UUID?>) -> some View {
        if enabled {
            self
                .onDrag {
                    draggingID.wrappedValue = tab.id
                    return NSItemProvider(object: tab.id.uuidString as NSString)
                }
                .onDrop(of: [.text],
                        delegate: TabReorderDropDelegate(target: tab,
                                                         manager: manager,
                                                         draggingID: draggingID))
        } else {
            self
        }
    }
}
