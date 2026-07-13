import SwiftUI
import AppKit

/// Left-column sidebar listing every page in the document — rebuilt 1:1 from
/// Figma node 74:25948 (`sidebar-panel`).
///
/// Visual spec (from Figma, forced light mode):
///   • Panel: fill `#F4F8F9`, 1pt border `rgba(0,0,0,0.16)`, top-right +
///     bottom-right corners rounded 20pt, drop shadow `4 0 / blur 15 /
///     rgba(0,0,0,0.12)`, natural width 200pt.
///   • Header row near the top: "PAGES" label (SF Mono Medium 11, UPPERCASE,
///     `rgba(0,0,0,0.85)`) on the left + a 16×16 "+" add-page button on the
///     right.
///   • Page rows: 180×24, 8pt corner radius, inner padding L8/R4/V4, gap 6.
///     Label SF Mono Medium 11, UPPERCASE, `rgba(0,0,0,0.85)`. Row pitch 28
///     (24 height + 4 gap). Selected row carries a `rgba(0,0,0,0.05)` wash.
///   • Bottom-left floating "i" button: 36pt circle, `rgba(255,255,255,0.6)`,
///     fully rounded, soft layered shadow, 24pt info glyph.
///
/// Functional hooks preserved from the previous sidebar: pages list
/// (`state.pages`), selection (`activePageID` / `switchTo`), add (`addPage`),
/// rename (double-click → `renamePage`), pin (`togglePin`), and delete
/// (`requestDeletePage` + the confirmation dialog → `confirmDeletePage`).
struct PagesSidebar: View {
    @EnvironmentObject var state: CanvasState
    @Environment(\.clipTheme) private var theme

    @State private var renamingID: UUID? = nil
    @State private var renameText: String = ""
    @FocusState private var renameFocused: Bool
    @State private var hoveredID: UUID? = nil
    /// Row currently hovered during a page drag — shows the green insertion line.
    @State private var dropTargetID: UUID? = nil
    /// Sidebar width (live), so the rename-dismiss monitor knows where the canvas
    /// begins (a click past this width = outside → commit).
    @State private var sidebarWidth: CGFloat = 200
    /// Local mouse monitor installed while renaming, to commit when the user
    /// clicks out onto the canvas (SwiftUI focus doesn't drop on an AppKit-canvas
    /// click, so `renameFocused` alone never fires).
    @State private var renameClickMonitor: Any? = nil

    // MARK: Figma tokens

    /// Panel surface fill (`#F4F8F9`) — a distinct Figma-specified panel tint,
    /// not close enough to any `clipTheme` surface tier to route through one.
    private let panelFill   = Color(red: 0.957, green: 0.973, blue: 0.976)
    /// Panel hairline border — routed through the shared theme token (was a
    /// hand-rolled `Color.black.opacity(0.16)` that drifted from `theme.border`).
    private var panelBorder: Color { theme.border }
    /// Primary text — routed through the shared theme token (was a hand-rolled
    /// `Color.black.opacity(0.85)` duplicating `theme.textPrimary`).
    private var labelColor: Color { theme.textPrimary }
    /// Hover + selected row wash — green `#208F08` @ 10%, multiply (Figma 74:25952
    /// hover / 74:25949 selected use the identical wash).
    private let rowWash = Color(red: 32 / 255, green: 143 / 255, blue: 8 / 255).opacity(0.10)
    /// Renaming-row border + text-selection tint — `#3DA726` (Figma 88:342).
    private let accentGreen = Color(red: 61 / 255, green: 167 / 255, blue: 38 / 255)

