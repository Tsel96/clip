import AppKit
import SwiftUI

// MARK: - NativeCanvasTopSegmentedControl  (public SwiftUI bridge)

/// Mounts the candy-green Canvas / Colorform / Archive segmented control at the
/// top-center of the canvas — the mirror of the bottom tool palette.
///
/// Pixel-1:1 with Figma node 73:37182 ("SegmentedControl"). All rendering is
/// native AppKit (CALayer fills, gradients, inner/outer shadows) so corner
/// radii, the recessed trough shadow, the floating indicator pill, and the
/// 0.22 s slide animation are precise — no SwiftUI geometry mangling.
///
/// Usage (CanvasView.swift):
///   `NativeCanvasTopSegmentedControl(state: state)`
///     `.frame(width: CanvasTopSegmentedControlView.totalW,`
///     `       height: CanvasTopSegmentedControlView.totalH)`
typealias NativeCanvasTopSegmentedControl = _TopSegmentedRepresentable

// MARK: - CanvasTopSegmentedControlView

/// The 357 × 50 segmented control.
///
/// Visual hierarchy (bottom → top):
///   1. segment-trough — green (#3DA726) recessed pill (349×42 @ 4,4) with a
///      5-layer inner shadow (#001400) that draws the pressed-in look.
///   2. indicator — the floating candy-yellow pill (gradient #FFF53B → #F8DE47,
///      1 pt #FFFCA9 top rim, layered drop shadow) that SLIDES between segments.
///   3. Three text labels — SF Mono SemiBold 17pt uppercase. The active label is
///      black α0.90 with an embossed text shadow; inactive are white α0.40.
///
/// Hit-testing: three always-full-size transparent NSButton-like zones own the
/// clicks; the indicator is purely decorative (Figma's recommended pattern).
final class CanvasTopSegmentedControlView: NSView {

    // MARK: Geometry (Figma 73:37182 — exact pt values)

    static let totalW: CGFloat = 357
    static let totalH: CGFloat = 50

    /// segment-trough: 349 × 42 @ (4, 4) inside the 357 × 50 frame.
    private static let troughInsetX: CGFloat = 4
    private static let troughInsetY: CGFloat = 4
    private static let troughW: CGFloat = 349   // 357 - 4*2
    private static let troughH: CGFloat = 42    // 50  - 4*2

    /// Indicator / hit-zone frames per tab (absolute inside the 357×50 view,
    /// y = 2, height 46 — flush, 0-gap). Index-matched to `CanvasMode` order
    /// (canvas, colorform, archive).
    private static let segmentFrames: [NSRect] = [
        NSRect(x: 2,   y: 2, width: 104, height: 46),   // canvas
        NSRect(x: 106, y: 2, width: 135, height: 46),   // colorform
        NSRect(x: 241, y: 2, width: 114, height: 46),   // archive
    ]

    // MARK: Sub-layers / sub-views

    /// Recessed green trough fill (the inner shadow lives in `troughShadows`).
    private let troughLayer = CALayer()
    /// 5 stacked inner-shadow casters that draw the trough's pressed-in look.
    private let troughShadows: [CALayer]

    /// Floating candy-yellow indicator pill (slides between segments).
    private let indicator = SegmentIndicatorView()

    /// 10%-white hover wash shown behind an INACTIVE segment's label on hover
    /// (Figma 93:654 "Hovered state"). One reusable view that moves to the hovered
    /// segment; hidden when none is hovered or the hovered one is selected.
    private let hoverWash = NSView()
    private var hoveredIndex: Int?

    /// Three transparent click zones (always full segment size).
    private var hitZones: [SegmentHitZone] = []
    /// Three text labels (index-matched to CanvasMode order).
    private var labels: [NSTextField] = []

    /// Currently-selected segment (CanvasMode rawValue order: 0/1/2).
    private(set) var selectedIndex: Int = 0

    /// Fired when the user taps a segment. Argument = the segment index.
    var onSelect: ((Int) -> Void)?

