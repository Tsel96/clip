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
        return CardVideoContentView(fileURL: fileURL,
                                    trimStart: node.trimStart, trimEnd: node.trimEnd)
    case .drawing(let stroke):
        return CardDrawingContentView(stroke: stroke)
    case .section(let title, let color):
        return CardSectionContentView(title: title, color: color)
    case .stickyNote(let content, let color):
        return CardStickyContentView(content: content, color: color)
    case .folder:
        let v = FolderCardView(); v.update(for: node); return v
    default:
        // tweet / instagram / youtube / webclip / text — still SwiftUI for now.
        // (Web cards keep their semantic-zoom live↔poster lifecycle; text keeps
        // its inline SwiftUI editor. See task #17.)
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
    var nsColor: NSColor {
        switch self {
        case .yellow:   return NSColor(srgbRed: 1.00, green: 0.91, blue: 0.55, alpha: 1)
        case .pink:     return NSColor(srgbRed: 1.00, green: 0.78, blue: 0.83, alpha: 1)
        case .mint:     return NSColor(srgbRed: 0.74, green: 0.95, blue: 0.83, alpha: 1)
        case .sky:      return NSColor(srgbRed: 0.76, green: 0.90, blue: 1.00, alpha: 1)
        case .lavender: return NSColor(srgbRed: 0.85, green: 0.80, blue: 1.00, alpha: 1)
        }
    }
    var shadowLipNS: NSColor {
        switch self {
        case .yellow:   return NSColor(srgbRed: 0.93, green: 0.81, blue: 0.41, alpha: 1)
        case .pink:     return NSColor(srgbRed: 0.93, green: 0.65, blue: 0.72, alpha: 1)
        case .mint:     return NSColor(srgbRed: 0.62, green: 0.85, blue: 0.72, alpha: 1)
        case .sky:      return NSColor(srgbRed: 0.60, green: 0.80, blue: 0.95, alpha: 1)
        case .lavender: return NSColor(srgbRed: 0.72, green: 0.67, blue: 0.92, alpha: 1)
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

/// Native FigJam-style sticky: a pastel rounded block with a darker bottom
/// "shadow lip" band and wrapped text. Mirrors `StickyNodeView` (the float
/// shadow is owned by `CardItemView`, so it's omitted here; inline editing /
/// hover colour-picker are canvas-dead). Render-only.
final class CardStickyContentView: NSView, NativeCardUpdatable {
    private var content: String
    private var color: StickyColor
    private let textField = NSTextField(wrappingLabelWithString: "")
    private let radius: CGFloat = 6
    private let lipHeight: CGFloat = 6

    init(content: String, color: StickyColor) {
        self.content = content; self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        textField.font = roundedSystemFont(ofSize: 16, weight: .medium)
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
        textField.textColor = NSColor.black.withAlphaComponent(0.85)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // Matches the SwiftUI insets: h14, top16, bottom = lip + a little.
        let x: CGFloat = 14, top: CGFloat = 16, bottom = lipHeight + 6
        textField.frame = NSRect(x: x, y: bottom,
                                 width: max(0, bounds.width - x * 2),
                                 height: max(0, bounds.height - top - bottom))
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        color.nsColor.setFill(); body.fill()
        // Darker bottom "block" lip, clipped to the body so its bottom corners round.
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        color.shadowLipNS.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: lipHeight)).fill()
        NSGraphicsContext.restoreGraphicsState()
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

    init(fileURL: URL, trimStart: Double?, trimEnd: Double?) {
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

        let item = AVPlayerItem(url: fileURL)
        let player = AVQueuePlayer()
        if let s = trimStart, let e = trimEnd, e > s {
            let range = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                                    end: CMTime(seconds: e, preferredTimescale: 600))
            looper = AVPlayerLooper(player: player, templateItem: item, timeRange: range)
            player.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            looper = AVPlayerLooper(player: player, templateItem: item)
        }
        player.isMuted = true
        self.player = player
        host.attach(player: player)
        player.play()
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

    deinit { player?.pause() }
}

/// Shared card-chrome constants so native content + the item chrome agree.
enum CardChrome {
    static let cornerRadius: CGFloat = 19.375
}
