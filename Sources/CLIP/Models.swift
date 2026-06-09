import Foundation
import CoreGraphics
import SwiftUI

// MARK: - Canvas nodes

/// Discriminated union of everything the canvas can render.
struct CanvasNode: Identifiable, Equatable, Codable {
    let id: UUID
    var position: CGPoint
    var width: CGFloat
    /// `nil` means "auto-size from content" (used by tweet & text nodes).
    var height: CGFloat?
    var kind: Kind
    /// When this node was first created on the canvas. Drives the date-
    /// sorted `Archive` view. Old saves missing the field
    /// decode as `Date.distantPast`; `CanvasState` resolves that sentinel
    /// to synthetic ascending dates on load (newer array index = newer
    /// timestamp) so chronology is preserved during migration.
    var addedAt: Date = Date()
    /// If set, this node belongs to a card-stack group (⌘G). The node
    /// with the smallest UUID string within the group is the *head*:
    /// it renders the stacked-cards visual; the other members are
    /// hidden from rendering until ungrouped (⌘⇧G). The members'
    /// `position` fields stay live and are translated in parallel
    /// when the head drags, so ungrouping releases them at the
    /// stack's *current* location, not the original.
    /// Optional + `decodeIfPresent` for backward compatibility with
    /// snapshots saved before this field existed.
    var groupID: UUID? = nil

    /// Where this node came from. `.phone` marks cards ingested from the
    /// iPhone share pipe (the iCloud Drive inbox) so the UI can badge
    /// them. `decodeIfPresent` defaults older snapshots to `.local`.
    var origin: Origin = .local

    enum Origin: String, Codable { case local, phone }

    /// Optional inspector metadata surfaced in the card lightbox's details
    /// panel. All `decodeIfPresent`, so snapshots saved before these
    /// existed migrate cleanly (default `nil`).
    var name: String? = nil
    var note: String? = nil
    var linkURL: String? = nil
    var tags: [String] = []
    var imagePrompt: String? = nil

    /// Non-destructive trim for `.video` cards (seconds into the clip). When
    /// set, the card loops only `[trimStart, trimEnd]`; `nil` = full clip.
    /// `decodeIfPresent`, so older snapshots migrate to the full clip.
    var trimStart: Double? = nil
    var trimEnd: Double? = nil

    enum Kind: Equatable {
        case tweet(url: String)
        case instagram(url: String)
        case youtube(url: String)
        case text(content: String, fontSize: CGFloat)
        case drawing(stroke: DrawingStroke)
        case image(data: Data, filename: String)
        case video(fileURL: URL, filename: String)
        case section(title: String, color: SectionColor)
        case stickyNote(content: String, color: StickyColor)

        /// Floor enforced by both creation (`addSection`, `addStickyNote`)
        /// and resize so a node never collapses below a usable footprint.
        /// Sections are larger than cards because their header bar alone
        /// is 28pt and the body needs room to host content.
        var minSize: CGSize {
            switch self {
            case .section:    return CGSize(width: 160, height: 120)
            case .stickyNote: return CGSize(width: 120, height: 120)
            default:          return CGSize(width: 80, height: 60)
            }
        }
    }

    init(id: UUID = UUID(),
         position: CGPoint,
         width: CGFloat,
         height: CGFloat? = nil,
         kind: Kind,
         addedAt: Date = Date(),
         groupID: UUID? = nil,
         origin: Origin = .local,
         name: String? = nil,
         note: String? = nil,
         linkURL: String? = nil,
         tags: [String] = [],
         imagePrompt: String? = nil,
         trimStart: Double? = nil,
         trimEnd: Double? = nil) {
        self.id = id
        self.position = position
        self.width = width
        self.height = height
        self.kind = kind
        self.addedAt = addedAt
        self.groupID = groupID
        self.origin = origin
        self.name = name
        self.note = note
        self.linkURL = linkURL
        self.tags = tags
        self.imagePrompt = imagePrompt
        self.trimStart = trimStart
        self.trimEnd = trimEnd
    }

    // MARK: - Codable (manual to migrate older snapshots)