    private static let titles = ["CANVAS", "COLORFORM", "ARCHIVE"]

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        self.troughShadows = Self.makeTroughInnerShadowLayers()
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        self.troughShadows = Self.makeTroughInnerShadowLayers()
        super.init(coder: coder)
        commonInit()
    }

    override var isFlipped: Bool { true }   // Y=0 at top, matching Figma coords

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false

        // --- segment-trough (green recessed pill) ---
        troughLayer.backgroundColor = NSColor.fromHex(0x3DA726).cgColor
        troughLayer.cornerCurve = .continuous
        troughLayer.masksToBounds = true            // clip the inner-shadow casters
        layer?.addSublayer(troughLayer)
        troughShadows.forEach { troughLayer.addSublayer($0) }

        // --- indicator (floating candy pill) — behind the labels ---
        addSubview(indicator)

        // --- hover wash (above trough, below labels) ---
        hoverWash.wantsLayer = true
        hoverWash.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        hoverWash.layer?.cornerCurve = .continuous
        hoverWash.layer?.opacity = 0
        addSubview(hoverWash)

        // --- labels + hit zones ---
        for (i, title) in Self.titles.enumerated() {
            let label = Self.makeLabel(title)
            addSubview(label)
            labels.append(label)

            let zone = SegmentHitZone()
            zone.onTap = { [weak self] in self?.handleTap(i) }
            zone.onHover = { [weak self] entered in self?.handleHover(i, entered) }
            addSubview(zone)
            hitZones.append(zone)
        }

        applySelectionStyling(animated: false)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Trough fill.
        let trough = NSRect(x: Self.troughInsetX, y: Self.troughInsetY,
                            width: Self.troughW, height: Self.troughH)
        troughLayer.frame = trough
        troughLayer.cornerRadius = Self.troughH / 2     // 21 → "999" fully round

        // Inner-shadow casters fill the trough; each is offset by its level so
        // the masked-out shadow falls inward (recessed look). `troughLayer`
        // clips, so only the inset shadow edge shows.
        Self.layoutTroughInnerShadows(troughShadows,
                                      bounds: troughLayer.bounds,
                                      radius: Self.troughH / 2)
        CATransaction.commit()

        // Indicator + labels + hit zones, per segment frame. Don't snap the
        // indicator mid-slide (that would cancel the spring).
        if !isSliding { indicator.frame = Self.segmentFrames[selectedIndex] }
        for (i, frame) in Self.segmentFrames.enumerated() {
            hitZones[i].frame = frame
            centerLabel(i)
        }
    }

    /// Size each label to its text and center it BOTH axes in its segment — an
    /// NSTextField left at the full 46pt-tall frame top-aligns the single line
    /// (the "labels broken inside" bug). Re-run on relayout + restyle.
    private func centerLabel(_ i: Int) {
        guard i < labels.count else { return }
        labels[i].sizeToFit()
        let f = Self.segmentFrames[i]
        let s = labels[i].frame.size
        labels[i].frame = NSRect(x: (f.midX - s.width / 2).rounded(),
                                 y: (f.midY - s.height / 2).rounded(),
                                 width: ceil(s.width), height: ceil(s.height))
    }

    /// Instant centered scale (the "press-down" before a spring-back pop).
    private static func setCenteredScale(_ v: NSView, _ s: CGFloat) {
        guard let l = v.layer else { return }
        let ap = l.anchorPoint
        let c = CGPoint(x: l.bounds.width * (0.5 - ap.x), y: l.bounds.height * (0.5 - ap.y))
        let t = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-c.x, -c.y, 0),
                                CATransform3DMakeScale(s, s, 1)),
            CATransform3DMakeTranslation(c.x, c.y, 0))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.transform = t
        CATransaction.commit()
    }

    // MARK: - Selection

    /// Programmatically set the selection (e.g. when `state.canvasMode` changes
    /// from elsewhere). Slides the indicator with the Figma 0.22 s animation.
    func setSelectedIndex(_ index: Int, animated: Bool) {
        guard index >= 0, index < Self.segmentFrames.count else { return }
        guard index != selectedIndex else { return }
        selectedIndex = index
        moveIndicator(to: index, animated: animated)
        applySelectionStyling(animated: animated)
        updateHoverWash(animated: animated)   // hide the wash if it's now the active tab
    }

    // MARK: - Hover wash (Figma 93:654)

    private func handleHover(_ index: Int, _ entered: Bool) {
        if entered { hoveredIndex = index }
        else if hoveredIndex == index { hoveredIndex = nil }
        updateHoverWash(animated: true)
    }

    /// Show the 10%-white wash behind the hovered INACTIVE segment (h=42 centred,
    /// 2 pt inset each side, fully rounded — Figma 93:654). Fades in/out.
    private func updateHoverWash(animated: Bool) {
        let show = hoveredIndex.map { $0 != selectedIndex } ?? false
        if show, let i = hoveredIndex {
            let f = Self.segmentFrames[i].insetBy(dx: 2, dy: 2)   // 46→42 tall, w−4
            CATransaction.begin(); CATransaction.setDisableActions(true)
            hoverWash.frame = f
            hoverWash.layer?.cornerRadius = f.height / 2
            CATransaction.commit()
        }
        let target: Float = show ? 1 : 0
        guard (hoverWash.layer?.opacity ?? 0) != target else { return }
        if animated {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = hoverWash.layer?.presentation()?.opacity ?? hoverWash.layer?.opacity
            a.toValue = target
            a.duration = 0.15
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverWash.layer?.add(a, forKey: "fade")
        }
        hoverWash.layer?.opacity = target
    }

    private func handleTap(_ index: Int) {
        clickPop()                       // tactile "click" feedback on every tap
        guard index != selectedIndex else { return }
        // Drive the visual change immediately for snappy feedback; the state
        // round-trip via `onSelect` keeps us authoritative.
        setSelectedIndex(index, animated: true)
        onSelect?(index)
    }

    /// A quick spring-back pop on the indicator = the "click" feedback (global
    /// motion). Press down instantly, then spring to full with a little overshoot.
    private func clickPop() {
        Self.setCenteredScale(indicator, 0.93)
        CLIPSpring.scale(indicator, to: 1.0, preset: .settle, key: "clickPop")
    }

    /// Slide the indicator to a segment with a snappy, springy overshoot (global
    /// motion `CLIPSpring.popOut`) instead of the old flat easeInEaseOut. The
    /// implicit animation carries the pill's sublayers (gradient + shadow) along.
    private var isSliding = false
    private func moveIndicator(to index: Int, animated: Bool) {
        let target = Self.segmentFrames[index]
        if animated {
            isSliding = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.34
                ctx.timingFunction = CLIPSpring.popOut
                ctx.allowsImplicitAnimation = true
                indicator.animator().frame = target
            }, completionHandler: { [weak self] in self?.isSliding = false })
        } else {
            indicator.frame = target
        }
    }

    /// Active label = black α0.90 + embossed shadow; inactive = white α0.40.
    private func applySelectionStyling(animated: Bool) {
        for (i, label) in labels.enumerated() {
            label.attributedStringValue = Self.attributedTitle(
                Self.titles[i], active: i == selectedIndex)
            centerLabel(i)              // keep centred (active label's shadow changes the fit)
        }
    }

    // MARK: - Label factory

    /// SF Mono SemiBold 17 pt — `NSFont.monospacedSystemFont(.semibold)`.
    private static let labelFont =
        NSFont.monospacedSystemFont(ofSize: 17, weight: .semibold)

    private static func makeLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = labelFont
        label.alignment = .center
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.usesSingleLineMode = true
        label.wantsLayer = true
        // NSTextField is single-line vertically-centered by default; combined
        // with .center alignment this matches Figma's centered flex.
        return label
    }

    /// Builds the per-state attributed title (color, alpha, embossed shadow).
    /// Active: #000000 α0.90 + 4-layer text shadow (simplified to one NSShadow).
    /// Inactive: #FFFFFF α0.40, no shadow (per Figma React + screenshot).
    private static func attributedTitle(_ title: String, active: Bool) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .kern: 0,   // SF Mono is already monospaced; no extra tracking
        ]
        if active {
            attrs[.foregroundColor] = NSColor.black.withAlphaComponent(0.90)
            // Figma "ACTIVE LABEL TEXT SHADOW" — 4 passes collapsed to the
            // perceptually-equivalent single NSShadow (down = -Y when flipped).
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 1.5
            attrs[.shadow] = shadow
        } else {
            attrs[.foregroundColor] = NSColor.white.withAlphaComponent(0.40)
        }
        return NSAttributedString(string: title, attributes: attrs)
    }

    // MARK: - Trough inner shadow (Figma 5-layer #001400)

    /// 5-pass inner shadow from the Figma spec, top → bottom (the 0-alpha
    /// 26-px level is dropped). Drawn as inset shadows via masked casters
    /// clipped by `troughLayer.masksToBounds`.
    ///   #001400 a=0.11 off=(0,1)  blur=2
    ///   #001400 a=0.10 off=(0,4)  blur=4
    ///   #001400 a=0.06 off=(0,9)  blur=6
    ///   #001400 a=0.02 off=(0,17) blur=7
    private struct InnerShadowLevel {
        let y: CGFloat; let blur: CGFloat; let alpha: Float
    }
    private static let troughShadowLevels: [InnerShadowLevel] = [
        .init(y: 1,  blur: 2, alpha: 0.11),
        .init(y: 4,  blur: 4, alpha: 0.10),
        .init(y: 9,  blur: 6, alpha: 0.06),
        .init(y: 17, blur: 7, alpha: 0.02),
    ]
    /// #001400 — the trough shadow's near-black green tint.
    private static let troughShadowColor =
        NSColor(srgbRed: 0, green: 20.0 / 255, blue: 0, alpha: 1).cgColor

    /// Builds the inner-shadow caster layers. Each uses an even-odd path that
    /// fills a large outer rect with a punched-out hole the size/shape of the
    /// trough — so the shadow it casts falls *inward* through the hole, giving
    /// the recessed look once `troughLayer` clips the overflow.
    private static func makeTroughInnerShadowLayers() -> [CALayer] {
        troughShadowLevels.map { level in
            let l = CAShapeLayer()
            l.fillRule = .evenOdd
            l.fillColor = NSColor.black.cgColor    // the shape itself; shadow tints
            l.shadowColor = troughShadowColor
            l.shadowOpacity = level.alpha
            l.shadowRadius = level.blur
            l.shadowOffset = .zero                 // offset baked into the path
            l.masksToBounds = false
            return l
        }
    }

    /// Positions/redraws the inner-shadow casters for the current trough bounds.
    private static func layoutTroughInnerShadows(_ layers: [CALayer],
                                                 bounds: CGRect,
                                                 radius: CGFloat) {
        let pad: CGFloat = 40
        for (i, layer) in layers.enumerated() {
            guard let shape = layer as? CAShapeLayer else { continue }
            shape.frame = bounds
            let level = troughShadowLevels[i]
            // Even-odd ring = (outer rect) − (FULL trough pill). The filled body
            // lands entirely OUTSIDE the trough, so `troughLayer.masksToBounds`
            // clips it away and only the ring's INNER shadow shows — biased
            // downward by the shadow OFFSET. (Offsetting the HOLE instead exposed
            // the caster's black body as a band across the trough top — the bug.)
            let path = CGMutablePath()
            path.addRect(CGRect(x: -pad, y: -pad,
                                width: bounds.width + pad * 2, height: bounds.height + pad * 2))
            path.addRoundedRect(in: bounds, cornerWidth: radius, cornerHeight: radius)
            shape.path = path
            shape.shadowOffset = CGSize(width: 0, height: level.y)   // +Y = down (flipped)
        }
    }
}