    private let panelCorner: CGFloat = 20
    private let rowHeight: CGFloat   = 24
    private let rowCorner: CGFloat   = 8
    private let rowGap: CGFloat      = 4      // vertical gap between rows
    private let sideInset: CGFloat   = 10     // page-list-item left/right inset

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Page list (scrolls) — header pinned, rows below.
            VStack(alignment: .leading, spacing: 0) {
                header
                    // Header label baseline sits at y≈60 (top 52, h16); the
                    // "+" aligns to it. Match Figma's top inset.
                    .padding(.top, 52)
                    .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: rowGap) {
                        ForEach(state.pages) { page in
                            reorderable(row(for: page), page: page)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, sideInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Bottom-left floating info button (Figma 74:25958), 18pt in
            // from the left, 18pt up from the bottom.
            VStack {
                Spacer()
                HStack {
                    infoButton
                    Spacer()
                }
            }
            .padding(.leading, 18)
            .padding(.bottom, 18)
        }
        // Paint the Figma panel chrome and suppress the column's default
        // sidebar material so the exact fill / border / rounded-right edge /
        // shadow show through.
        .background(panelBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        // Track the live sidebar width so the rename-dismiss monitor knows where
        // the canvas begins.
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { sidebarWidth = g.size.width }
                    .onChange(of: g.size.width) { sidebarWidth = $0 }
            }
        )
        // Deleting a page destroys every card on it — confirm before the
        // (undoable) removal in `confirmDeletePage()`.
        .confirmationDialog(
            "Delete “\(state.pageAwaitingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { state.pageAwaitingDeletion != nil },
                set: { if !$0 { state.pageAwaitingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Page", role: .destructive) { state.confirmDeletePage() }
            Button("Cancel", role: .cancel) { state.pageAwaitingDeletion = nil }
        } message: {
            Text("All cards on this page will be deleted. You can undo with ⌘Z.")
        }
    }

    // MARK: - Panel chrome

    /// The `#F4F8F9` panel with right-only rounded corners, hairline border,
    /// and the rightward drop shadow — drawn behind the column to override the
    /// system sidebar material.
    private var panelBackground: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: panelCorner,
            topTrailingRadius: panelCorner,
            style: .continuous
        )
        // The panel now lays out directly (HStack with a higher zIndex), so its
        // real rightward drop shadow spills over the canvas — Figma `4 0 / blur 15`.
        return shape
            .fill(panelFill)
            .overlay(shape.strokeBorder(panelBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 7.5, x: 4, y: 0)
    }

    // MARK: - Header (PAGES + add)

