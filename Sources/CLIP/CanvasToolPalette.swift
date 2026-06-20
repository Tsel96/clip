import AppKit
import SwiftUI

// MARK: - NativeCanvasToolPalette  (public SwiftUI bridge — alias of _PaletteRepresentable)

/// Mounts the candy-yellow tool palette at the bottom-center of the canvas.
/// All rendering is native AppKit so hit-testing, layer shadows, and animation
/// are precise — no SwiftUI geometry mangling.
///
/// Usage (CanvasView.swift):
///   `_PaletteRepresentable(state: state).frame(width: totalW, height: totalH)`
/// This type is exposed so callers outside this file can reference the
/// CanvasToolPaletteView dimension constants without needing the concrete
/// representable struct.
typealias NativeCanvasToolPalette = _PaletteRepresentable

// MARK: - CanvasToolPaletteView

/// The full horizontal assembly: [main yellow pill] [10 pt gap] [round + pill].
///
/// Figma node 60:12981 — Frame 44 — width 542 × height 62 (plus overflow for
/// the decorative props that poke above the pill and for the drop shadow bleed).
///
/// Visual hierarchy (bottom → top):
///   1. Green outer capsule (border colour #3DA726, drop-shadow)
///   2. Yellow inner capsule (gradient #FFF53B → #F8DE47, top rim #FFFCA9)
///   3. Tool buttons — active one gets a green (#3DA726) fill circle
///   4. Decorative SVG props (Marker, Stickers) — overflow above the pill
///   5. Round "add / section" pill (same candy skin)
final class CanvasToolPaletteView: NSView {

    // MARK: Sub-views

    /// The five-tool main pill  (470 × 62 canvas-rect, but drawn with
    /// extra padding so its drop-shadow is never clipped by the host's bounds).
    private let mainPill = MainPillView()

    /// The round "+" / section pill (62 × 62).
    private let addPill = AddPillView()

    /// Drop-shadows for both pills live HERE (in the full-size host) rather than
    /// inside the pill views — a pill's bounds are only as tall as the pill, so a
    /// shadow parented there is clipped at the pill's bottom edge before it can
    /// reach the host's shadow-bleed room. Parented here, the host's totalW×totalH
    /// bounds fully contain the shadow, so nothing can clip it.
    private let mainShadows = makeCandyShadowLayers()
    private let addShadows  = makeCandyShadowLayers()

    /// Callback injected by `configure(active:onTap:)`.
    var onToolTap: ((ToolMode) -> Void)?
    var onAddTap: (() -> Void)?
    var onFolderTap: (() -> Void)?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false

        // Shadow layers go behind the pill subviews (zPosition keeps them back).
        (mainShadows + addShadows).forEach {
            $0.zPosition = -1
            layer?.addSublayer($0)
        }

        addSubview(mainPill)
        addSubview(addPill)