    private enum CodingKeys: String, CodingKey {
        case id, position, width, height, kind, addedAt, groupID, origin
        case name, note, linkURL, tags, imagePrompt
        case trimStart, trimEnd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id       = try c.decode(UUID.self,     forKey: .id)
        self.position = try c.decode(CGPoint.self,  forKey: .position)
        self.width    = try c.decode(CGFloat.self,  forKey: .width)
        self.height   = try c.decodeIfPresent(CGFloat.self, forKey: .height)
        self.kind     = try c.decode(Kind.self,     forKey: .kind)
        // Sentinel for "missing — migrate this on load." `CanvasState`
        // walks the loaded snapshot and rewrites distantPast values to
        // synthetic ascending timestamps using the node's array index,
        // so older saves don't all collapse to the same date.
        self.addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? .distantPast
        self.groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        self.origin  = try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .local
        self.name    = try c.decodeIfPresent(String.self, forKey: .name)
        self.note    = try c.decodeIfPresent(String.self, forKey: .note)
        self.linkURL = try c.decodeIfPresent(String.self, forKey: .linkURL)
        self.tags    = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.imagePrompt = try c.decodeIfPresent(String.self, forKey: .imagePrompt)
        self.trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart)
        self.trimEnd   = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,       forKey: .id)
        try c.encode(position, forKey: .position)
        try c.encode(width,    forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encode(kind,     forKey: .kind)
        try c.encode(addedAt,  forKey: .addedAt)
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encode(origin, forKey: .origin)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(linkURL, forKey: .linkURL)
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
        try c.encodeIfPresent(imagePrompt, forKey: .imagePrompt)
        try c.encodeIfPresent(trimStart, forKey: .trimStart)
        try c.encodeIfPresent(trimEnd, forKey: .trimEnd)
    }

    static func tweet(url: String, position: CGPoint, width: CGFloat = 360) -> CanvasNode {
        CanvasNode(position: position, width: width, kind: .tweet(url: url))
    }

    static func youtube(url: String, position: CGPoint, width: CGFloat = 360) -> CanvasNode {
        CanvasNode(position: position, width: width, kind: .youtube(url: url))
    }

    static func instagram(url: String,
                          position: CGPoint,
                          width: CGFloat = 360,
                          height: CGFloat = 540) -> CanvasNode {
        CanvasNode(position: position, width: width, height: height,
                   kind: .instagram(url: url))
    }

    static func image(data: Data,
                      filename: String,
                      position: CGPoint,
                      size: CGSize) -> CanvasNode {
        CanvasNode(position: position,
                   width: size.width, height: size.height,
                   kind: .image(data: data, filename: filename))
    }

    static func video(fileURL: URL,
                      filename: String,
                      position: CGPoint,
                      size: CGSize) -> CanvasNode {
        CanvasNode(position: position,
                   width: size.width, height: size.height,
                   kind: .video(fileURL: fileURL, filename: filename))
    }

    static func text(content: String = "",
                     position: CGPoint,
                     width: CGFloat = 240,
                     fontSize: CGFloat = 16) -> CanvasNode {
        CanvasNode(position: position, width: width,
                   kind: .text(content: content, fontSize: fontSize))
    }

    static func drawing(stroke: DrawingStroke,
                        position: CGPoint,
                        size: CGSize) -> CanvasNode {
        CanvasNode(position: position, width: size.width, height: size.height,
                   kind: .drawing(stroke: stroke))
    }

    static func section(title: String = "",
                        color: SectionColor = .slate,
                        rect: CGRect) -> CanvasNode {
        let min = Kind.section(title: title, color: color).minSize
        return CanvasNode(position: rect.origin,
                          width: max(min.width, rect.width),
                          height: max(min.height, rect.height),
                          kind: .section(title: title, color: color))
    }

    static func stickyNote(content: String = "",
                           color: StickyColor = .yellow,
                           position: CGPoint,
                           size: CGSize = CGSize(width: 200, height: 200)) -> CanvasNode {
        CanvasNode(position: position, width: size.width, height: size.height,
                   kind: .stickyNote(content: content, color: color))
    }

    var renderHeight: CGFloat? { height }

    /// True if this node is a Section (frame). Used by `CanvasView` to
    /// render sections in a back layer so they never occlude cards.
    var isSection: Bool {
        if case .section = kind { return true }
        return false
    }

    /// World rectangle covering this node (position + size at current
    /// width/height). Sections use this for containment hit-testing.
    var worldRect: CGRect {
        CGRect(x: position.x, y: position.y,
               width: width, height: height ?? 0)
    }
}

// MARK: - Palette enums for sections and sticky notes

/// Pastel tints used for section frames. Codable via raw String so the
/// JSON schema stays human-readable.
enum SectionColor: String, Codable, CaseIterable, Hashable {
    case slate, sand, mint, lavender, rose

