import SwiftUI

/// ⌘K command palette. Substring-search across EVERY page — post URLs,
/// text/sticky contents, file names, section titles, plus each card's
/// name, note and tags. Selecting a result switches to that card's page,
/// selects it, and centres the camera on it. (`searchSummary`/`searchIcon`/
/// `searchHaystack` live in NodeSearch.swift, shared with the Outline list.)
struct SearchPalette: View {
    @EnvironmentObject var state: CanvasState

    @State private var query: String = ""
    @State private var highlighted: Int = 0
    @FocusState private var queryFocused: Bool

    /// Cap so a broad query can't build an unbounded list.
    private let maxResults = 50

    private var results: [SearchResult] {
        guard !query.isEmpty else { return [] }
        let needle = query.lowercased()
        var out: [SearchResult] = []
        for page in state.pages {
            for node in page.nodes where node.searchHaystack.lowercased().contains(needle) {
                out.append(SearchResult(
                    nodeID: node.id,
                    pageID: page.id,
                    pageName: page.name,
                    icon: node.searchIcon,
                    title: node.searchSummary
                ))
                if out.count >= maxResults { return out }
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search posts, text, files, tags…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit { activateHighlighted() }
                    .font(.clip(13.5))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.hover)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if results.isEmpty {
                Text(query.isEmpty
                     ? "Type to search every page."
                     : "No matches.")
                    .font(.clip(12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, r in
                            resultRow(result: r, isHighlighted: idx == highlighted)
                                .contentShape(Rectangle())
                                .onTapGesture { jump(to: r) }
                                .onHover { hovering in
                                    if hovering { highlighted = idx }
                                }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 8)
        .onAppear {
            queryFocused = true
            highlighted = 0
        }
        .onChange(of: query) { _ in highlighted = 0 }
        .onExitCommand { state.isSearchPresented = false }
    }

    @ViewBuilder
    private func resultRow(result: SearchResult, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(result.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.clip(12.5))
            Spacer(minLength: 8)
            Text(result.pageName)
                .font(.clip(10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(nsColor: .separatorColor).opacity(0.25),
                            in: Capsule(style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            isHighlighted
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
    }

    private func activateHighlighted() {
        guard !results.isEmpty,
              highlighted >= 0,
              highlighted < results.count else { return }
        jump(to: results[highlighted])
    }

    private func jump(to result: SearchResult) {
        state.isSearchPresented = false
        state.jumpToNode(result.nodeID, onPage: result.pageID)
    }
}

private struct SearchResult: Identifiable {
    let id = UUID()
    let nodeID: UUID
    let pageID: UUID
    let pageName: String
    let icon: String
    let title: String
}