        mainPill.onToolTap   = { [weak self] tool in self?.onToolTap?(tool) }
        mainPill.onFolderTap = { [weak self] in self?.onFolderTap?() }
        addPill.onTap        = { [weak self] in self?.onAddTap?() }
    }

    // MARK: - Layout

    /// Total width = 470 + 10 + 62 = 542 pt (Figma Frame 44 width).
    /// We add `shadowBleed` of padding on every side so the host NSView
    /// is larger than the visual content and the drop-shadow is never clipped.
    static let mainPillW: CGFloat  = 470
    static let addPillW: CGFloat   = 62
    static let gap: CGFloat        = 10
    /// Visual content height = 62; decorative props overflow ~12 pt above.
    static let contentH: CGFloat   = 62
    static let propOverflow: CGFloat = 18   // marker pokes ~12 pt above pill + margin
    /// Bottom gap = how far the pill sits off the viewport bottom (18 pt, user
    /// spec) AND the room for the visible drop-shadow. The frame bottom sits flush
    /// with the viewport (`.padding(.bottom, 0)`), so the faint shadow tail past
    /// 18 pt simply fades off the screen edge — no hard cut-off in the canvas.
    static let shadowBleed: CGFloat  = 18
    static let totalW: CGFloat =
        mainPillW + gap + addPillW + shadowBleed * 2
    static let totalH: CGFloat =
        contentH + propOverflow + shadowBleed

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.totalW, height: Self.totalH)
    }

    override func layout() {
        super.layout()
        let b = bounds

        // Horizontally centered, pushed to the shadow-bleed bottom
        let leftEdge = (b.width  - (Self.mainPillW + Self.gap + Self.addPillW)) / 2
        let bottomY  = Self.shadowBleed  // Y=0 is visually below pill

        // Main pill  (includes its own propOverflow header above the 62-pt pill)
        mainPill.frame = NSRect(
            x: leftEdge,
            y: bottomY,
            width: Self.mainPillW,
            height: Self.contentH + Self.propOverflow
        )
        // Add pill — Figma's parent flex is `items-center`, both pills are 62 pt,
        // so the add capsule must be flush with the main pill's capsule (which sits
        // in the BOTTOM 62 pt of mainPill, i.e. at `bottomY`). NOT offset up by the
        // prop overflow — that was lifting the "+" 14 pt above the row.
        addPill.frame = NSRect(
            x: leftEdge + Self.mainPillW + Self.gap,
            y: bottomY,
            width: Self.addPillW,
            height: Self.contentH
        )

        // Drop-shadows, in THIS view's non-flipped space (Y-up → "down" is -Y).
        // The green capsule of each pill sits at the bottom contentH of its frame.
        let mainCapsule = NSRect(x: leftEdge, y: bottomY,
                                 width: Self.mainPillW, height: Self.contentH)
        let addCapsule  = NSRect(x: leftEdge + Self.mainPillW + Self.gap, y: bottomY,
                                 width: Self.addPillW, height: Self.contentH)
        layoutCandyShadows(mainShadows, capsule: mainCapsule,
                           radius: Self.contentH / 2, downSign: -1)
        layoutCandyShadows(addShadows, capsule: addCapsule,
                           radius: Self.contentH / 2, downSign: -1)
    }

    // MARK: - State

    func configure(active: ToolMode) {
        mainPill.configure(active: active)
    }

    /// Drives the "+" button's green selected skin (link input open/closed).
    func setAddSelected(_ on: Bool) {
        addPill.setSelected(on)
    }
}

// MARK: - Candy drop-shadow (Figma node 60:12982 / 60:13020)

/// One level of the pill's layered green drop-shadow. A `CALayer` holds only a
/// single shadow, so the four Figma levels are rendered as four stacked
/// shadow-casting layers behind the capsule.
private struct CandyShadowLevel {
    let y: CGFloat      // downward offset (pt)
    let blur: CGFloat   // → shadowRadius
    let alpha: Float    // → shadowOpacity
}

/// Figma drop-shadow on the green capsule, top → bottom (the 38 px level is
/// fully transparent in Figma and omitted). Blur values are Figma's own iOS
/// `shadowRadius` export (2× the CSS blur):
///   offset 2  radius 3   rgba(0,92,2,0.12)
///   offset 6  radius 6   rgba(0,92,2,0.10)
///   offset 14 radius 8   rgba(0,92,2,0.06)
///   offset 24 radius 10  rgba(0,92,2,0.02)
private let candyShadowLevels: [CandyShadowLevel] = [
    .init(y: 2,  blur: 3,  alpha: 0.12),
    .init(y: 6,  blur: 6,  alpha: 0.10),
    .init(y: 14, blur: 8,  alpha: 0.06),
    .init(y: 24, blur: 10, alpha: 0.02),
]

/// `rgba(0, 92, 2, 1)` — the shadow's green tint (#005C02).
private let candyShadowColor =
    NSColor(srgbRed: 0, green: 92.0 / 255, blue: 2.0 / 255, alpha: 1).cgColor

/// Builds the four shadow-casting layers (clear-filled; the shadow comes from
/// `shadowPath`, set per-layout). Add these BEHIND the green capsule.
private func makeCandyShadowLayers() -> [CALayer] {
    candyShadowLevels.map { level in
        let l = CALayer()
        l.backgroundColor = NSColor.clear.cgColor
        l.shadowColor     = candyShadowColor
        l.shadowOpacity   = level.alpha
        l.shadowRadius    = level.blur
        l.shadowOffset    = .zero        // offset is baked into the path (below)
        l.masksToBounds   = false
        return l
    }
}

