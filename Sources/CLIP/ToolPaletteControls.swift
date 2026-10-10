import AppKit

// The individual controls of the candy tool palette (`CanvasToolPaletteView`
// in CanvasToolPalette.swift): the tool buttons, the Marker / Sticky props and
// the "+" pill. Split out of that file to keep it navigable; behaviour is
// unchanged.

// MARK: - PropButton

/// A clickable decorative prop (Marker / Stickers). `NSImageView` swallows the
/// mouse-down before a gesture recognizer can fire, so the props were dead; this
/// plain view claims every in-bounds click via `hitTest` + fires `onTap` on
/// mouse-up, making the prop a reliable tool button.
final class PropButton: NSView {
    var onTap: (() -> Void)?

    // MARK: Accessibility — a custom NSView is invisible to VoiceOver unless
    // it says what it is. Exposed as a pressable button with a name (which
    // doubles as the hover tooltip).
    var accessibilityName = "" { didSet { toolTip = accessibilityName } }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityName }
    override func accessibilityPerformPress() -> Bool { onTap?(); return onTap != nil }
    private let imageView = NSImageView()        // rest / base art
    private let hoverImageView = NSImageView()   // hover art, crossfaded over base
    private let selectedImageView = NSImageView() // marker selected art (lifted + glow)
    private var isActive  = false
    private var isHovered = false
    private var isPressed = false
    /// When true the prop has distinct rest/hover ARTWORK that crossfades
    /// (the sticky button) — and it has NO active state and no hover-grow; the
    /// art itself carries the state. When false it's the scale-based prop (Marker).
    private var usesStateImages = false
    /// Marker prop: rest art slides UP `markerLift` pt on hover/select (the SVGs
    /// differ by a pure 10pt lift) and the selected art (lift + glow) crossfades
    /// in on top. The "best smooth transition" for a lift is a slide, not a fade.
    private var usesMarkerStates = false
    private var markerLift: CGFloat = 0

    init(image: NSImage?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false        // art overflows; never clip the pop
        imageView.image = image
        for iv in [imageView, hoverImageView, selectedImageView] {
            iv.imageScaling = .scaleAxesIndependently
            iv.wantsLayer = true
            addSubview(iv)
        }
        hoverImageView.alphaValue = 0       // hidden until hover
        selectedImageView.alphaValue = 0    // hidden until selected
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setImage(_ image: NSImage?) { imageView.image = image }

    /// Sticky button: crossfade between two distinct artworks on hover (Figma
    /// sticky-btn-rest / -hover). No active state, no scale-grow — just a smooth
    /// fade between the rest and hover renders.
    func setStateImages(rest: NSImage?, hover: NSImage?) {
        usesStateImages = true
        imageView.image = rest
        hoverImageView.image = hover
        hoverImageView.alphaValue = 0
    }

    /// Marker prop: rest art + the selected art (the rest art already lifted +
    /// glowing). On hover the rest art slides up `lift`pt (a slide — the SVGs
    /// differ by exactly a 10pt lift); on select the selected art crossfades in
    /// over the lifted rest (the glow).
    func setMarkerStates(rest: NSImage?, selected: NSImage?, lift: CGFloat) {
        usesMarkerStates = true
        imageView.image = rest
        selectedImageView.image = selected
        selectedImageView.alphaValue = 0
        markerLift = lift
    }

    /// Reflects whether this prop's tool (Draw) is the active mode.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if usesMarkerStates { refreshMarker() }
        else if !usesStateImages { refreshScale() }
    }

    private var markerLifted = false
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        // The hovered art is baked at the LIFTED position, so rest sits `markerLift`
        // lower; hover/selected lift it back up to the baked spot (flipped view → +y is down).
        let off: CGFloat = markerLifted ? 0 : markerLift
        imageView.frame = CGRect(x: 0, y: off, width: bounds.width, height: bounds.height)
        hoverImageView.frame = bounds
        // Selected art has the green pill baked at a fixed spot — never slide it.
        selectedImageView.frame = bounds
    }

    // MARK: Hover tracking
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; refresh() }
    override func mouseExited(with event: NSEvent)  { isHovered = false; isPressed = false; refresh() }

    /// Claim every in-bounds click so the image subview never swallows it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }
    override func mouseDown(with event: NSEvent) { isPressed = true; refresh() }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        refresh()
        if inside { onTap?() }
    }

    private func refresh() {
        if usesMarkerStates {
            refreshMarker()                                        // 3 states only: rest / hover / selected — no press scale
        } else if usesStateImages {
            crossfadeHover(isHovered)                              // rest ↔ hover artwork
            CLIPSpring.scale(self, to: isPressed ? 0.94 : 1.0, key: "xform")  // subtle press only
        } else {
            refreshScale()
        }
    }

    /// Smooth rest↔hover artwork crossfade (sticky button).
    private func crossfadeHover(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CLIPSpring.easeOutSoft
            ctx.allowsImplicitAnimation = true
            hoverImageView.animator().alphaValue = on ? 1 : 0
        }
    }

    /// Marker: slide the base art up on hover/select (the 10pt lift), and
    /// crossfade the selected art (lift + glow) in when the Draw tool is active.
    private func refreshMarker() {
        markerLifted = isHovered || isActive
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CLIPSpring.easeOutSoft
            ctx.allowsImplicitAnimation = true
            // Rest sits `markerLift` lower; hover/selected lift to the baked position.
            imageView.animator().setFrameOrigin(CGPoint(x: 0, y: markerLifted ? 0 : markerLift))
            // Selected art has the green pill baked in at a fixed spot — never slide it.
            selectedImageView.animator().setFrameOrigin(.zero)
            // Selected shows ONLY the selected art (marker + pill); hide the base.
            imageView.animator().alphaValue = isActive ? 0 : 1
            selectedImageView.animator().alphaValue = isActive ? 1 : 0
        }
    }

    /// One transform = press / active / hover composed, sprung through the
    /// unified `CLIPSpring` with a single coalescing key so re-triggers retarget
    /// instead of stacking. (Marker prop.)
    private func refreshScale() {
        let s: CGFloat = isPressed ? 0.94 : (isActive ? 1.08 : (isHovered ? 1.05 : 1.0))
        CLIPSpring.scale(self, to: s, key: "xform")
    }
}

