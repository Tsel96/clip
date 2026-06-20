import AppKit
import AVFoundation

/// Native (AppKit) card content — the start of replacing the SwiftUI-hosted
/// cards with native views per type, mirroring Spatial's `CanvasItemView` /
/// `Canvas*View` architecture. Each type renders directly into an NSView that
/// fills `CardItemView`; chrome (rounded corners, shadow, selection) lives on
/// the item layer.
///
/// Migration is incremental: `makeNativeCardContent` returns `nil` for kinds
/// not yet ported, and `CardItemView` falls back to hosting the SwiftUI card so
/// nothing breaks mid-migration.
@MainActor
func makeNativeCardContent(for node: CanvasNode) -> NSView? {
    switch node.kind {
    case .image(let data, _):
        return CardImageContentView(data: data)
    case .video(let fileURL, _):
        let make = { CardVideoContentView(fileURL: fileURL,
                                          trimStart: node.trimStart, trimEnd: node.trimEnd,
                                          nodeID: node.id) }
        return FeatureFlags.useWebViewCache
            ? NativeVideoCache.shared.view(for: node.id, make: make)
            : make()
    case .drawing(let stroke):
        return CardDrawingContentView(stroke: stroke)
    case .section(let title, let color):
        return CardSectionContentView(title: title, color: color)
    case .stickyNote(let content, let color):
        return CardStickyContentView(content: content, color: color)
    case .folder:
        let v = FolderCardView(); v.update(for: node); return v
    case .text(let content, let fontSize):
        // Native at-rest render. `HostingCollectionItem.setContent(isEditing:)`
        // swaps to the SwiftUI inline editor while this node is being edited.
        // Gated so the whole text card can fall back to SwiftUI in one flip.
        return FeatureFlags.useNativeText
            ? CardTextContentView(content: content, fontSize: fontSize)
            : nil
    default:
        // tweet / instagram / youtube / webclip — still SwiftUI (web cards keep
        // their semantic-zoom live↔poster lifecycle). See task #17.
        return nil
    }
}

/// A cheap content signature for the kinds whose native view must refresh when
/// their payload changes (text/colour edits don't change the item's frame, so
/// `apply` would otherwise leave a native card stale — unlike SwiftUI hosts,
/// which re-render reactively). `nil` = immutable content (image/video/drawing/
/// web), which never needs a refresh. Avoids comparing image `Data`.
func nativeContentKey(for node: CanvasNode) -> String? {
    switch node.kind {
    case .section(let t, let c):    return "section|\(t)|\(c.rawValue)"
    case .stickyNote(let t, let c): return "sticky|\(t)|\(c.rawValue)"
    case .text(let t, let s):       return "text|\(t)|\(s)"
    case .folder(let t, let i, let c): return "folder|\(t)|\(i)|\(c.count)"
    default:                        return nil
    }
}

/// Native content that can refresh in place when its node's payload changes
/// (so a section recolour / sticky edit reflects without a re-host).
protocol NativeCardUpdatable: AnyObject {
    func update(for node: CanvasNode)
}

// MARK: - Model colour → NSColor (no SwiftUI)

extension SectionColor {
    var nsColor: NSColor {
        switch self {
        case .slate:    return NSColor(srgbRed: 0.45, green: 0.50, blue: 0.58, alpha: 1)
        case .sand:     return NSColor(srgbRed: 0.78, green: 0.65, blue: 0.42, alpha: 1)
        case .mint:     return NSColor(srgbRed: 0.42, green: 0.72, blue: 0.55, alpha: 1)
        case .lavender: return NSColor(srgbRed: 0.62, green: 0.55, blue: 0.78, alpha: 1)
        case .rose:     return NSColor(srgbRed: 0.82, green: 0.50, blue: 0.58, alpha: 1)
        }
    }
}

