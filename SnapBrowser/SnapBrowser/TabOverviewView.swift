import SwiftUI
import UniformTypeIdentifiers

/// Tab overview, modelled on Brave's iPad tab page (layout and
/// interaction only — no Brave assets or naming): a ⋯ menu and a
/// search pill in the header, a grid of cards, and a bottom bar
/// with a round ＋ (new tab), a 「N タブ / プライベート」 tray
/// switch in the middle, and a round ✓ to close. Normal and
/// private tabs live in SEPARATE trays (v0.4.11) instead of one
/// mixed grid with eye-off badges. The ⋯ menu carries 履歴,
/// 閉じたタブを開く, タブを選択 (multi-select mode) and
/// すべてのタブを閉じる for the current tray. In multi-select
/// mode cards grow check badges, taps toggle selection instead of
/// switching, drag-reorder is off, and the bottom bar becomes the
/// selection actions. The grid/list view toggle from Brave's
/// header was deliberately NOT ported (see BUILD_LOG 第20次）.
///
/// Column count (kept from v0.4.5): decided explicitly from the
/// container width — never `GridItem(.adaptive)`, which collapsed
/// to one stretched full-width column in the user's ~380pt
/// floating window (two adaptive columns need 2×170 + 16 spacing
/// + 32 padding = a ≥388pt window; his was just under).
///
/// Card containment (v0.4.11, the 「広がってる」 fix): up to
/// v0.4.10 a card's size was negotiated — the preview ZStack used
/// `frame(maxWidth: .infinity)` + `aspectRatio(.fit)` around a
/// `scaledToFill` image whose ideal size is the full-window
/// capture, and the system `.onDrag` preview rasterised the card
/// at whatever size that negotiation produced. A card could
/// therefore paint wider than its grid cell, over its neighbour,
/// with the drag preview's × floating beside the real one (the
/// user's photo: the active card lying on top of the video tab's
/// card). Now the parent computes the cell width arithmetically
/// from the container and every card is HARD-framed to it (width
/// on the card, width×height on the preview, clipped), and the
/// drag uses a custom preview that is the same hard-framed card —
/// a card physically cannot exceed its cell in any state.
///
/// All metrics derive from the GeometryReader's container size —
/// v0.4 removed every UIScreen-based measurement after the
/// carousel broke inside iPad floating windows. The header keeps
/// its explicit top inset because a fullScreenCover's safe area
/// does not clear the iPadOS window buttons (traffic lights).
struct TabOverviewView: View {
    @ObservedObject var manager: BrowserModel
    @Environment(\.dismiss) private var dismiss

    /// Which tray the grid shows. The overview opens on the tray
    /// the ACTIVE tab belongs to.
    private enum Segment {
        case normal
        case `private`
    }
    @State private var segment: Segment
    /// Tab search: filters the current tray by title / URL,
    /// case-insensitive substring — same rule as the other searches.
    @State private var query = ""
    /// Multi-select mode (v0.4.11): card taps toggle membership in
    /// `selectedIDs`; the × buttons hide; drag-reorder is off.
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showHistory = false
    @State private var showCloseAllConfirm = false
    /// Card drag-reorder: the tab currently being dragged, for the
    /// dimmed-source-card effect and the drop delegates.
    @State private var draggingTabID: UUID?

    init(manager: BrowserModel) {
        _manager = ObservedObject(wrappedValue: manager)
        _segment = State(initialValue: manager.activeTab.isPrivate ? .private : .normal)
    }

    private var normalTabs: [BrowserTab] { manager.tabs.filter { !$0.isPrivate } }
    private var privateTabs: [BrowserTab] { manager.tabs.filter { $0.isPrivate } }
    private var segmentTabs: [BrowserTab] {
        segment == .private ? privateTabs : normalTabs
    }