// MARK: - StickerProp

/// The sticky-note prop: a back **paper** sheet and a front **corner-fold**
/// sheet that physically fan apart + lift on hover (Figma sticky-btn 90-557 rest
/// → 90-537 hover), plus a 30% white wash over the front sheet. Built from the
/// per-element SVGs and driven with CALayer position + transform (which animate
/// reliably, unlike NSView.frameCenterRotation). No selected state.
final class StickerProp: NSView {
    var onTap: (() -> Void)?

    // MARK: Accessibility — a custom NSView is invisible to VoiceOver unless
    // it says what it is. Exposed as a pressable button with a name (which
    // doubles as the hover tooltip).
    var accessibilityName = "" { didSet { toolTip = accessibilityName } }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityName }
    override func accessibilityPerformPress() -> Bool { onTap?(); return onTap != nil }

    private let paper    = CALayer()   // back sheet (carries the baked shadow)
    private let fold     = CALayer()   // front sheet with the folded corner
    private let foldWash  = CALayer()  // 30% white wash, masked to the fold shape

    private var isHovered = false
    private var isPressed = false

    // View is NOT flipped → CALayer geometry is y-up (origin bottom-left).
    private let paperSize = CGSize(width: 91, height: 89)
    private let foldSize   = CGSize(width: 80, height: 87)

    // Element centres (126×76 frame), Figma top-left converted to y-up (76 − y).
    // Rest = 90-557, hover = 90-537.
    private let paperCRest  = CGPoint(x: 50.19, y: 20.62)
    private let paperCHover = CGPoint(x: 48.19, y: 21.61)
    // Fold img centre (incl. the −5.88%/−9.74% inset): rest 94-696, hover 90-537.
    private let foldCRest   = CGPoint(x: 53.68, y: 22.73)   // y-up (76 − 53.27)
    private let foldCHover  = CGPoint(x: 58.45, y: 30.73)   // y-up (76 − 45.27)

    // The fold SVG is baked at the REST pose (upright), so it stays put at rest and
    // rotates to +4.72° on hover. The paper SVG is baked at the HOVER pose (−16.3°),
    // so it rotates back +5.37° CW at rest. (y-up: CW = −rad.)
    private let paperRestRot: CGFloat = -5.37 * .pi / 180
    private let foldHoverRot: CGFloat = -4.72 * .pi / 180

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true                       // clip to 126×76, like Figma
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        paper.bounds = CGRect(origin: .zero, size: paperSize)
        fold.bounds  = CGRect(origin: .zero, size: foldSize)
        for l in [paper, fold] {
            l.contentsGravity = .resize
            l.contentsScale = scale
            layer?.addSublayer(l)
        }
        foldWash.frame = CGRect(origin: .zero, size: foldSize)   // child of fold → inherits its transform
        foldWash.backgroundColor = NSColor.white.cgColor
        foldWash.contentsScale = scale
        foldWash.opacity = 0
        fold.addSublayer(foldWash)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setElements(paper p: NSImage?, fold f: NSImage?) {
        paper.contents = p
        fold.contents = f
        if let f = f {                                    // clip the wash to the fold silhouette
            let mask = CALayer()
            mask.frame = CGRect(origin: .zero, size: foldSize)
            mask.contents = f
            mask.contentsGravity = .resize
            mask.contentsScale = fold.contentsScale
            foldWash.mask = mask
        }
        needsLayout = true
    }

    func setActive(_ active: Bool) {}                     // sticky: no selected state

    private var lifted: Bool { isHovered }

    override func layout() {
        super.layout()
        apply(animated: false)
    }

    private func apply(animated: Bool) {
        let pC = lifted ? paperCHover : paperCRest
        let fC = lifted ? foldCHover  : foldCRest
        let pT = lifted ? CATransform3DIdentity
                        : CATransform3DMakeRotation(paperRestRot, 0, 0, 1)   // paper rests rotated, hover flat
        let fT = lifted ? CATransform3DMakeRotation(foldHoverRot, 0, 0, 1)   // fold rests flat, hover rotated
                        : CATransform3DIdentity

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.24)
            CATransaction.setAnimationTimingFunction(CLIPSpring.easeOutSoft)
        }
        paper.position = pC
        paper.transform = pT
        fold.position = fC
        fold.transform = fT
        foldWash.opacity = isHovered ? 0.30 : 0
        CATransaction.commit()
    }

    // MARK: hover + click
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; apply(animated: true) }
    override func mouseExited(with event: NSEvent)  { isHovered = false; isPressed = false; apply(animated: true) }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) != nil ? self : nil }
    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onTap?() }
    }
}