extension StickyColor {
    /// Background fill — Spatial's exact muted sRGB pastels.
    var nsColor: NSColor {
        switch self {
        case .yellow:       return NSColor(srgbRed: 0.980, green: 0.973, blue: 0.902, alpha: 1)
        case .pink:         return NSColor(srgbRed: 0.980, green: 0.902, blue: 0.945, alpha: 1)
        case .mint:         return NSColor(srgbRed: 0.902, green: 0.980, blue: 0.922, alpha: 1)
        case .sky:          return NSColor(srgbRed: 0.902, green: 0.961, blue: 0.980, alpha: 1)
        case .lavender:     return NSColor(srgbRed: 0.910, green: 0.902, blue: 0.980, alpha: 1)
        case .yellowRich:   return NSColor(srgbRed: 0.980, green: 0.965, blue: 0.824, alpha: 1)
        case .pinkRich:     return NSColor(srgbRed: 0.980, green: 0.824, blue: 0.906, alpha: 1)
        case .greenRich:    return NSColor(srgbRed: 0.824, green: 0.980, blue: 0.859, alpha: 1)
        case .blueRich:     return NSColor(srgbRed: 0.824, green: 0.937, blue: 0.980, alpha: 1)
        case .lavenderRich: return NSColor(srgbRed: 0.839, green: 0.824, blue: 0.980, alpha: 1)
        case .neutral:      return NSColor(srgbRed: 0.843, green: 0.851, blue: 0.859, alpha: 1)
        case .neutralHiCon: return NSColor(srgbRed: 0.843, green: 0.851, blue: 0.859, alpha: 1)
        }
    }
    /// Per-swatch dark text color — hue-matched so it reads well on the pastel bg.
    var nsTextColor: NSColor {
        switch self {
        case .yellow, .yellowRich:           return NSColor(srgbRed: 0.322, green: 0.286, blue: 0.000, alpha: 1) // #524900
        case .pink, .pinkRich:               return NSColor(srgbRed: 0.322, green: 0.000, blue: 0.173, alpha: 1) // #52002C
        case .mint, .greenRich:              return NSColor(srgbRed: 0.000, green: 0.322, blue: 0.075, alpha: 1) // #005213
        case .sky, .blueRich:                return NSColor(srgbRed: 0.000, green: 0.235, blue: 0.322, alpha: 1) // #003C52
        case .lavender, .lavenderRich:       return NSColor(srgbRed: 0.031, green: 0.000, blue: 0.322, alpha: 1) // #080052
        case .neutral:                       return NSColor(srgbRed: 0.322, green: 0.286, blue: 0.000, alpha: 1) // #524900
        case .neutralHiCon:                  return NSColor(srgbRed: 0.012, green: 0.063, blue: 0.102, alpha: 1) // #03101A
        }
    }
}

/// Rounded-design system font (SwiftUI's `.rounded`) for AppKit.
func roundedSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withDesign(.rounded) { return NSFont(descriptor: d, size: size) ?? base }
    return base
}

/// Native section frame (Spatial-style labelled container): a tinted rounded
/// body with a header band carrying a dashed-rect glyph + title. Mirrors
/// `SectionNodeView`. Drawn in standard (bottom-left) coords so the header sits
/// at the visual top with no flip guesswork. The hover colour-picker / inline
/// rename are canvas-dead (the input view owns clicks), so this is render-only.
final class CardSectionContentView: NSView, NativeCardUpdatable {
    private var title: String
    private var color: SectionColor
    private let titleField = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let headerHeight: CGFloat = 28
    private let radius: CGFloat = 12

