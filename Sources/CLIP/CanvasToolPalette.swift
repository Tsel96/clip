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

    /// Callback injected by `configure(active:onTap:)`.
    var onToolTap: ((ToolMode) -> Void)?
    var onAddTap: (() -> Void)?

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

        addSubview(mainPill)
        addSubview(addPill)

        mainPill.onToolTap = { [weak self] tool in self?.onToolTap?(tool) }
        addPill.onTap      = { [weak self] in self?.onAddTap?() }
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
    static let propOverflow: CGFloat = 14   // above the pill
    static let shadowBleed: CGFloat  = 20   // below / sides for shadow room
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
    }

    // MARK: - State

    func configure(active: ToolMode) {
        mainPill.configure(active: active)
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
/// fully transparent in Figma and omitted):
///   0 2  1.5 rgba(0,92,2,0.12)
///   0 6  3   rgba(0,92,2,0.10)
///   0 14 4   rgba(0,92,2,0.06)
///   0 24 5   rgba(0,92,2,0.02)
private let candyShadowLevels: [CandyShadowLevel] = [
    .init(y: 2,  blur: 1.5, alpha: 0.12),
    .init(y: 6,  blur: 3,   alpha: 0.10),
    .init(y: 14, blur: 4,   alpha: 0.06),
    .init(y: 24, blur: 5,   alpha: 0.02),
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

/// Positions the shadow layers over `capsule`. Each layer's FRAME is offset
/// downward by its level's Y using the same convention as the green capsule's
/// frame (verified Y-down in these flipped hosts: `outerLayer.frame.y = pillTopY`
/// renders the pill at the bottom). The shadowPath is just the layer's own
/// bounds, so we never depend on `geometryFlipped` path orientation.
private func layoutCandyShadows(_ layers: [CALayer], capsule: CGRect, radius: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let path = CGPath(
        roundedRect: CGRect(origin: .zero, size: capsule.size),
        cornerWidth: radius, cornerHeight: radius, transform: nil
    )
    for (i, l) in layers.enumerated() {
        l.frame = capsule.offsetBy(dx: 0, dy: candyShadowLevels[i].y)
        l.shadowPath = path
    }
    CATransaction.commit()
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
    // First button (index 0) is active — rendered with green pill bg.
    // buttonModes maps index → ToolMode.
    private static let buttonModes: [ToolMode] =
        [.select, .draw, .text, .stickyNote, .connect]

    // Decorative prop positions (in inner capsule coords, Y from top of inner capsule)
    // Marker:   x=129, y=-10  (overflows above rim by 10+innerTop=12)
    // Stickers: x=195, y=-6   (overflows above rim by 6+innerTop=8)
    // Both clip to the inner capsule rect horizontally but overflow top.
    private static let markerX: CGFloat   = 129
    private static let markerY: CGFloat   = -10   // in inner capsule local Y (negative = above)
    private static let stickersX: CGFloat = 195
    private static let stickersY: CGFloat = -6

    // MARK: Layers

    private let shadowLayers = makeCandyShadowLayers() // 4-level green drop-shadow
    private let outerLayer   = CALayer()      // green border
    private let innerLayer   = CAGradientLayer() // yellow gradient
    private let rimLayer     = CALayer()      // top highlight rim

    // Tool button views (index-matched to buttonModes)
    private var buttonViews: [ToolPaletteButton] = []

    // Decorative prop image views
    private let markerView   = NSImageView()
    private let stickersView = NSImageView()

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

        // --- Layered green drop-shadow (behind the capsule) ---
        shadowLayers.forEach { layer?.addSublayer($0) }

        // --- Outer green border layer ---
        outerLayer.backgroundColor  = NSColor.fromHex(0x3DA726).cgColor
        outerLayer.masksToBounds    = false
        layer?.addSublayer(outerLayer)

        // --- Inner yellow gradient ---
        innerLayer.colors = [
            NSColor.fromHex(0xFFF53B).cgColor,
            NSColor.fromHex(0xF8DE47).cgColor
        ]
        innerLayer.startPoint = CGPoint(x: 0.5, y: 0)
        innerLayer.endPoint   = CGPoint(x: 0.5, y: 1)
        innerLayer.borderColor = NSColor.fromHex(0xFFFCA9).cgColor
        innerLayer.borderWidth = 2
        innerLayer.masksToBounds = true
        outerLayer.addSublayer(innerLayer)

        // --- Tool buttons ---
        for (i, mode) in Self.buttonModes.enumerated() {
            let btn = ToolPaletteButton(mode: mode)
            btn.layer?.opacity = Float(Self.buttonOpacities[i])
            btn.onTap = { [weak self] in self?.onToolTap?(mode) }
            addSubview(btn)
            buttonViews.append(btn)
        }

        // --- Decorative props ---
        if let img = NSImage(named: "Marker") ??
            loadBundleImage(named: "Marker") {
            markerView.image = img
            markerView.imageScaling = .scaleAxesIndependently
        }
        markerView.wantsLayer = true
        addSubview(markerView)

        if let img = NSImage(named: "Stickers") ??
            loadBundleImage(named: "Stickers") {
            stickersView.image = img
            stickersView.imageScaling = .scaleAxesIndependently
        }
        stickersView.wantsLayer = true
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

        // Layered drop-shadow tracks the green capsule rect.
        layoutCandyShadows(
            shadowLayers,
            capsule: CGRect(x: 0, y: pillTopY, width: bounds.width, height: pillH),
            radius: pillH / 2
        )

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
            let isActive = (Self.buttonModes[i] == active)
            btn.setActive(isActive, animated: true)
            // Inactive buttons at designed opacity; active one is fully opaque
            btn.layer?.opacity = isActive ? 1.0 : Float(Self.buttonOpacities[i])
        }
    }
}