// MARK: - AddPillView

/// The round (62 × 62) "+" candy pill — same green/yellow skin, contains a
/// "+" icon at 70% opacity. Fires `onTap` (wired to section creation).
final class AddPillView: NSView {

    var onTap: (() -> Void)?

    // MARK: Accessibility — a custom NSView is invisible to VoiceOver unless
    // it says what it is. Exposed as a pressable button with a name (which
    // doubles as the hover tooltip).
    var accessibilityName = "" { didSet { toolTip = accessibilityName } }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityName }
    override func accessibilityPerformPress() -> Bool { onTap?(); return onTap != nil }

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
        NSColor.paletteHex(0xFFFCA9).cgColor, NSColor.paletteHex(0xFFFCA9).cgColor,
        NSColor.paletteHex(0xFFF53B).cgColor, NSColor.paletteHex(0xF8DE47).cgColor
    ]
    /// Selected skin (Figma 72:36780): #3DA726→#4CC432 gradient + 30% black overlay
    /// = #2B751B→#358923. No separate rim — uniform dark green at top.
    private static let greenSkin: [CGColor] = [
        NSColor.paletteHex(0x2B751B).cgColor, NSColor.paletteHex(0x2B751B).cgColor,
        NSColor.paletteHex(0x2B751B).cgColor, NSColor.paletteHex(0x358923).cgColor
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

        outerLayer.backgroundColor = NSColor.paletteHex(0x3DA726).cgColor
        outerLayer.masksToBounds   = false
        layer?.addSublayer(outerLayer)

        // Pale top rim only (Figma `border-t-2`), via a crisp 4-stop gradient —
        // matches the main pill. 2 pt of the 58 pt inner circle → ≈ 0.0345.
        innerLayer.colors = [
            NSColor.paletteHex(0xFFFCA9).cgColor,
            NSColor.paletteHex(0xFFFCA9).cgColor,
            NSColor.paletteHex(0xFFF53B).cgColor,
            NSColor.paletteHex(0xF8DE47).cgColor
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

    /// Human name for an icon asset (VoiceOver label + tooltip).
    static func displayName(for iconName: String) -> String {
        switch iconName {
        case "tool_select":  return "Select"
        case "tool_hand":    return "Hand"
        case "tool_text":    return "Text"
        case "tool_connect": return "Connect"
        case "Download":     return "Download"
        case "Color":        return "Color"
        case "Eject":        return "Eject"
        default:             return iconName.replacingOccurrences(of: "tool_", with: "").capitalized
        }
    }

    var onTap: (() -> Void)?

    // MARK: Accessibility — a custom NSView is invisible to VoiceOver unless
    // it says what it is. Exposed as a pressable button with a name (which
    // doubles as the hover tooltip).
    var accessibilityName = "" { didSet { toolTip = accessibilityName } }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityName }
    override func accessibilityPerformPress() -> Bool { onTap?(); return onTap != nil }

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
    /// Rest (outlined black template) ↔ selected (solid brand-yellow) artwork —
    /// swapped on selection so the SHAPE changes, not just the tint (Figma states).
    private lazy var restImage: NSImage?   = Self.loadIcon(iconName)
    // Active art loads as a TEMPLATE too and is tinted brand-yellow — the solid
    // `_active` SVGs make a filled yellow shape, and NSImage's SVG colour
    // rendering is unreliable, so tinting a template is the robust path.
    private lazy var activeImage: NSImage? = Self.loadIcon(iconName + "_active")

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

        // Icon: outlined black template at rest; swaps to the solid brand-yellow
        // `_active` art when selected (see setActive).
        iconView.image            = restImage
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
        refreshIconState()
        refreshBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if isPressed { isPressed = false; CLIPSpring.scale(self, to: 1.0, key: "press") }
        refreshIconState()
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
        // Swap the SHAPE (outlined → solid). The active art carries its own
        // #FEF33C; the rest art is a black template. Fall back to a yellow tint
        // if a tool has no `_active` asset yet.
        iconView.image = (active ? activeImage : restImage) ?? restImage
        iconView.contentTintColor = active ? NSColor.paletteHex(0xFEF33C) : .black
        refreshIconState()
        refreshBackground(animated: animated)
    }

    // MARK: - Background circle (selected beats hover beats hidden)

    private func refreshBackground(animated: Bool = true) {
        let opacity: CGFloat
        if isActive {
            bgLayer.backgroundColor = NSColor.paletteHex(0x3DA726).cgColor
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

    /// Icon-level state effects (Figma 89-576 rest / 89-578 hover / 89-581
    /// selected) — applied to the ICON, not the hover circle:
    ///   • rest      → dimmed to the per-tool rest opacity, no shadow
    ///   • hover     → full opacity + soft dark drop shadow (the icon lifts)
    ///   • selected  → full opacity + white glow (white@70%, blur ~10pt)
    private func refreshIconState() {
        iconView.wantsLayer = true
        guard let l = iconView.layer else { return }
        l.masksToBounds = false
        if isActive {
            iconView.alphaValue = 1.0
            l.shadowColor = NSColor.white.cgColor
            l.shadowOffset = .zero
            l.shadowRadius = 3          // softer, tighter glow (was 5 / 0.7)
            l.shadowOpacity = 0.4
        } else if isHovered {
            iconView.alphaValue = 1.0
            l.shadowColor = NSColor.black.cgColor
            l.shadowOffset = CGSize(width: 0, height: -2)   // project DOWN (icon layer is y-up)
            l.shadowRadius = 2
            l.shadowOpacity = 0.35
        } else {
            iconView.alphaValue = iconRestOpacity
            l.shadowOpacity = 0
        }
    }

    // MARK: - Icon mapping

    /// Returns a 24 × 24 template image for a tool mode.
    /// Uses SF Symbols where possible; falls back to a constructed path image.
    /// Loads a 24×24 template icon (`tool_*.svg`) from the bundle.
    static func loadIcon(_ name: String, template: Bool = true) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        // Rest icons are black templates (tinted); the selected (`_active`) icons
        // carry their own brand-yellow colour, so they load non-template.
        img.isTemplate = template
        img.size = NSSize(width: 24, height: 24)
        return img
    }

}