    init(title: String, color: SectionColor) {
        self.title = title; self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        addSubview(icon)
        titleField.font = roundedSystemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        addSubview(titleField)
        apply()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(for node: CanvasNode) {
        guard case .section(let t, let c) = node.kind else { return }
        title = t; color = c; apply()
    }

    private func apply() {
        titleField.stringValue = title.isEmpty ? "Section" : title
        titleField.textColor = title.isEmpty ? .secondaryLabelColor : .labelColor
        icon.contentTintColor = color.nsColor.withAlphaComponent(0.85)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let H = bounds.height
        icon.frame = NSRect(x: 10, y: H - headerHeight + (headerHeight - 12) / 2, width: 12, height: 12)
        let tx: CGFloat = 10 + 12 + 8
        titleField.frame = NSRect(x: tx, y: H - headerHeight + (headerHeight - 17) / 2,
                                  width: max(0, bounds.width - tx - 10), height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        let base = color.nsColor
        let body = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        base.withAlphaComponent(0.08).setFill(); body.fill()
        // Header band — tinted, clipped to the body so its top corners round.
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        base.withAlphaComponent(0.15).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: bounds.height - headerHeight,
                                  width: bounds.width, height: headerHeight)).fill()
        NSGraphicsContext.restoreGraphicsState()
        // Header divider + body border.
        base.withAlphaComponent(0.30).setStroke()
        let div = NSBezierPath(); div.lineWidth = 0.5
        div.move(to: NSPoint(x: 0, y: bounds.height - headerHeight))
        div.line(to: NSPoint(x: bounds.width, y: bounds.height - headerHeight)); div.stroke()
        body.lineWidth = 1; body.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Native Spatial-style sticky: a muted-pastel rounded block, no bottom lip,
/// with proportional font + insets that scale with the card width. Float shadow
/// lives on `CardItemView`; inline edit / colour picker are canvas-dead.
final class CardStickyContentView: NSView, NativeCardUpdatable {
    private var content: String
    private var color: StickyColor
    private let textField = NSTextField(wrappingLabelWithString: "")
    private let radius: CGFloat = 6

    init(content: String, color: StickyColor) {
        self.content = content; self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        textField.isEditable = false
        textField.isSelectable = false
        textField.drawsBackground = false
        textField.isBordered = false
        textField.maximumNumberOfLines = 0
        textField.lineBreakMode = .byWordWrapping
        textField.cell?.wraps = true
        addSubview(textField)
        apply()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(for node: CanvasNode) {
        guard case .stickyNote(let t, let c) = node.kind else { return }
        content = t; color = c; apply()
    }

    private func apply() {
        textField.stringValue = content
        textField.textColor = color.nsTextColor
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        guard w > 1, h > 1 else { return }
        // Proportional sizing — at 200pt width: font 12, h-inset 12, v-inset 24.
        // Grows linearly with width so large stickies stay readable.
        let fontSize = max(12, 12 + (w - 200) * 0.06).rounded()
        let hPad = max(12, 12 + (w - 200) * 0.06)
        let vPad = max(24, 24 + (w - 200) * 0.06)
        textField.font = roundedSystemFont(ofSize: fontSize, weight: .medium)
        textField.frame = NSRect(x: hPad, y: vPad,
                                 width: max(0, w - hPad * 2),
                                 height: max(0, h - vPad * 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Plain pastel fill — no bottom lip (Spatial has none).
        let body = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        color.nsColor.setFill(); body.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Native canvas text — Spatial's at-rest `CanvasLabel`. Renders the node's text
/// with no chrome (the selection rect on `CardItemView` hugs it). Sized to the
/// glyphs and centred, matching the SwiftUI `TextNodeView` display (`.fixedSize()`
/// hosted in an item that centres it). The inline EDITOR stays SwiftUI:
/// `HostingCollectionItem.setContent(isEditing:)` swaps to it while this node is
/// `editingTextNodeID`, so the auto-sizing field + focus all stay proven.
final class CardTextContentView: NSView, NativeCardUpdatable {
    private var content: String
    private var fontSize: CGFloat
    private let field = NSTextField(labelWithString: "")

    init(content: String, fontSize: CGFloat) {
        self.content = content; self.fontSize = fontSize
        super.init(frame: .zero)
        wantsLayer = true
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.isBordered = false
        field.maximumNumberOfLines = 0           // honour committed \n line breaks
        field.cell?.wraps = false                // no wrap (≈ SwiftUI .fixedSize)
        field.cell?.isScrollable = false
        field.alignment = .left
        addSubview(field)
        apply()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(for node: CanvasNode) {
        guard case .text(let t, let s) = node.kind else { return }
        content = t; fontSize = s; apply()
    }

    private func apply() {
        field.font = .systemFont(ofSize: fontSize)
        if content.isEmpty {
            field.stringValue = "Text"
            field.textColor = .tertiaryLabelColor
        } else {
            field.stringValue = content
            field.textColor = .labelColor
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        field.sizeToFit()
        let w = field.frame.width, h = field.frame.height
        field.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2,
                             width: w, height: h)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Build a smoothed quadratic-bézier `CGPath` through `points` — the AppKit twin
/// of `PathMath.smoothPath` (kept here so native content never imports SwiftUI).
func smoothCGPath(through points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    path.move(to: first)
    if points.count == 1 { return path }
    if points.count == 2 { path.addLine(to: points[1]); return path }
    for i in 1..<(points.count - 1) {
        let curr = points[i], next = points[i + 1]
        let mid = CGPoint(x: (curr.x + next.x) / 2, y: (curr.y + next.y) / 2)
        path.addQuadCurve(to: mid, control: curr)
    }
    path.addLine(to: points.last!)
    return path
}

/// Native drawing card: strokes the stored `DrawingStroke` (already in node-local
/// coords) with round caps/joins. Mirrors `DrawingNodeView`; the hover-delete
/// chip it had is canvas-dead anyway (the input view owns all clicks).
final class CardDrawingContentView: NSView {
    override var isFlipped: Bool { true }                 // top-left coords, like the stored points
    private let stroke: DrawingStroke

    init(stroke: DrawingStroke) {
        self.stroke = stroke
        super.init(frame: .zero)
        wantsLayer = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, stroke.points.count > 1 else { return }
        ctx.addPath(smoothCGPath(through: stroke.points))
        ctx.setStrokeColor(NSColor(srgbRed: stroke.color.red, green: stroke.color.green,
                                   blue: stroke.color.blue, alpha: 1).cgColor)
        ctx.setLineWidth(stroke.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    // Native content is non-interactive — CardItemView owns select/move/resize.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Native image card: a CALayer showing the decoded image, aspect-fill, clipped
/// to the card's rounded corners. (Spatial's `CanvasImageView`.)
final class CardImageContentView: NSView {
    override var isFlipped: Bool { true }
    private let imageLayer = CALayer()

    init(data: Data) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CardChrome.cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        if let img = NSImage(data: data),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            imageLayer.contents = cg
        }
        layer?.addSublayer(imageLayer)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // No implicit animation, or the image would lerp during a resize.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    // Native content is non-interactive — CardItemView owns select/move/resize.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Native local-video card: an `AVPlayerLayer` (loop, muted, autoplay) over a
/// decoded first-frame poster, clipped to the rounded corners. Mirrors Spatial's
/// `CanvasVideoItem` (AVPlayer / AVPlayerLayer / AVPlayerLooper). Always-live to
/// match the current decoupled cards; semantic-zoom unload is a later pass.
final class CardVideoContentView: NSView {
    override var isFlipped: Bool { true }
    private let host = PlayerHostView()
    private let posterLayer = CALayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private let fileURL: URL
    private let timeRange: CMTimeRange?
    private let nodeID: UUID?

    init(fileURL: URL, trimStart: Double?, trimEnd: Double?, nodeID: UUID? = nil) {
        self.fileURL = fileURL
        self.nodeID = nodeID
        if let s = trimStart, let e = trimEnd, e > s {
            self.timeRange = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                                         end: CMTime(seconds: e, preferredTimescale: 600))
        } else {
            self.timeRange = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CardChrome.cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        posterLayer.contentsGravity = .resizeAspectFill
        posterLayer.masksToBounds = true
        layer?.addSublayer(posterLayer)
        if let poster = VideoPosterStore.cachedPoster(for: fileURL) {
            posterLayer.contents = poster.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else {
            Task { @MainActor in
                if let p = await VideoPosterStore.poster(for: fileURL) {
                    posterLayer.contents = p.cgImage(forProposedRect: nil, context: nil, hints: nil)
                }
            }
        }

        host.translatesAutoresizingMaskIntoConstraints = false
        host.playerLayer.cornerRadius = CardChrome.cornerRadius
        host.playerLayer.masksToBounds = true
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // A fresh looping player. The whole VIEW is reused across the select/move
        // `reloadData` (NativeVideoCache, keyed by node id), so this init runs only
        // once per node — the player persists, so the video never reloads or blinks.
        let item = AVPlayerItem(url: fileURL)
        let p = AVQueuePlayer()
        if let range = timeRange {
            looper = AVPlayerLooper(player: p, templateItem: item, timeRange: range)
            p.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            looper = AVPlayerLooper(player: p, templateItem: item)
        }
        p.isMuted = true
        player = p
        host.attach(player: p)
        p.play()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        posterLayer.frame = bounds
        CATransaction.commit()
    }

    // Pass-through: the AVPlayerLayer host must NOT swallow clicks — the
    // CardItemView owns select/move/resize.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Node id this view is cached under (for NativeVideoCache.park on detach).
    var cacheNodeID: UUID? { nodeID }

    /// Stop + release the player. Called by NativeVideoCache when its deferred
    /// teardown fires — i.e. the node really went away, not just a reload.
    func teardown() {
        player?.pause()
        player = nil
        looper = nil
    }

    deinit { player?.pause() }
}

/// Caches the native file-video VIEW (and thus its live AVPlayer) by node id so it
/// SURVIVES the select/move `reloadData` — re-parented to the new item instead of
/// rebuilt, so the video never reloads or blinks. Unlike a player cache this is
/// order-independent: the view stays in the cache across park↔reclaim, so a card
/// that lands at a lower index on reload still finds it. Mirrors WebViewCache's
/// ~1.2 s deferred teardown so off-screen videos still release.
final class NativeVideoCache {
    static let shared = NativeVideoCache()
    private init() {}
    private var views: [UUID: CardVideoContentView] = [:]
    private var teardowns: [UUID: Timer] = [:]

    /// Reclaim the node's existing video view (cancelling any pending teardown), or
    /// build one. The view is NOT removed from the cache, so repeated reclaims in
    /// any order all return the same instance.
    func view(for id: UUID, make: () -> CardVideoContentView) -> CardVideoContentView {
        teardowns[id]?.invalidate(); teardowns[id] = nil
        if let v = views[id] { return v }
        let v = make()
        views[id] = v
        return v
    }

    /// The view detached from its item — hold it briefly for reuse, then tear it
    /// down if nothing reclaims it (the node scrolled off / was filtered out).
    func park(_ id: UUID) {
        guard views[id] != nil, teardowns[id] == nil else { return }
        teardowns[id] = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.views[id]?.teardown()
            self.views[id] = nil
            self.teardowns[id] = nil
        }
    }

    /// Force-evict on node deletion — tear down immediately.
    func evict(_ id: UUID) {
        teardowns[id]?.invalidate(); teardowns[id] = nil
        views[id]?.teardown()
        views[id] = nil
    }
}

/// Shared card-chrome constants so native content + the item chrome agree.
enum CardChrome {
    static let cornerRadius: CGFloat = 19.375
}
