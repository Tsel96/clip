import SwiftUI

/// Flat "layer list" of every card across all pages, grouped by page.
/// Clicking a row reveals that card (switching pages if needed). Shares
/// the `searchIcon`/`searchSummary` helpers (NodeSearch.swift) with ⌘K.
struct OutlinePanel: View {
    @EnvironmentObject var state: CanvasState

    var body: some View {
        List {
            ForEach(state.pages) { page in
                Section(page.name) {
                    if page.nodes.isEmpty {
                        Text("Empty")
                            .clipText(11)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(page.nodes) { node in
                            row(node: node, pageID: page.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func row(node: CanvasNode, pageID: UUID) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.searchIcon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(node.searchSummary)
                .clipText(12)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.jumpToNode(node.id, onPage: pageID) }
    }
}