// MARK: - SegmentIndicatorView  (the floating candy-yellow pill)

/// The lifted active-segment pill: gradient #FFF53B → #F8DE47, 1 pt #FFFCA9 top
/// rim, layered black drop shadow. Corner radius fully rounded.
private final class SegmentIndicatorView: NSView {

    private let shadowLayers: [CALayer]
    private let bodyLayer = CAGradientLayer()

    /// Figma drop shadow on the indicator (4 passes, floating elevation):
    ///   #000000 a=0.15 off=(0,0) blur=1
    ///   #000000 a=0.13 off=(0,1) blur=1
    ///   #000000 a=0.08 off=(0,3) blur=2
    ///   #000000 a=0.02 off=(0,6) blur=2
    private struct ShadowLevel { let y: CGFloat; let blur: CGFloat; let alpha: Float }
    private static let shadowLevels: [ShadowLevel] = [
        .init(y: 0, blur: 1, alpha: 0.15),
        .init(y: 1, blur: 1, alpha: 0.13),
        .init(y: 3, blur: 2, alpha: 0.08),
        .init(y: 6, blur: 2, alpha: 0.02),
    ]

    override init(frame frameRect: NSRect) {
        self.shadowLayers = Self.makeShadowLayers()
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        self.shadowLayers = Self.makeShadowLayers()
        super.init(coder: coder)
        commonInit()
    }