    /// Soft tint used both for the fill (low alpha) and the border (mid).
    var swiftUIColor: Color {
        switch self {
        case .slate:    return Color(red: 0.45, green: 0.50, blue: 0.58)
        case .sand:     return Color(red: 0.78, green: 0.65, blue: 0.42)
        case .mint:     return Color(red: 0.42, green: 0.72, blue: 0.55)
        case .lavender: return Color(red: 0.62, green: 0.55, blue: 0.78)
        case .rose:     return Color(red: 0.82, green: 0.50, blue: 0.58)
        }
    }

    var label: String {
        switch self {
        case .slate:    return "Slate"
        case .sand:     return "Sand"
        case .mint:     return "Mint"
        case .lavender: return "Lavender"
        case .rose:     return "Rose"
        }
    }
}

/// FigJam-style sticky-note palette.
enum StickyColor: String, Codable, CaseIterable, Hashable {
    case yellow, pink, mint, sky, lavender

    var swiftUIColor: Color {
        switch self {
        case .yellow:   return Color(red: 1.00, green: 0.91, blue: 0.55)
        case .pink:     return Color(red: 1.00, green: 0.78, blue: 0.83)
        case .mint:     return Color(red: 0.74, green: 0.95, blue: 0.83)
        case .sky:      return Color(red: 0.76, green: 0.90, blue: 1.00)
        case .lavender: return Color(red: 0.85, green: 0.80, blue: 1.00)
        }
    }

    /// Slightly darker tint for the "shadow lip" along the bottom edge
    /// — gives the sticky its FigJam-style block feel.
    var shadowLip: Color {
        switch self {
        case .yellow:   return Color(red: 0.93, green: 0.81, blue: 0.41)
        case .pink:     return Color(red: 0.93, green: 0.65, blue: 0.72)
        case .mint:     return Color(red: 0.62, green: 0.85, blue: 0.72)
        case .sky:      return Color(red: 0.60, green: 0.80, blue: 0.95)
        case .lavender: return Color(red: 0.72, green: 0.67, blue: 0.92)
        }
    }

    var label: String {
        switch self {
        case .yellow:   return "Yellow"
        case .pink:     return "Pink"
        case .mint:     return "Mint"
        case .sky:      return "Sky"
        case .lavender: return "Lavender"
        }
    }
}

struct DrawingStroke: Equatable, Codable {
    /// Points in node-local coordinates (0...width × 0...height).
    var points: [CGPoint]
    var color: StrokeColor
    var width: CGFloat
}

/// Pre-defined draw colors. Not using `Color` directly because it
/// only conforms to Equatable on macOS 14+, and we target macOS 13.
struct StrokeColor: Equatable, Hashable, Codable {
    let red: Double
    let green: Double
    let blue: Double

    static let blue   = StrokeColor(red: 0.231, green: 0.510, blue: 0.965)
    static let red    = StrokeColor(red: 0.937, green: 0.267, blue: 0.267)
    static let green  = StrokeColor(red: 0.133, green: 0.773, blue: 0.369)
    static let amber  = StrokeColor(red: 0.961, green: 0.620, blue: 0.043)
    static let purple = StrokeColor(red: 0.659, green: 0.333, blue: 0.969)
    static let pink   = StrokeColor(red: 0.925, green: 0.282, blue: 0.600)
    static let cyan   = StrokeColor(red: 0.024, green: 0.714, blue: 0.831)
    static let black  = StrokeColor(red: 0.106, green: 0.106, blue: 0.122)

    static let palette: [StrokeColor] = [.blue, .red, .green, .amber, .purple, .pink, .cyan, .black]

    var swiftUIColor: Color { Color(red: red, green: green, blue: blue) }
}

/// Top-level view mode.
///   `.canvas`    — the regular infinite canvas (edit mode: tools,
///                  connectors, drawing).
///   `.colorform` — regroups cards spatially by dominant color, with
///                  soft "color bulbs" at low zoom.
///   `.archive`   — multi-level zoom hierarchy: Calendar heatmap →
///                  (drill into a day) → Bento → (drill into a card) →
///                  Lightbox. Inner level lives on `CanvasState.archiveLevel`.
///
/// `.canvas` is the *editor*; the others are read-only *views* over
/// the same document. `CanvasState.lastViewMode` remembers which view
/// the user last entered (excluding Colorform, which is expensive to
/// recompute at launch) so reopening the app can restore it.
enum CanvasMode: String, CaseIterable, Identifiable, Codable {
    case canvas, colorform, archive

    var id: String { rawValue }
    var label: String {
        switch self {
        case .canvas:    return "Canvas"
        case .colorform: return "Colorform"
        case .archive:   return "Archive"
        }
    }
    var systemImage: String {
        switch self {
        case .canvas:    return "rectangle.on.rectangle"
        case .colorform: return "circle.hexagongrid.fill"
        case .archive:   return "calendar"
        }
    }