    private var header: some View {
        HStack(spacing: 6) {
            Text("PAGES")
                .clipLabel(11)
                .foregroundStyle(labelColor)
                // Figma offsets the label 8pt further in than the row inset
                // (label x=18 vs panel; rows x=10). Nudge to match.
                .padding(.leading, 8)

            Spacer(minLength: 8)

            Button {
                state.addPage()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(labelColor)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            .help("New page")
            .accessibilityLabel("New page")
            .accessibilityIdentifier("sidebar.addPage")
            // Row inset is 10; Figma puts the "+" right edge at x=186 → 14pt
            // from the panel's right at width 200. Align its trailing edge.
            .padding(.trailing, 4)
        }
    }

    // MARK: - Page row

    @ViewBuilder
    private func row(for page: Page) -> some View {
        let isSelected = page.id == state.activePageID
        // Hover and selected share the same green wash (Figma); renaming adds it too.
        let washed = isSelected || hoveredID == page.id || renamingID == page.id

        HStack(spacing: 6) {
            if renamingID == page.id {
                // Raw-case buffer underneath (transparent text, owns the caret +
                // the actual committed value) + an uppercase-for-DISPLAY-only
                // overlay on top — `.textCase(.uppercase)` doesn't transform an
                // editable field's input, so mutating the buffer itself was the
                // old approach, but that bakes the uppercase string into the
                // model on any no-retype commit. Same pattern as `LinkInputBar`
                // and `FolderGridView.FolderNameField`.
                ZStack(alignment: .leading) {
                    Text(renameText.uppercased())
                        .clipLabel(11)
                        .foregroundStyle(labelColor)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                    TextField("Page name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.clip(11))
                        .foregroundStyle(.clear)
                        .tint(accentGreen)          // green caret + selection (Figma 88:342)
                        .focused($renameFocused)
                        .onAppear {
                            renameText = page.name   // raw case — overlay displays it uppercased
                            renameFocused = true
                        }
                        .onSubmit { commitRename(for: page.id) }
                        .onExitCommand { cancelRename() }
                        .onChange(of: renameFocused) { focused in
                            if !focused { commitRename(for: page.id) }
                        }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(page.name)
                    .clipLabel(11)
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(page.name)
            }

            if page.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(labelColor.opacity(0.5))
                    .help("Pinned")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: rowCorner, style: .continuous)
                .fill(washed ? rowWash : .clear)
                .blendMode(washed ? .multiply : .normal)
        )
        .overlay(
            renamingID == page.id
                ? RoundedRectangle(cornerRadius: rowCorner, style: .continuous)
                    .strokeBorder(accentGreen, lineWidth: 1)
                : nil
        )
        .contentShape(RoundedRectangle(cornerRadius: rowCorner, style: .continuous))
        .onHover { inside in
            if inside { hoveredID = page.id }
            else if hoveredID == page.id { hoveredID = nil }
        }
        .onTapGesture(count: 2) {
            beginRename(page)
        }
        .onTapGesture {
            // Clicking another page while renaming commits the edit first.
            if let editing = renamingID, editing != page.id { commitRename(for: editing) }
            if renamingID != page.id { state.switchTo(pageID: page.id) }
        }
        .contextMenu {
            Button("Rename") { beginRename(page) }
            Button(page.pinned ? "Unpin" : "Pin") { state.togglePin(page.id) }
            if state.pages.count > 1 {
                Divider()
                Button("Delete", role: .destructive) {
                    state.requestDeletePage(page.id)
                }
            }
        }
    }

    /// Drag-reorder wrapper applied to each row at the ForEach site (kept separate
    /// so the row's own long modifier chain stays type-checkable).
    @ViewBuilder
    private func reorderable(_ content: some View, page: Page) -> some View {
        content
            .overlay(alignment: .top) {
                if dropTargetID == page.id {
                    Rectangle().fill(accentGreen).frame(height: 2)
                        .offset(y: -(rowGap / 2 + 1))
                }
            }
            .draggable(page.id.uuidString) {
                Text(page.name)
                    .clipLabel(11)
                    .foregroundStyle(labelColor)
                    .padding(.horizontal, 8)
                    .frame(height: rowHeight)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let s = items.first, let dragged = UUID(uuidString: s) else { return false }
                state.movePage(dragged, before: page.id)
                dropTargetID = nil
                return true
            } isTargeted: { over in
                dropTargetID = over ? page.id : (dropTargetID == page.id ? nil : dropTargetID)
            }
    }

    // MARK: - Bottom info button

    private var infoButton: some View {
        Button {
            state.isInboxGuidePresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(labelColor)
                .frame(width: 28, height: 28)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.6))
                        .figmaPillShadow()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.hover)
        .help("How CLIP works")
        .accessibilityLabel("Info")
        .accessibilityIdentifier("sidebar.info")
    }

    // MARK: - Rename helpers

    private func beginRename(_ page: Page) {
        renameText = page.name   // raw case — the row overlay displays it uppercased
        renamingID = page.id
        renameFocused = true
        installRenameDismissMonitor()
    }

    private func commitRename(for id: UUID) {
        guard renamingID == id else { return }   // ignore stale/duplicate commits
        let value = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingID = nil
        removeRenameDismissMonitor()
        // Skip the no-op case (opened + closed without an actual edit) so it
        // doesn't create an undo entry downstream.
        guard let page = state.pages.first(where: { $0.id == id }), value != page.name else { return }
        state.renamePage(id, to: value)
    }

    private func cancelRename() {
        renamingID = nil
        removeRenameDismissMonitor()
    }

    /// A click on the canvas doesn't drop SwiftUI focus from the rename field, so
    /// `renameFocused` never flips — leaving the row stuck in edit mode. While
    /// renaming, watch for a mouse-down past the sidebar's right edge (= on the
    /// canvas) and commit then.
    private func installRenameDismissMonitor() {
        removeRenameDismissMonitor()
        renameClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            if event.locationInWindow.x > sidebarWidth, let id = renamingID {
                DispatchQueue.main.async { commitRename(for: id) }
            }
            return event
        }
    }

    private func removeRenameDismissMonitor() {
        if let m = renameClickMonitor { NSEvent.removeMonitor(m); renameClickMonitor = nil }
    }
}