/// Positions the shadow layers over `capsule`. Each layer's FRAME is offset by
/// its level's Y in the "down" direction — `downSign` is +1 for a flipped host
/// (Y-down) or -1 for a non-flipped host (Y-up). The shadowPath is just the
/// layer's own bounds, so we never depend on `geometryFlipped` path orientation.
private func layoutCandyShadows(_ layers: [CALayer], capsule: CGRect,
                                radius: CGFloat, downSign: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let path = CGPath(
        roundedRect: CGRect(origin: .zero, size: capsule.size),
        cornerWidth: radius, cornerHeight: radius, transform: nil
    )
    for (i, l) in layers.enumerated() {
        l.frame = capsule.offsetBy(dx: 0, dy: candyShadowLevels[i].y * downSign)
        l.shadowPath = path
    }
    CATransaction.commit()
}

// MARK: - PropButton

/// A clickable decorative prop (Marker / Stickers). `NSImageView` swallows the
/// mouse-down before a gesture recognizer can fire, so the props were dead; this
/// plain view claims every in-bounds click via `hitTest` + fires `onTap` on
/// mouse-up, making the prop a reliable tool button.
private final class PropButton: NSView {
    var onTap: (() -> Void)?
    private let imageView = NSImageView()
    private var isActive  = false
    private var isHovered = false
    private var isPressed = false

    init(image: NSImage?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false        // art overflows; never clip the pop
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setImage(_ image: NSImage?) { imageView.image = image }

    /// Reflects whether this prop's tool (Draw / Sticky) is the active mode —
    /// the 3D art pops up a touch, mirroring the Figma selected variant.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        refreshScale()
    }

    override var isFlipped: Bool { true }
    override func layout() { super.layout(); imageView.frame = bounds }

    // MARK: Hover tracking
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; refreshScale() }
    override func mouseExited(with event: NSEvent)  { isHovered = false; isPressed = false; refreshScale() }

    /// Claim every in-bounds click so the image subview never swallows it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }
    override func mouseDown(with event: NSEvent) { isPressed = true; refreshScale() }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        refreshScale()
        if inside { onTap?() }
    }

    /// One transform = press / active / hover composed, sprung through the
    /// unified `CLIPSpring` with a single coalescing key so re-triggers retarget
    /// instead of stacking.
    private func refreshScale() {
        let s: CGFloat = isPressed ? 0.94 : (isActive ? 1.08 : (isHovered ? 1.05 : 1.0))
        CLIPSpring.scale(self, to: s, key: "xform")
    }
}

// MARK: - MainPillView

/// The 470 × (62 + propOverflow) view.  The bottom 62 pt is the candy pill;
/// the top `propOverflow` pt is where Marker / Stickers poke above the rim.
private final class MainPillView: NSView {

    // MARK: Geometry (all in the bottom 62-pt pill local space)

    private static let pillH: CGFloat       = 62     // outer pill height
    private static let innerH: CGFloat      = 58     // inner yellow capsule height
    private static let innerTop: CGFloat    = 2      // top inset of inner capsule
    private static let innerSideInset: CGFloat = 2   // each side
    private static let buttonSize: CGFloat  = 52
    private static let iconSize: CGFloat    = 24
    private static let buttonRadius: CGFloat = 60    // "60px" in Figma

    // Button X origins within inner capsule (from Figma metadata)
    // 60:12984 Cursor  left=2  → within inner capsule
    // 60:12987 Hand    left=56
    // 60:12990 Text    left=304 (opacity 70%)
    // 60:12995 Folder  left=358 (opacity 70%)
    // 60:12999 Connect left=412 (opacity 70%)
    private static let buttonXs: [CGFloat] = [2, 56, 304, 358, 412]
    private static let buttonOpacities: [CGFloat] = [1, 1, 0.7, 0.7, 0.7]
    // Each button's tool MODE (nil = the Folder ACTION button — it creates a
    // folder instead of entering a mode) + its icon. Draw and Sticky are NOT
    // buttons; they're the Marker / Stickers props (made clickable below).
    private static let buttonModes: [ToolMode?] =
        [.select, .hand, .text, nil, .connect]
    private static let buttonIcons: [String] =
        ["tool_select", "tool_hand", "tool_text", "tool_folder", "tool_connect"]

    // Decorative prop positions (in inner capsule coords, Y from top of inner capsule)
    // Marker:   x=129, y=-10  (overflows above rim by 10+innerTop=12)
    // Stickers: x=195, y=-6   (overflows above rim by 6+innerTop=8)
    // Both clip to the inner capsule rect horizontally but overflow top.
    private static let markerX: CGFloat   = 129
    private static let markerY: CGFloat   = -12   // Figma 60:13004 top:-12 (above inner-capsule top)
    private static let stickersX: CGFloat = 195
    private static let stickersY: CGFloat = -6

