import SwiftUI

/// ⌘K command palette. Substring-search across the *active page* — tweet
/// URLs, Instagram URLs, text-node contents, and image/video filenames.
/// Selecting a result selects that node and centres the camera on it.
struct SearchPalette: View {
    @EnvironmentObject var state: CanvasState

    @State private var query: String = ""
    @State private var highlighted: Int = 0
    @FocusState private var queryFocused: Bool

    private var results: [SearchResult] {
        guard !query.isEmpty else { return [] }
        let needle = query.lowercased()
        return state.nodes.compactMap { node in
            let summary = node.searchSummary
            if summary.lowercased().contains(needle) {
                return SearchResult(
                    nodeID: node.id,
                    icon: node.searchIcon,
                    title: summary
                )
            }
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search posts, text, files…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit { activateHighlighted() }
                    .font(.system(size: 14))
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
                     ? "Type to search the current page."
                     : "No matches on this page.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, r in
                            resultRow(result: r, isHighlighted: idx == highlighted)
                                .contentShape(Rectangle())
                                .onTapGesture { jump(to: r.nodeID) }
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
                .font(.callout)
            Spacer()
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
        jump(to: results[highlighted].nodeID)
    }

    private func jump(to nodeID: UUID) {
        guard let n = state.nodeByID[nodeID] else { return }
        let centre = CGPoint(
            x: n.position.x + n.width / 2,
            y: n.position.y + state.renderedHeight(of: n) / 2
        )
        state.centerCamera(on: centre)
        state.select(nodeID)
        state.isSearchPresented = false
    }
}

private struct SearchResult: Identifiable {
    let id = UUID()
    let nodeID: UUID
    let icon: String
    let title: String
}

private extension CanvasNode {
    /// Text used both for filtering and for the displayed row title.
    var searchSummary: String {
        switch kind {
        case .tweet(let url):           return url
        case .instagram(let url):       return url
        case .youtube(let url):         return url
        case .text(let content, _):
            return content.isEmpty ? "(empty text)" : content
        case .drawing:                  return "Drawing"
        case .image(_, let filename):   return filename
        case .video(_, let filename):   return filename
        case .section(let title, _):
            return title.isEmpty ? "(untitled section)" : title
        case .stickyNote(let content, _):
            return content.isEmpty ? "(empty sticky)" : content
        }
    }

    var searchIcon: String {
        switch kind {
        case .tweet:      return "bird"
        case .instagram:  return "camera"
        case .youtube:    return "play.rectangle"
        case .text:       return "textformat"
        case .drawing:    return "pencil.tip"
        case .image:      return "photo"
        case .video:      return "film"
        case .section:    return "rectangle.dashed"
        case .stickyNote: return "note.text"
        }
    }
}
