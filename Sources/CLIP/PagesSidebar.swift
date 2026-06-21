import SwiftUI

/// Left-column sidebar listing every page in the document. Click a row to
/// switch pages, double-click to rename, right-click for Delete.
struct PagesSidebar: View {
    @EnvironmentObject var state: CanvasState

    @State private var renamingID: UUID? = nil
    @State private var renameText: String = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Canvas / Colorform tab strip — top of the sidebar, Claude-style.
            CanvasModeSwitcher()
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

            List(selection: Binding<UUID?>(
                get: { state.activePageID },
                set: { newID in
                    if let id = newID { state.switchTo(pageID: id) }
                }
            )) {
                Section("Pages") {
                    ForEach(state.pages) { page in
                        row(for: page)
                            .tag(page.id)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 6) {
                Button {
                    state.addPage()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.hover)
                .help("New page")
                .accessibilityLabel("New page")
                .accessibilityIdentifier("sidebar.addPage")

                Text("\(state.pages.count) page\(state.pages.count == 1 ? "" : "s")")
                    .clipLabel(9, tracking: 1.0)
                    .foregroundStyle(.tertiary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
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

    private func leadingIcon(for page: Page) -> String {
        page.name == CanvasState.incomingPageName ? "iphone" : "doc"
    }

    @ViewBuilder
    private func row(for page: Page) -> some View {
        HStack(spacing: 6) {
            Image(systemName: leadingIcon(for: page))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if renamingID == page.id {
                TextField("Page name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onAppear {
                        renameText = page.name
                        renameFocused = true
                    }
                    .onSubmit { commitRename(for: page.id) }
                    .onExitCommand { cancelRename() }
                    .onChange(of: renameFocused) { focused in
                        if !focused { commitRename(for: page.id) }
                    }
            } else {
                Text(page.name)
                    .clipText(12)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if page.pinned {
                Spacer(minLength: 4)
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("Pinned")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            beginRename(page)
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

    private func beginRename(_ page: Page) {
        renameText = page.name
        renamingID = page.id
        renameFocused = true
    }

    private func commitRename(for id: UUID) {
        let value = renameText
        renamingID = nil
        state.renamePage(id, to: value)
    }

    private func cancelRename() {
        renamingID = nil
    }
}