    override var isFlipped: Bool { true }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false

        // Shadow casters behind the body.
        shadowLayers.forEach { $0.zPosition = -1; layer?.addSublayer($0) }

        // Body gradient + pale top rim, identical recipe to the bottom palette:
        // a crisp 4-stop vertical gradient paints the 1 pt #FFFCA9 rim only on
        // the rounded top edge, never the sides/bottom.
        bodyLayer.colors = [
            NSColor.fromHex(0xFFFCA9).cgColor,   // pale top rim
            NSColor.fromHex(0xFFFCA9).cgColor,
            NSColor.fromHex(0xFFF53B).cgColor,   // body top
            NSColor.fromHex(0xF8DE47).cgColor,   // body bottom
        ]
        bodyLayer.startPoint = CGPoint(x: 0.5, y: 0)
        bodyLayer.endPoint   = CGPoint(x: 0.5, y: 1)
        bodyLayer.masksToBounds = true
        bodyLayer.cornerCurve = .continuous
        layer?.addSublayer(bodyLayer)
    }

    override func layout() {
        super.layout()
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        bodyLayer.frame = b
        let r = b.height / 2                       // 23 → "50"/fully round
        bodyLayer.cornerRadius = r
        // Rim ≈ 2 pt of the 46 pt pill → 2/46 ≈ 0.0435 (two stops at the top).
        let rimFrac = 2.0 / max(b.height, 1)
        bodyLayer.locations = [0.0, NSNumber(value: rimFrac),
                               NSNumber(value: rimFrac), 1.0]

        // Drop-shadow casters: a clear layer per level, shadow from shadowPath.
        // This is a FLIPPED view (+Y = down), so the Figma positive-Y offsets cast
        // the shadow DOWNWARD by offsetting the caster +Y (was −Y → shadow pointed up).
        let path = CGPath(roundedRect: CGRect(origin: .zero, size: b.size),
                          cornerWidth: r, cornerHeight: r, transform: nil)
        for (i, l) in shadowLayers.enumerated() {
            l.frame = b.offsetBy(dx: 0, dy: Self.shadowLevels[i].y)
            l.shadowPath = path
        }
        CATransaction.commit()
    }

    private static func makeShadowLayers() -> [CALayer] {
        shadowLevels.map { level in
            let l = CALayer()
            l.backgroundColor = NSColor.clear.cgColor
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = level.alpha
            l.shadowRadius = level.blur
            l.shadowOffset = .zero
            l.masksToBounds = false
            return l
        }
    }
}