    // MARK: Layers

    private let outerLayer   = CALayer()      // green border
    private let innerLayer   = CAGradientLayer() // yellow gradient
    private let rimLayer     = CALayer()      // top highlight rim

    // Tool button views (index-matched to buttonModes)
    private var buttonViews: [ToolPaletteButton] = []

    // Decorative prop views — clickable (Marker = Draw, Stickers = Sticky).
    private let markerView   = PropButton(image: nil)
    private let stickersView = PropButton(image: nil)

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true

        // --- Outer green border layer ---  (drop-shadow is host-parented)
        outerLayer.backgroundColor  = NSColor.fromHex(0x3DA726).cgColor
        outerLayer.masksToBounds    = false
        layer?.addSublayer(outerLayer)

        // --- Inner yellow gradient ---
        // Figma 60:12983: body gradient #FFF53B → #F8DE47 with a 2 pt pale rim
        // (#FFFCA9) on the TOP edge ONLY (`border-t-2`). A crisp 4-stop vertical
        // gradient renders the rim only along the rounded top — never the sides
        // or bottom — so the green outer ring stays the sole full-perimeter edge.
        innerLayer.colors = [
            NSColor.fromHex(0xFFFCA9).cgColor,   // pale top rim
            NSColor.fromHex(0xFFFCA9).cgColor,
            NSColor.fromHex(0xFFF53B).cgColor,   // body top
            NSColor.fromHex(0xF8DE47).cgColor    // body bottom
        ]
        // rim ≈ 2 pt of the 58 pt capsule → 2/58 ≈ 0.0345
        innerLayer.locations = [0.0, 0.0345, 0.0345, 1.0]
        innerLayer.startPoint = CGPoint(x: 0.5, y: 0)
        innerLayer.endPoint   = CGPoint(x: 0.5, y: 1)
        innerLayer.masksToBounds = true
        outerLayer.addSublayer(innerLayer)

        // --- Tool buttons ---
        for (i, icon) in Self.buttonIcons.enumerated() {
            let btn = ToolPaletteButton(iconName: icon)
            btn.iconRestOpacity = Self.buttonOpacities[i]
            let mode = Self.buttonModes[i]
            btn.onTap = { [weak self] in
                if let mode { self?.onToolTap?(mode) }   // enter a tool mode
                else { self?.onFolderTap?() }            // the Folder action button
            }
            addSubview(btn)
            buttonViews.append(btn)
        }

        // --- Decorative props (clickable: Marker = Draw, Stickers = Sticky) ---
        markerView.setImage(NSImage(named: "Marker") ?? loadBundleImage(named: "Marker"))
        markerView.onTap = { [weak self] in self?.onToolTap?(.draw) }
        addSubview(markerView)