    /// True for modes that *view* the document without mutating its
    /// spatial layout. The mode switcher groups these visually and
    /// `lastViewMode` persists the most-recent one across launches.
    var isViewMode: Bool {
        switch self {
        case .canvas:                  return false
        case .colorform, .archive:     return true
        }
    }
}

/// Levels within Archive mode, in drill-in order. Outer (`calendar`) is
/// the year-at-a-glance heatmap; `day(Date)` is a magazine-style bento
/// of one day's cards; `card(UUID)` is the single-card lightbox focus.
/// Transitions between levels are camera-animated and use
/// `matchedGeometryEffect` for hero continuity.
enum ArchiveLevel: Equatable {
    case calendar
    case day(Date)
    case card(UUID)
}

enum ToolMode: String, CaseIterable, Identifiable, Codable {
    case select, section, text, stickyNote, draw, connect

    var id: String { rawValue }
    var label: String {
        switch self {
        case .select:     return "Select"
        case .section:    return "Section"
        case .text:       return "Text"
        case .stickyNote: return "Sticky"
        case .draw:       return "Draw"
        case .connect:    return "Connect"
        }
    }
    var systemImage: String {
        switch self {
        case .select:     return "cursorarrow"
        case .section:    return "rectangle.dashed"
        case .text:       return "textformat"
        case .stickyNote: return "note.text"
        case .draw:       return "pencil.tip"
        case .connect:    return "arrow.right"
        }
    }
    var keyboardKey: Character {
        switch self {
        case .select:     return "v"
        case .section:    return "s"
        case .text:       return "t"
        case .stickyNote: return "n"
        case .draw:       return "d"
        case .connect:    return "c"
        }
    }
}

// MARK: - Connectors (FigJam-style arrows between nodes)

struct Connector: Identifiable, Equatable, Codable {
    let id: UUID
    var sourceID: UUID
    var targetID: UUID

    init(id: UUID = UUID(), sourceID: UUID, targetID: UUID) {
        self.id = id
        self.sourceID = sourceID
        self.targetID = targetID
    }
}

/// In-flight connector during a drag-to-connect gesture.
struct PendingConnector: Equatable {
    let sourceID: UUID
    var cursorWorld: CGPoint
    var hoveredTargetID: UUID?
}

// MARK: - Camera

struct Camera: Equatable, Codable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var zoom: CGFloat = 1
}

// MARK: - Page (one section of the document)