// MARK: - AddPillView

/// The round (62 × 62) "+" candy pill — same green/yellow skin, contains a
/// "+" icon at 70% opacity. Fires `onTap` (wired to section creation).
private final class AddPillView: NSView {

    var onTap: (() -> Void)?

    private let shadowLayers = makeCandyShadowLayers()
    private let outerLayer = CALayer()
    private let innerLayer = CAGradientLayer()
    private let iconView   = NSImageView()

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

        shadowLayers.forEach { layer?.addSublayer($0) }

        outerLayer.backgroundColor = NSColor.fromHex(0x3DA726).cgColor
        outerLayer.masksToBounds   = false
        layer?.addSublayer(outerLayer)

        innerLayer.colors = [
            NSColor.fromHex(0xFFF53B).cgColor,
            NSColor.fromHex(0xF8DE47).cgColor
        ]
        innerLayer.startPoint = CGPoint(x: 0.5, y: 0)
        innerLayer.endPoint   = CGPoint(x: 0.5, y: 1)
        innerLayer.borderColor = NSColor.fromHex(0xFFFCA9).cgColor
        innerLayer.borderWidth = 2
        innerLayer.masksToBounds = true
        outerLayer.addSublayer(innerLayer)

        // "+" SF Symbol icon — centred at 24 × 24
        iconView.image         = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        iconView.imageScaling  = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .black
        iconView.alphaValue    = 0.7
        iconView.wantsLayer    = true
        addSubview(iconView)

        // Click tracking
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
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

        layoutCandyShadows(shadowLayers,
                           capsule: CGRect(x: 0, y: 0, width: w, height: h),
                           radius: h / 2)

        // Inner: 2pt inset all sides  → 58 × 58
        let innerSize: CGFloat = 58
        let innerInset: CGFloat = 2
        innerLayer.frame        = CGRect(x: innerInset, y: innerInset,
                                          width: innerSize, height: innerSize)
        innerLayer.cornerRadius = innerSize / 2
        innerLayer.cornerCurve  = .continuous
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

    // MARK: - Interaction

    @objc private func handleClick(_ gr: NSClickGestureRecognizer) {
        guard gr.state == .ended else { return }
        onTap?()
    }
}

// MARK: - ToolPaletteButton

/// A single 52 × 52 tool button.  Active state = green (#3DA726) filled
/// capsule behind the icon; inactive = no background, icon at designed opacity.
final class ToolPaletteButton: NSView {

    let mode: ToolMode
    var onTap: (() -> Void)?

    private let bgLayer   = CALayer()
    private let iconView  = NSImageView()
    private var isActive  = false

    // MARK: - Init

    init(mode: ToolMode) {
        self.mode = mode
        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func commonInit() {
        wantsLayer = true

        // Green active-state background (hidden until active)
        bgLayer.backgroundColor = NSColor.fromHex(0x3DA726).cgColor
        bgLayer.cornerCurve     = .continuous
        bgLayer.opacity         = 0
        layer?.addSublayer(bgLayer)

        // Icon
        iconView.image            = iconImage(for: mode)
        iconView.imageScaling     = .scaleProportionallyUpOrDown
        iconView.contentTintColor = nil  // SVG icons carry their own colour
        iconView.wantsLayer       = true
        addSubview(iconView)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
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

    // MARK: - Active state

    func setActive(_ active: Bool, animated: Bool) {
        guard active != isActive else { return }
        isActive = active
        if animated {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = bgLayer.presentation()?.opacity ?? (active ? 0 : 1)
            anim.toValue   = active ? 1.0 : 0.0
            anim.duration  = 0.18
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bgLayer.add(anim, forKey: "opacityAnim")
        }
        bgLayer.opacity = active ? 1.0 : 0.0

        // Active icon uses yellow so it pops against the green background;
        // inactive icon uses black.
        iconView.contentTintColor = active ? NSColor.fromHex(0xFEF33C) : NSColor.black
    }

    // MARK: - Interaction

    @objc private func handleClick(_ gr: NSClickGestureRecognizer) {
        guard gr.state == .ended else { return }
        onTap?()
    }

    // MARK: - Icon mapping

    /// Returns a 24 × 24 template image for a tool mode.
    /// Uses SF Symbols where possible; falls back to a constructed path image.
    private func iconImage(for mode: ToolMode) -> NSImage? {
        let name: String
        switch mode {
        case .select:     name = "tool_select"     // the Figma cursor
        case .draw:       name = "tool_hand"       // hand / pan
        case .text:       name = "tool_text"       // serif "T"
        case .stickyNote: name = "tool_folder"     // 4th tool = folder
        case .connect:    name = "tool_connect"    // headphone-style connector
        case .section:    name = "tool_plus"
        }
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
struct _PaletteRepresentable: NSViewRepresentable {
    let state: CanvasState

    func makeNSView(context: Context) -> CanvasToolPaletteView {
        let v = CanvasToolPaletteView()
        v.configure(active: state.toolMode)
        wireCallbacks(v, state: state)
        return v
    }

    func updateNSView(_ nsView: CanvasToolPaletteView, context: Context) {
        nsView.configure(active: state.toolMode)
        wireCallbacks(nsView, state: state)
    }

    private func wireCallbacks(_ v: CanvasToolPaletteView, state: CanvasState) {
        v.onToolTap = { mode in
            // The 4th tool carries the folder icon — it CREATES a folder
            // (the user's ask) rather than entering a placement mode.
            if mode == .stickyNote {
                state.addFolder()
            } else {
                withAnimation(Motion.feedback) { state.toolMode = mode }
            }
        }
        v.onAddTap = {
            withAnimation(Motion.feedback) { state.toolMode = .section }
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