        stickersView.setImage(NSImage(named: "Stickers") ?? loadBundleImage(named: "Stickers"))
        stickersView.onTap = { [weak self] in self?.onToolTap?(.stickyNote) }
        addSubview(stickersView)
    }

    /// Loads an SVG/PNG from the app bundle's Resources folder.
    private func loadBundleImage(named name: String) -> NSImage? {
        let extensions = ["svg", "png", "pdf"]
        for ext in extensions {
            if let url = Bundle.module.url(forResource: name, withExtension: ext) {
                return NSImage(contentsOf: url)
            }
        }
        return nil
    }

    var onToolTap: ((ToolMode) -> Void)?
    var onFolderTap: (() -> Void)?

    // MARK: - Layout

    override var isFlipped: Bool { true }  // Y=0 at top, matching Figma coords

    override func layout() {
        super.layout()
        let propOverflow = CanvasToolPaletteView.propOverflow
        let pillH = Self.pillH
        // The pill strip starts at y = propOverflow (in flipped coords, top of the pill)
        let pillTopY = propOverflow

        // Outer layer: full pill width × height, at pillTopY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outerLayer.frame = CGRect(x: 0, y: pillTopY, width: bounds.width, height: pillH)
        let outerR = pillH / 2   // 31 → effectively 999px-radius capsule
        outerLayer.cornerRadius  = outerR
        outerLayer.cornerCurve   = .continuous

        // Inner layer: 2pt inset on each side, 2pt from top
        let innerW = bounds.width - Self.innerSideInset * 2
        innerLayer.frame  = CGRect(x: Self.innerSideInset, y: Self.innerTop,
                                   width: innerW, height: Self.innerH)
        let innerR = Self.innerH / 2
        innerLayer.cornerRadius = innerR
        innerLayer.cornerCurve  = .continuous
        CATransaction.commit()

        // Tool buttons (coords relative to inner capsule top-left, then shifted by
        // (innerSideInset, innerTop + pillTopY) to land in view space)
        let innerOriginX = Self.innerSideInset
        let innerOriginY = pillTopY + Self.innerTop   // view-local flipped Y

        for (i, btn) in buttonViews.enumerated() {
            let bx = Self.buttonXs[i]
            let by: CGFloat = 2   // buttonY within inner capsule = 2pt from top
            btn.frame = NSRect(
                x: innerOriginX + bx,
                y: innerOriginY + by,
                width: Self.buttonSize,
                height: Self.buttonSize
            )
        }

        // Decorative props (Figma gives positions relative to inner capsule top)
        // Marker: 66 × 68, at (129, -10) from inner capsule top
        let markerW: CGFloat = 66
        let markerH: CGFloat = 68
        markerView.frame = NSRect(
            x: innerOriginX + Self.markerX,
            y: innerOriginY + Self.markerY,
            width: markerW,
            height: markerH
        )

        // Stickers: 89 × 64, at (195, -6) from inner capsule top
        // The Figma clip is bottom-aligned (bottom: 0)
        let stickersW: CGFloat = 89
        let stickersH: CGFloat = 64
        stickersView.frame = NSRect(
            x: innerOriginX + Self.stickersX,
            y: innerOriginY + Self.stickersY,
            width: stickersW,
            height: stickersH
        )
    }

    // MARK: - State

    func configure(active: ToolMode) {
        for (i, btn) in buttonViews.enumerated() {
            btn.setActive(Self.buttonModes[i] == active, animated: true)
        }
        // The Marker / Stickers props are the Draw / Sticky tools — pop them up
        // when their mode is active (Figma selected variant lifts the 3D art).
        markerView.setActive(active == .draw)
        stickersView.setActive(active == .stickyNote)
    }
}

// MARK: - AddPillView

/// The round (62 × 62) "+" candy pill — same green/yellow skin, contains a
/// "+" icon at 70% opacity. Fires `onTap` (wired to section creation).
private final class AddPillView: NSView {

    var onTap: (() -> Void)?

    private let outerLayer = CALayer()
    private let innerLayer = CAGradientLayer()
    /// White wash that fades in on hover (Figma 72:36831 — 40% white over the
    /// candy yellow, brightening it). Clipped to the inner circle, under the icon.
    private let hoverHighlight = CALayer()
    /// Spatial's `clickHighlight` — a dark overlay clipped to the inner circle
    /// that fades in on press (under the icon), giving the "dim while pressed".
    private let pressHighlight = CALayer()
    private let iconView   = NSImageView()
    private var isHovered  = false
    private var isPressed  = false
    private var isSelected = false

    /// Candy-yellow inner skin (default) — pale rim + warm gradient.
    private static let yellowSkin: [CGColor] = [
        NSColor.fromHex(0xFFFCA9).cgColor, NSColor.fromHex(0xFFFCA9).cgColor,
        NSColor.fromHex(0xFFF53B).cgColor, NSColor.fromHex(0xF8DE47).cgColor
    ]
    /// Selected skin (Figma 72:36780): #3DA726→#4CC432 gradient + 30% black overlay
    /// = #2B751B→#358923. No separate rim — uniform dark green at top.
    private static let greenSkin: [CGColor] = [
        NSColor.fromHex(0x2B751B).cgColor, NSColor.fromHex(0x2B751B).cgColor,
        NSColor.fromHex(0x2B751B).cgColor, NSColor.fromHex(0x358923).cgColor
    ]

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false      // never clip the hover-grow

        outerLayer.backgroundColor = NSColor.fromHex(0x3DA726).cgColor
        outerLayer.masksToBounds   = false
        layer?.addSublayer(outerLayer)

