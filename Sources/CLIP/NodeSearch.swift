import Foundation

/// Shared, non-private node→text/icon helpers used by both the ⌘K search
/// palette and the Outline list. One source of truth so a new `Kind`
/// only needs updating here.
extension CanvasNode {
    /// Text used both for filtering and for the displayed row title.
    var searchSummary: String {
        switch kind {
        case .tweet(let url):           return url
        case .instagram(let url):       return url
        case .youtube(let url):         return url
        case .webclip(let url):         return url
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
        case .webclip:    return "globe"
        case .text:       return "textformat"
        case .drawing:    return "pencil.tip"
        case .image:      return "photo"
        case .video:      return "film"
        case .section:    return "rectangle.dashed"
        case .stickyNote: return "note.text"
        }
    }

    /// Everything a free-text query should match against: the summary plus
    /// the user's own metadata (name, note, tags).
    var searchHaystack: String {
        var parts = [searchSummary]
        if let name, !name.isEmpty { parts.append(name) }
        if let note, !note.isEmpty { parts.append(note) }
        if !tags.isEmpty { parts.append(tags.joined(separator: " ")) }
        return parts.joined(separator: " ")
    }
}