/// A single page in the canvas document. Each page owns its own nodes,
/// connectors, and camera (zoom + pan). Selection, tool mode, etc. stay
/// document-global on `CanvasState`.
struct Page: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var nodes: [CanvasNode]
    var connectors: [Connector]
    var camera: Camera
    /// Pinned pages float to the top of the sidebar (e.g. the iPhone inbox).
    var pinned: Bool

    init(id: UUID = UUID(),
         name: String,
         nodes: [CanvasNode] = [],
         connectors: [Connector] = [],
         camera: Camera = Camera(),
         pinned: Bool = false) {
        self.id = id
        self.name = name
        self.nodes = nodes
        self.connectors = connectors
        self.camera = camera
        self.pinned = pinned
    }

    // Explicit, tolerant decoding so older `canvas.json` files (which predate
    // `pinned`) still load — a missing key defaults to `false` instead of
    // throwing and wiping the document.
    private enum CodingKeys: String, CodingKey {
        case id, name, nodes, connectors, camera, pinned
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        nodes = try c.decode([CanvasNode].self, forKey: .nodes)
        connectors = try c.decode([Connector].self, forKey: .connectors)
        camera = try c.decode(Camera.self, forKey: .camera)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

// MARK: - Tweet API decoding (unchanged)

struct TweetUser: Decodable, Equatable {
    let name: String
    let screenName: String
    let profileImageURL: String?

    enum CodingKeys: String, CodingKey {
        case name
        case screenName = "screen_name"
        case profileImageURL = "profile_image_url_https"
    }
}

struct TweetVideoVariant: Decodable, Equatable {
    let bitrate: Int?
    let contentType: String
    let url: String

    enum CodingKeys: String, CodingKey {
        case bitrate
        case contentType = "content_type"
        case url
    }
}

struct TweetVideoInfo: Decodable, Equatable {
    let variants: [TweetVideoVariant]
    let aspectRatio: [Int]?

    enum CodingKeys: String, CodingKey {
        case variants
        case aspectRatio = "aspect_ratio"
    }
}

struct TweetMedia: Decodable, Equatable {
    let type: String
    let mediaURLHTTPS: String
    let videoInfo: TweetVideoInfo?

    enum CodingKeys: String, CodingKey {
        case type
        case mediaURLHTTPS = "media_url_https"
        case videoInfo = "video_info"
    }
}

struct TweetData: Decodable, Equatable {
    let text: String?
    let user: TweetUser
    let mediaDetails: [TweetMedia]?
    let createdAt: String?
    let favoriteCount: Int?
    let conversationCount: Int?

    enum CodingKeys: String, CodingKey {
        case text
        case user
        case mediaDetails
        case createdAt = "created_at"
        case favoriteCount = "favorite_count"
        case conversationCount = "conversation_count"
    }
}

// MARK: - Manual Codable for CanvasNode.Kind (enum w/ associated values)

extension CanvasNode.Kind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, url, content, fontSize, stroke, data, filename, fileURL
        case title, color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "tweet":
            self = .tweet(url: try c.decode(String.self, forKey: .url))
        case "instagram":
            self = .instagram(url: try c.decode(String.self, forKey: .url))
        case "youtube":
            self = .youtube(url: try c.decode(String.self, forKey: .url))
        case "text":
            self = .text(
                content: try c.decode(String.self, forKey: .content),
                fontSize: try c.decode(CGFloat.self, forKey: .fontSize)
            )
        case "drawing":
            self = .drawing(stroke: try c.decode(DrawingStroke.self, forKey: .stroke))
        case "image":
            self = .image(
                data: try c.decode(Data.self, forKey: .data),
                filename: try c.decode(String.self, forKey: .filename)
            )
        case "video":
            self = .video(
                fileURL: try c.decode(URL.self, forKey: .fileURL),
                filename: try c.decode(String.self, forKey: .filename)
            )
        case "section":
            self = .section(
                title: try c.decode(String.self, forKey: .title),
                color: try c.decode(SectionColor.self, forKey: .color)
            )
        case "stickyNote":
            self = .stickyNote(
                content: try c.decode(String.self, forKey: .content),
                color: try c.decode(StickyColor.self, forKey: .color)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown CanvasNode.Kind type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tweet(let url):
            try c.encode("tweet", forKey: .type)
            try c.encode(url, forKey: .url)
        case .instagram(let url):
            try c.encode("instagram", forKey: .type)
            try c.encode(url, forKey: .url)
        case .youtube(let url):
            try c.encode("youtube", forKey: .type)
            try c.encode(url, forKey: .url)
        case .text(let content, let fontSize):
            try c.encode("text", forKey: .type)
            try c.encode(content, forKey: .content)
            try c.encode(fontSize, forKey: .fontSize)
        case .drawing(let stroke):
            try c.encode("drawing", forKey: .type)
            try c.encode(stroke, forKey: .stroke)
        case .image(let data, let filename):
            try c.encode("image", forKey: .type)
            try c.encode(data, forKey: .data)
            try c.encode(filename, forKey: .filename)
        case .video(let fileURL, let filename):
            try c.encode("video", forKey: .type)
            try c.encode(fileURL, forKey: .fileURL)
            try c.encode(filename, forKey: .filename)
        case .section(let title, let color):
            try c.encode("section", forKey: .type)
            try c.encode(title, forKey: .title)
            try c.encode(color, forKey: .color)
        case .stickyNote(let content, let color):
            try c.encode("stickyNote", forKey: .type)
            try c.encode(content, forKey: .content)
            try c.encode(color, forKey: .color)
        }
    }
}

extension TweetData {
    var bestVideoURL: URL? {
        guard let media = mediaDetails?.first,
              media.type == "video" || media.type == "animated_gif",
              let variants = media.videoInfo?.variants else { return nil }
        let mp4s = variants
            .filter { $0.contentType == "video/mp4" }
            .sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }
        return mp4s.first.flatMap { URL(string: $0.url) }
    }

    var posterURL: URL? {
        mediaDetails?.first.flatMap { URL(string: $0.mediaURLHTTPS) }
    }

    var hasPhoto: Bool {
        mediaDetails?.first?.type == "photo"
    }

    var videoAspect: CGFloat {
        if let info = mediaDetails?.first?.videoInfo,
           let ar = info.aspectRatio,
           ar.count == 2, ar[0] > 0, ar[1] > 0 {
            return CGFloat(ar[0]) / CGFloat(ar[1])
        }
        return 16.0 / 9.0
    }
}