        // Pale top rim only (Figma `border-t-2`), via a crisp 4-stop gradient —
        // matches the main pill. 2 pt of the 58 pt inner circle → ≈ 0.0345.
        innerLayer.colors = [
            NSColor.fromHex(0xFFFCA9).cgColor,
            NSColor.fromHex(0xFFFCA9).cgColor,
            NSColor.fromHex(0xFFF53B).cgColor,
            NSColor.fromHex(0xF8DE47).cgColor
        ]
        innerLayer.locations = [0.0, 0.0345, 0.0345, 1.0]
        innerLayer.startPoint = CGPoint(x: 0.5, y: 0)
        innerLayer.endPoint   = CGPoint(x: 0.5, y: 1)
        innerLayer.masksToBounds = true
        outerLayer.addSublayer(innerLayer)

        // hover wash — white, hidden at rest, fades to 40% on hover (under press).
        hoverHighlight.backgroundColor = NSColor.white.cgColor
        hoverHighlight.opacity = 0
        innerLayer.addSublayer(hoverHighlight)

        // clickHighlight — dark wash, hidden at rest, fades in on press.
        pressHighlight.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        pressHighlight.opacity = 0
        innerLayer.addSublayer(pressHighlight)

        // "+" SF Symbol icon — centred at 24 × 24
        iconView.image         = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        iconView.imageScaling  = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .black
        iconView.alphaValue    = 0.7
        iconView.wantsLayer    = true
        addSubview(iconView)
    }

    // MARK: - Layout

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width   // 62
        let h = bounds.height  // 62

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outerLayer.frame        = CGRect(x: 0, y: 0, width: w, height: h)
        outerLayer.cornerRadius = h / 2
        outerLayer.cornerCurve  = .continuous

        // Inner: 2pt inset all sides  → 58 × 58
        let innerSize: CGFloat = 58
        let innerInset: CGFloat = 2
        innerLayer.frame        = CGRect(x: innerInset, y: innerInset,
                                          width: innerSize, height: innerSize)
        innerLayer.cornerRadius = innerSize / 2
        innerLayer.cornerCurve  = .continuous
        hoverHighlight.frame        = innerLayer.bounds
        hoverHighlight.cornerRadius = innerSize / 2
        hoverHighlight.cornerCurve  = .continuous
        pressHighlight.frame        = innerLayer.bounds
        pressHighlight.cornerRadius = innerSize / 2
        pressHighlight.cornerCurve  = .continuous
        CATransaction.commit()

        // Icon: 24 × 24, centred within the 52 × 52 button circle (inset 3+2=5 each side)
        let iconSize: CGFloat = 24
        iconView.frame = NSRect(
            x: (w - iconSize) / 2,
            y: (h - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
    }

    // MARK: - Interaction (unified hover-grow / press-shrink)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }
    // Spatial's BaseView press feel, reproduced 1:1:
    //   • hover  → spring-grow to 1.05 (their hover scale)
    //   • press  → FAST snap-down to 0.94 (~0.06s, no spring) + clickHighlight dim
    //   • release→ resetScaleWithStiffness: spring back with overshoot (.control)
    private static let pressScale: CGFloat = 0.94
    /// Release spring — Spatial's resetScale feel: a slight but felt overshoot
    /// (response 0.30, damping 0.70 ≈ ~5 % overshoot, ~0.25s settle). `.control`
    /// (damping 0.78) overshoots only ~2 % and reads as dead.
    private static let releaseSpring = CLIPSpring.Preset(response: 0.30, damping: 0.70)

    // Hover recolors the surface to flat green (Figma 72:36831) — it does NOT
    // scale. The only scale on this button is the Spatial press-down (below).
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshSkin()
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false; isPressed = false
        refreshSkin()
        CLIPSpring.scale(self, to: 1.0, preset: Self.releaseSpring, key: "xform")
        setPressHighlight(false)
    }

    /// Claim every in-bounds click so the icon subview never swallows it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        CLIPSpring.pressScale(self, to: Self.pressScale, duration: 0.07, key: "xform")
        setPressHighlight(true)
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        CLIPSpring.scale(self, to: 1.0, preset: Self.releaseSpring, key: "xform")
        setPressHighlight(false)
        if inside { onTap?() }
    }

    /// Fade the clickHighlight in (fast, on press) / out (softer, on release).
    private func setPressHighlight(_ on: Bool) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = pressHighlight.presentation()?.opacity ?? pressHighlight.opacity
        a.toValue   = on ? 1 : 0
        a.duration  = on ? 0.06 : 0.18
        a.timingFunction = CLIPSpring.easeOutSoft
        a.fillMode  = .forwards
        pressHighlight.opacity = on ? 1 : 0
        pressHighlight.add(a, forKey: "press")
    }

    // MARK: - Selected (link-input open) skin

    /// Link-input open/closed → darkened-green selected skin (Figma 72:36780).
    func setSelected(_ on: Bool) {
        guard on != isSelected else { return }
        isSelected = on
        refreshSkin()
    }

    /// Apply the correct inner surface for the current state. The gradient is
    /// darkened green only when SELECTED (input open, Figma 72:36780), otherwise
    /// candy yellow. HOVER does not change the gradient — it fades in a 40% white
    /// wash (Figma 72:36831), brightening the yellow. Outer ring stays `#3DA726`.
    private func refreshSkin() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CLIPSpring.easeOutSoft)
        innerLayer.colors = isSelected ? Self.greenSkin : Self.yellowSkin
        CATransaction.commit()
        setHoverHighlight(isHovered && !isSelected)
        iconView.alphaValue = isSelected ? 0.85 : 0.70
    }

    /// Fade the white hover wash (Figma 72:36831 — 40% white over the candy).
    private func setHoverHighlight(_ on: Bool) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = hoverHighlight.presentation()?.opacity ?? hoverHighlight.opacity
        a.toValue   = on ? 0.40 : 0
        a.duration  = 0.16
        a.timingFunction = CLIPSpring.easeOutSoft
        a.fillMode  = .forwards
        hoverHighlight.opacity = on ? 0.40 : 0
        hoverHighlight.add(a, forKey: "hover")
    }
}

