import SwiftUI
import AppKit

/// Archive mode, rebuilt as a chronological list — every card you've
/// added, newest first, grouped by day, each row showing what it is and
/// the exact time it landed.
///
/// Rationale (UX audit): the calendar-heatmap → bento → lightbox stack
/// encoded "when" as cell lightness and hid "what" behind two drill
/// levels, never showing time of day at all. A list answers "what did I
/// add and when" in zero clicks: day headers, per-row timestamps, real
/// titles and thumbnails. Click a row to jump to that card on the canvas.
struct ArchiveListView: View {
    @EnvironmentObject var state: CanvasState
    /// Re-renders rows as image thumbnails finish decoding.
    @ObservedObject private var thumbs = MinimapThumbs.shared

    var body: some View {
        Group {
            if dayGroups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(dayGroups, id: \.day) { group in
                            Section {
                                ForEach(group.nodes) { node in
                                    ArchiveListRow(node: node) { reveal(node) }
                                    if node.id != group.nodes.last?.id {
                                        Divider()
                                            .padding(.leading, 64)
                                            .opacity(0.5)
                                    }
                                }
                            } header: {
                                dayHeader(for: group)
                            }
                        }
                    }
                    .frame(maxWidth: 560)
                    .padding(.top, 16)
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grouping

    private struct DayGroup {
        let day: Date
        let nodes: [CanvasNode]
    }

    /// Cards grouped by local-time day, newest day first, newest card
    /// first within each day. Computed straight from `state.nodes` so the
    /// list is always live — no enter-mode snapshot to go stale.
    private var dayGroups: [DayGroup] {
        let cal = Calendar.current
        var buckets: [Date: [CanvasNode]] = [:]
        for node in state.nodes where !node.isSection {
            buckets[cal.startOfDay(for: node.addedAt), default: []].append(node)
        }
        return buckets
            .map { day, nodes in
                DayGroup(day: day, nodes: nodes.sorted { $0.addedAt > $1.addedAt })
            }
            .sorted { $0.day > $1.day }
    }

    // MARK: - Day header

    private func dayHeader(for group: DayGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.dayTitle(for: group.day))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text(group.nodes.count == 1 ? "1 card" : "\(group.nodes.count) cards")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Solid-ish backing so rows scrolling beneath the pinned header
        // never bleed through the text.
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    static func dayTitle(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateFormat = cal.isDate(day, equalTo: Date(), toGranularity: .year)
            ? "EEEE, MMM d"
            : "EEEE, MMM d, yyyy"
        return fmt.string(from: day)
    }

    // MARK: - Row action

    /// Jump out of Archive and frame the canvas on this card — same path
    /// the old lightbox's "Open in Canvas" used.
    private func reveal(_ node: CanvasNode) {
        state.setMode(.canvas)
        state.select(node.id)
        let rect = CGRect(
            x: node.position.x, y: node.position.y,
            width: node.width, height: state.renderedHeight(of: node)
        )
        state.frameRect(rect, padding: 120)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Your archive is empty")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Cards appear here as you add them, newest first.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Row

private struct ArchiveListRow: View {
    @EnvironmentObject var state: CanvasState
    let node: CanvasNode
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                thumbnail

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(Self.timeFormatter.string(from: node.addedAt))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        )
        .onHover { hovering = $0 }
        .help("Open on canvas")
        .accessibilityLabel("\(title), added \(Self.timeFormatter.string(from: node.addedAt))")
    }

    // MARK: Thumbnail / kind tile

    @ViewBuilder
    private var thumbnail: some View {
        if let img = MinimapThumbs.shared.thumbnail(for: node) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                )
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(kindColor.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: kindSymbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(kindColor)
                )
        }
    }

    // MARK: Per-kind presentation

    private var title: String {
        if let name = node.name, !name.isEmpty { return name }
        switch node.kind {
        case .tweet(let url):       return Self.compactURL(url)
        case .instagram(let url):   return Self.compactURL(url)
        case .youtube(let url):     return Self.compactURL(url)
        case .image(_, let file):   return file
        case .video(_, let file):   return file
        case .text(let content, _),
             .stickyNote(let content, _):
            let line = content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first ?? ""
            return line.isEmpty ? "Empty note" : line
        case .drawing:              return "Drawing"
        case .section(let title, _): return title
        }
    }

    private var subtitle: String {
        var parts = [kindLabel]
        if !node.tags.isEmpty { parts.append(node.tags.joined(separator: " · ")) }
        return parts.joined(separator: "  ·  ")
    }

    private var kindLabel: String {
        switch node.kind {
        case .tweet:      return "X / Twitter"
        case .instagram:  return "Instagram"
        case .youtube:    return "YouTube"
        case .image:      return "Image"
        case .video:      return "Video"
        case .text:       return "Text"
        case .stickyNote: return "Sticky note"
        case .drawing:    return "Drawing"
        case .section:    return "Section"
        }
    }

    private var kindSymbol: String {
        switch node.kind {
        case .tweet:      return "bubble.left"
        case .instagram:  return "camera"
        case .youtube:    return "play.rectangle"
        case .image:      return "photo"
        case .video:      return "film"
        case .text:       return "textformat"
        case .stickyNote: return "note.text"
        case .drawing:    return "pencil.tip"
        case .section:    return "rectangle.dashed"
        }
    }

    /// Mirrors the minimap's per-kind palette so the two stay one language.
    private var kindColor: Color {
        switch node.kind {
        case .tweet:      return Color(nsColor: .controlAccentColor)
        case .instagram:  return Color(red: 0.91, green: 0.21, blue: 0.45)
        case .youtube:    return Color(red: 1.0, green: 0.0, blue: 0.0)
        case .image:      return .green
        case .video:      return .orange
        case .text:       return .secondary
        case .stickyNote(_, let color): return color.swiftUIColor
        case .drawing(let s):           return s.color.swiftUIColor
        case .section(_, let color):    return color.swiftUIColor
        }
    }

    /// "x.com/user/status/123…" without scheme/www, trimmed to fit a row.
    private static func compactURL(_ raw: String) -> String {
        var s = raw
        for prefix in ["https://", "http://", "www."] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