// MARK: - SegmentHitZone  (transparent always-full-size click target)

/// A transparent click target over one segment. Claims every in-bounds click so
/// the indicator/labels never swallow it; fires `onTap` on mouse-up-in-bounds.
private final class SegmentHitZone: NSView {
    var onTap: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInActiveApp],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    // No cursor rect — a pointing-hand here fought the canvas cursorUpdate (blink).
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) { /* accept; fire on mouse-up */ }
    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) { onTap?() }
    }
}

// MARK: - SwiftUI mounting

/// `NSViewRepresentable` wiring `CanvasTopSegmentedControlView` to `CanvasState`.
/// The three segments map 1:1 onto `CanvasMode` (canvas/colorform/archive); a
/// tap calls `state.setMode(_:)`, and external mode changes flow back into the
/// indicator via `updateNSView`.
struct _TopSegmentedRepresentable: NSViewRepresentable {
    let state: CanvasState
    /// Value field so SwiftUI diffs it → `updateNSView` fires on EXTERNAL mode
    /// changes (e.g. tapping an Archive row jumps to canvas). Without this the
    /// reference-type `state` looks identical every render and the indicator
    /// stays stuck on the old segment.
    let mode: CanvasMode

    init(state: CanvasState) {
        self.state = state
        self.mode = state.canvasMode
    }

    func makeNSView(context: Context) -> CanvasTopSegmentedControlView {
        let v = CanvasTopSegmentedControlView()
        v.setSelectedIndex(Self.index(for: mode), animated: false)
        v.onSelect = { idx in
            let m = Self.mode(for: idx)
            withAnimation(Motion.feedback) { state.setMode(m) }
        }
        return v
    }

    func updateNSView(_ nsView: CanvasTopSegmentedControlView, context: Context) {
        // Re-wire (captures the current `state`) and reflect external changes.
        nsView.onSelect = { idx in
            let m = Self.mode(for: idx)
            withAnimation(Motion.feedback) { state.setMode(m) }
        }
        nsView.setSelectedIndex(Self.index(for: mode), animated: true)
    }

    func makeCoordinator() -> Void { }

    // CanvasMode.allCases order is [canvas, colorform, archive] — matches the
    // segment frame order exactly.
    private static func index(for mode: CanvasMode) -> Int {
        switch mode {
        case .canvas:    return 0
        case .colorform: return 1
        case .archive:   return 2
        }
    }
    private static func mode(for index: Int) -> CanvasMode {
        switch index {
        case 1:  return .colorform
        case 2:  return .archive
        default: return .canvas
        }
    }
}

// MARK: - NSColor hex helper

private extension NSColor {
    /// Initialise from a 0xRRGGBB integer literal, sRGB colour space.
    static func fromHex(_ hex: UInt32) -> NSColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >>  8) & 0xFF) / 255
        let b = CGFloat( hex        & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