// MARK: - ToolPaletteButton

/// A single 52 × 52 tool button. Three states (Figma node 72:36300):
///   • `.default`  — no background, icon black at its designed rest opacity.
///   • `.hovered`  — translucent white (40%) circle behind the icon.
///   • `.selected` — green (#3DA726) circle, icon brand-yellow (#FEF33C) + glow.
/// Hover/press/selection are all driven by the unified `CLIPSpring` motion
/// system (CASpringAnimation, `.control` preset) — no ad-hoc curves.
final class ToolPaletteButton: NSView {

    var onTap: (() -> Void)?

    /// Designed rest opacity for the icon when this tool is NOT selected (Figma:
    /// leading tools 1.0, trailing tools 0.70). It applies to the icon ONLY —
    /// the hover/selected circle always renders at full strength, matching the
    /// Figma layer model where the 0.70 lives on `icon-circle`, not the button.
    var iconRestOpacity: CGFloat = 1.0 {
        didSet { if !isActive { iconView.alphaValue = iconRestOpacity } }
    }

    private let bgLayer   = CALayer()    // hover (white 40%) / selected (green) circle
    private let iconView  = NSImageView()
    private var isActive  = false
    private var isHovered = false
    private var isPressed = false
    private let iconName: String

    // MARK: - Init

    init(iconName: String) {
        self.iconName = iconName
        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false      // let the selected-icon glow bleed past bounds

        // Background circle — hidden at rest; springs in on hover / selection.
        bgLayer.cornerCurve = .continuous
        bgLayer.opacity     = 0
        layer?.addSublayer(bgLayer)

        // Icon (template image; tinted black at rest, brand-yellow when selected).
        iconView.image            = Self.loadIcon(iconName)
        iconView.imageScaling     = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .black
        iconView.wantsLayer       = true
        iconView.layer?.masksToBounds = false
        addSubview(iconView)
    }

    // MARK: - Layout

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let sz = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.frame        = sz
        // "rounded-[60px]" in Figma means a corner radius of 60pt —
        // capped to half the button side so it never exceeds a full circle.
        bgLayer.cornerRadius = min(60, sz.height / 2)
        CATransaction.commit()