    /// Reorder is only offered on the full, unfiltered list in
    /// normal mode: reordering a filtered subset — or a selection —
    /// would move cards the user can't see and scramble the order.
    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleTabs: [BrowserTab] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return segmentTabs }
        return segmentTabs.filter { tab in
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
            let columnCount = Self.columnCount(forWidth: container.width)
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 16),
                count: columnCount)
            // The cell width, computed — not negotiated. Every card
            // is framed to exactly this (see the header comment).
            let cardWidth = (container.width - 32 - 16 * CGFloat(columnCount - 1))
                / CGFloat(columnCount)
            // Preview aspect follows the container like Brave's /
            // Chrome's grids: portrait windows get portrait (3:4)
            // cards, landscape windows get wide (4:3) cards.
            // Previews are captured at the window's real size, so
            // matching the frame to the container's orientation also
            // reduces cropping.
            let previewAspect: CGFloat = container.height > container.width
                ? 3.0 / 4.0 : 4.0 / 3.0

            VStack(spacing: 0) {
                header
                ScrollView {
                    if visibleTabs.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(visibleTabs) { tab in
                            card(for: tab, cardWidth: cardWidth, previewAspect: previewAspect)
                        }
                    }
                    .padding(16)
                    // Drops that land on grid gaps (not on a card)
                    // still end the drag cleanly.
                    .onDrop(of: [.text],
                            delegate: TabGridCatchAllDropDelegate(draggingID: $draggingTabID))
                }
                if selecting {
                    selectionBar
                } else {
                    bottomBar
                }
            }
            .frame(width: container.width, height: container.height)
        }
        .background(Theme.paper)
        .onAppear {
            draggingTabID = nil
            manager.captureAllPreviews()
        }
        .onChange(of: query) { _ in draggingTabID = nil }
        .onChange(of: segment) { _ in
            // A selection belongs to one tray; switching trays ends
            // selection mode rather than carrying invisible picks.
            selecting = false
            selectedIDs = []
            draggingTabID = nil
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(store: manager.history,
                        onOpen: { url in
                            showHistory = false
                            manager.openInActiveTab(url)
                            dismiss()
                        })
        }
        .confirmationDialog("このトレイのタブをすべて閉じますか？",
                            isPresented: $showCloseAllConfirm,
                            titleVisibility: .visible) {
            Button("すべてのタブを閉じる", role: .destructive) { closeAllInSegment() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(segment == .private
                 ? "プライベートタブがすべて閉じられます。"
                 : "通常タブがすべて閉じられます。")
        }
    }

    // MARK: Header (Brave-style: ⋯ menu + search pill)

    /// The top inset clears the iPadOS window buttons that overlay
    /// a fullScreenCover's top-left corner (v0.3's header collided
    /// with them in floating windows).
    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    showHistory = true
                } label: {
                    Label("履歴", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    manager.restoreClosedTab()
                    dismiss()
                } label: {
                    Label("閉じたタブを開く", systemImage: "arrow.uturn.backward")
                }
                .disabled(manager.closedTabs.isEmpty)
                Button {
                    selecting = true
                } label: {
                    Label("タブを選択", systemImage: "checkmark.circle")
                }
                .disabled(selecting)
                Divider()
                Button(role: .destructive) {
                    showCloseAllConfirm = true
                } label: {
                    Label("すべてのタブを閉じる", systemImage: "xmark.bin")
                }
                .disabled(segmentTabs.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.bold())
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            searchField
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 10)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider() }
    }

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
    }

    private var emptyState: some View {
        Group {
            if isSearching {
                Text("「\(query)」に一致するタブがありません")
            } else if segment == .private {
                Text("プライベートタブはまだありません")
            } else {
                Text("タブがありません")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    // MARK: Cards

    /// One grid card, with drag-reorder attached only in normal
    /// mode on the unfiltered tray. The drag carries a CUSTOM
    /// preview — the same hard-framed card — because the default
    /// preview rasterises the source view at its own negotiated
    /// size, which is how an oversized card image came to float
    /// over the neighbouring card in the user's photo.
    @ViewBuilder
    private func card(for tab: BrowserTab, cardWidth: CGFloat, previewAspect: CGFloat) -> some View {
        let card = TabCard(tab: tab,
                           isActive: tab.id == manager.activeTabID,
                           cardWidth: cardWidth,
                           previewAspect: previewAspect,
                           selecting: selecting,
                           isSelected: selectedIDs.contains(tab.id),
                           onSelect: { handleCardTap(tab) },
                           onClose: { manager.closeTab(tab) })
        if selecting || isSearching {
            card
        } else {
            card
                // The dragged card dims; the OTHER cards slide aside
                // live as the drag crosses them (the drop delegate
                // reorders the model mid-drag), which is the
                // insertion feedback.
                .opacity(draggingTabID == tab.id ? 0.35 : 1)
                .onDrag {
                    draggingTabID = tab.id
                    return NSItemProvider(object: tab.id.uuidString as NSString)
                } preview: {
                    TabCard(tab: tab,
                            isActive: tab.id == manager.activeTabID,
                            cardWidth: cardWidth,
                            previewAspect: previewAspect,
                            selecting: false,
                            isSelected: false,
                            onSelect: {},
                            onClose: {})
                }
                .onDrop(of: [.text],
                        delegate: TabReorderDropDelegate(target: tab,
                                                         manager: manager,
                                                         draggingID: $draggingTabID))
        }
    }

    private func handleCardTap(_ tab: BrowserTab) {
        if selecting {
            if selectedIDs.contains(tab.id) {
                selectedIDs.remove(tab.id)
            } else {
                selectedIDs.insert(tab.id)
            }
        } else {
            manager.selectTab(tab)
            dismiss()
        }
    }

    // MARK: Bottom bar (Brave-style: round ＋ left, tray switch centre, round ✓ right)

    /// The round buttons are a deliberate, single-screen exception
    /// to the app's no-floating-buttons rule — Brave's tab page has
    /// them, the user asked for Brave's structure, and they live in
    /// this flush bottom bar rather than floating over content.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                if segment == .private {
                    manager.newPrivateTab()
                } else {
                    manager.newTab()
                }
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
            Spacer()
            Picker("タブの種類", selection: $segment) {
                Text("\(normalTabs.count) タブ").tag(Segment.normal)
                Text("プライベート \(privateTabs.count)").tag(Segment.private)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "checkmark")
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

    // MARK: Selection-mode bottom bar

    private var selectionBar: some View {
        HStack(spacing: 8) {
            Button("キャンセル") { exitSelection() }
                .font(.body)
                .foregroundStyle(Theme.ink)
                .frame(height: 44)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            Spacer()
            Button {
                closeSelected()
            } label: {
                Text(selectedIDs.isEmpty
                     ? "選択したタブを閉じる"
                     : "選択したタブを閉じる（\(selectedIDs.count)件）")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(selectedIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedIDs.isEmpty)
            .frame(height: 44)
            .contentShape(Rectangle())
            Button("すべて閉じる") { showCloseAllConfirm = true }
                .font(.body)
                .foregroundStyle(Color.red)
                .frame(height: 44)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .disabled(segmentTabs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
    }

    private func exitSelection() {
        selecting = false
        selectedIDs = []
    }

    private func closeSelected() {
        let targets = manager.tabs.filter { selectedIDs.contains($0.id) }
        for tab in targets { manager.closeTab(tab) }
        exitSelection()
        settleSegmentAfterClose()
    }

    private func closeAllInSegment() {
        manager.closeTabs(isPrivate: segment == .private)
        exitSelection()
        settleSegmentAfterClose()
    }

    /// After a bulk close the current tray may be empty while the
    /// other still has tabs (or holds the fresh start tab created
    /// when everything closed) — follow the content instead of
    /// staring at an empty tray.
    private func settleSegmentAfterClose() {
        if segmentTabs.isEmpty {
            segment = (segment == .private) ? .normal : .private
        }
    }
}

private struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let isActive: Bool
    /// The grid cell's width, computed by the parent. The card and
    /// its preview are framed to it EXACTLY (v0.4.11 containment
    /// fix) — no ideal-size negotiation anywhere in the card.
    let cardWidth: CGFloat
    let previewAspect: CGFloat
    /// Multi-select mode: the × hides and a check badge shows.
    let selecting: Bool
    let isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            cardHeader
            preview
        }
        .frame(width: cardWidth)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isActive ? Theme.cobalt : Theme.hairline,
                              lineWidth: isActive ? 2.5 : 0.5)
        )
        .overlay {
            if selecting && isSelected {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.cobalt.opacity(0.10))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if selecting {
                selectionBadge
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { onSelect() }
    }

    private var selectionBadge: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Theme.cobalt : Color.white.opacity(0.9))
                .frame(width: 24, height: 24)
                .overlay(
                    Circle().strokeBorder(isSelected ? Theme.cobalt : Theme.hairline,
                                          lineWidth: 1)
                )
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
            }
        }
        .padding(.top, 10)
        .padding(.trailing, 10)
        .allowsHitTesting(false)
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
            if !selecting {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
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
        // Hard frame (v0.4.11): exactly the cell width and the
        // height the aspect rule gives it. The image fills and is
        // clipped INSIDE this frame — it can no longer negotiate a
        // size of its own and paint over the neighbouring card.
        .frame(width: cardWidth, height: cardWidth / previewAspect)
        .clipped()
    }
}

// MARK: - Card drag-reorder

/// Per-card drop target. The reorder happens LIVE in dropEntered —
/// as the dragged card crosses a target, the model moves the dragged
/// tab to the target's slot and the grid animates the other cards
/// out of the way, so the insertion point is always visible. The
/// indices are recomputed inside the MainActor hop at execution
/// time (never captured at event time), so a burst of dropEntered
/// events from a fast drag still converges on the pointer's card.
/// iOS's drag interaction itself starts on long-press, which is
/// what keeps plain taps (select) and the × button unaffected.
/// With the segmented trays (v0.4.11) the indices are the model's
/// global ones: moving the dragged tab to the target's global slot
/// changes the two tabs' relative order inside their tray exactly
/// as the grid shows it.
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