        // Icon: 24 × 24 centred in 52 × 52 → x=14, y=14  (from Figma)
        let iconSize: CGFloat = 24
        let pad: CGFloat = (bounds.width - iconSize) / 2
        iconView.frame = NSRect(x: pad, y: pad, width: iconSize, height: iconSize)
    }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if isPressed { isPressed = false; CLIPSpring.scale(self, to: 1.0, key: "press") }
        refreshBackground()
    }

    // MARK: - Press (mouse-tracked so the press-shrink can spring)

    /// Claim every in-bounds click so the icon subview never swallows it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        CLIPSpring.scale(self, to: 0.94, key: "press")     // unified press-shrink
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        CLIPSpring.scale(self, to: 1.0, key: "press")
        if inside { onTap?() }
    }

    // MARK: - Selected state

    func setActive(_ active: Bool, animated: Bool) {
        guard active != isActive else { return }
        isActive = active
        iconView.alphaValue       = active ? 1.0 : iconRestOpacity
        iconView.contentTintColor = active ? NSColor.fromHex(0xFEF33C) : .black
        applyGlow(active)
        refreshBackground(animated: animated)
    }

    // MARK: - Background circle (selected beats hover beats hidden)

    private func refreshBackground(animated: Bool = true) {
        let opacity: CGFloat
        if isActive {
            bgLayer.backgroundColor = NSColor.fromHex(0x3DA726).cgColor
            opacity = 1
        } else if isHovered {
            bgLayer.backgroundColor = NSColor.white.withAlphaComponent(0.40).cgColor
            opacity = 1
        } else {
            opacity = 0                 // keep the last colour so the fade-out is visible
        }
        if animated {
            CLIPSpring.animate(bgLayer, "opacity", to: opacity, preset: .control, key: "bg")
        } else {
            bgLayer.removeAnimation(forKey: "bg")
            bgLayer.opacity = Float(opacity)
        }
    }

    /// Selected icon gets a soft white halo (Figma: white@70%, blur ~10pt).
    private func applyGlow(_ on: Bool) {
        guard let l = iconView.layer else { return }
        l.shadowColor   = NSColor.white.cgColor
        l.shadowOffset  = .zero
        l.shadowRadius  = on ? 5 : 0
        l.shadowOpacity = on ? 0.7 : 0
    }

    // MARK: - Icon mapping

    /// Returns a 24 × 24 template image for a tool mode.
    /// Uses SF Symbols where possible; falls back to a constructed path image.
    /// Loads a 24×24 template icon (`tool_*.svg`) from the bundle.
    static func loadIcon(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true   // the button tints it black (idle) / yellow (active)
        img.size = NSSize(width: 24, height: 24)
        return img
    }

}

// MARK: - SwiftUI mounting

/// `NSViewRepresentable` that wires `CanvasToolPaletteView` to `CanvasState`.
/// CanvasView mounts this in an `.overlay(alignment: .bottom)` with an explicit
/// `.frame(width: totalW, height: totalH)` so the shadow bleed is honored.
///
/// `toolMode` and `isAddSelected` are stored as value-type fields so SwiftUI
/// can diff them across renders and guarantee `updateNSView` fires on change.
/// Without this, `state` is a reference type — same pointer each render —
/// and SwiftUI skips the update, leaving the "+" button stuck yellow.
struct _PaletteRepresentable: NSViewRepresentable {
    let state: CanvasState
    let toolMode: ToolMode
    let isAddSelected: Bool

    init(state: CanvasState) {
        self.state        = state
        self.toolMode     = state.toolMode
        self.isAddSelected = state.isLinkInputPresented
    }

    func makeNSView(context: Context) -> CanvasToolPaletteView {
        let v = CanvasToolPaletteView()
        v.configure(active: toolMode)
        v.setAddSelected(isAddSelected)
        wireCallbacks(v, state: state)
        return v
    }

    func updateNSView(_ nsView: CanvasToolPaletteView, context: Context) {
        nsView.configure(active: toolMode)
        nsView.setAddSelected(isAddSelected)
        wireCallbacks(nsView, state: state)
    }

    private func wireCallbacks(_ v: CanvasToolPaletteView, state: CanvasState) {
        v.onToolTap = { mode in
            // The Marker prop = Draw, with the yellow/amber marker colour.
            if mode == .draw { state.drawColor = .amber }
            withAnimation(Motion.feedback) { state.toolMode = mode }
        }
        v.onFolderTap = { state.addFolder() }   // the Folder button
        // "+" toggles the inline link input (Figma 72:36784); its green
        // selected skin follows `isLinkInputPresented`.
        v.onAddTap = {
            withAnimation(Motion.pop) { state.isLinkInputPresented.toggle() }
        }
    }

    func makeCoordinator() -> Void { }
}

// MARK: - NSColor hex helper

private extension NSColor {
    /// Initialise from a 0xRRGGBB integer literal, sRGB colour space.
    static func fromHex(_ hex: UInt32) -> NSColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >>  8) & 0xFF) / 255
        let b = CGFloat( hex        & 0xFF) / 255
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
}
