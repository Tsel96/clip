import AppKit

private func hex(_ v: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

// MARK: - Native radial color picker (Spatial's flower wheel, 1:1)

/// Spatial's color selector: a dark disc carrying a tightly-packed "flower" of
/// equal-sized colour circles (white core + 6 pastel inner ring + 12 vibrant
/// outer ring), wrapped in a crisp rainbow rim + soft glow, with a dark
/// `#1D2023` control bar below (save / eyedropper / eject).
///
/// Flower geometry follows the BlossomColorPicker "geometric nesting" algorithm
/// (equal circles, valley-staggered rings, aggressive overlap) so the petals
/// pack densely like Spatial's — not the sparse, uneven ring of the first pass.
final class RadialColorPicker: NSView {

    var onPick: (NSColor) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    /// Live preview as the cursor sweeps the petals: the hovered colour (or `nil`
    /// when over no petal / on exit). Drives the folder's live recolour.
    var onHoverPreview: (NSColor?) -> Void = { _ in }

    // MARK: Geometry — Spatial proportions
    /// Spatial's flower leaves the blossom ~0.78× of the disc, so a dark margin
    /// rings it before the OFFSET rainbow rim; the white core is a touch larger
    /// than the leaves and the rings are spread enough that the vibrant outer
    /// ring is never buried under the pale inner ring.
    private let discR: CGFloat = 72
    private let petalR: CGFloat = 15         // inner + outer leaf radius
    private let coreR: CGFloat = 19          // white centre, slightly larger
    private let pad: CGFloat = 36            // room for the glow + drop shadow (must not clip)
    private var discCenter: CGPoint = .zero
    private let innerR: CGFloat = 23
    private let outerR: CGFloat = 42         // outer leaf edge ≈ 57 → ~15pt dark margin to the rim

    // MARK: Hover falloff (Spatial: "each leaf interacts with nearby leaves")
    /// Peak scale boost for the hovered circle, the core's extra pop, and the
    /// Gaussian falloff width (pt) over which neighbours react.
    private let hoverBoost: CGFloat = 0.30
    private let hoverCoreBoost: CGFloat = 0.36
    private let hoverSigma: CGFloat = 19

    // MARK: Palette (BlossomColorPicker)
    /// Inner ring — 6 pastels, clockwise from top.
    private let innerColors: [NSColor] = [
        hex(0xFDF1B6), hex(0xFCE0CA), hex(0xF8C8D4), hex(0xDEC2E9), hex(0xC6DEF5), hex(0xD2ECD0),
    ]
    /// Outer ring — 12 vibrants, clockwise.
    private let outerColors: [NSColor] = [
        hex(0xFCD752), hex(0xFDBA50), hex(0xFA9C4D), hex(0xF6774F), hex(0xF15656), hex(0xE756A6),
        hex(0xB261CC), hex(0x8966DF), hex(0x6586E5), hex(0x69B5E2), hex(0x77C9A2), hex(0xA4D483),
    ]
    private let discColor = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.063, alpha: 1)  // #0E0E10

    private struct Petal { let layer: CAShapeLayer; let color: NSColor; let center: CGPoint; let r: CGFloat; let isCore: Bool; let baseZ: CGFloat }
    private var petals: [Petal] = []
    private var hovered: Int? = nil
    private var tracking: NSTrackingArea?
    private var outsideMonitor: Any?
    /// Crisp outline traced around the hovered petal (above everything).
    private let hoverRing = CAShapeLayer()
    /// Once a colour is picked, stop reverting the live preview on the way out.
    private var picked = false
    /// Current scale of each petal, so a leaf can pop up INSTANTLY when hovered
    /// but ease back SMOOTHLY once the cursor moves off it.
    private var petalScale: [CGFloat] = []

    init() {
        // Disc only — the control bar is the candy folder toolbar this blooms ABOVE.
        let viewSide = discR * 2 + pad * 2
        super.init(frame: CGRect(x: 0, y: 0, width: viewSide, height: viewSide))
        wantsLayer = true
        layerUsesCoreImageFilters = true
        discCenter = CGPoint(x: viewSide / 2, y: viewSide / 2)
        buildHaloDisc()
        buildPetals()
        buildHoverRing()
        petalScale = Array(repeating: 1, count: petals.count)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A single reusable ring layer, drawn above every petal, that traces the
    /// hovered circle. Hidden until a petal is hovered.
    private func buildHoverRing() {
        hoverRing.fillColor = nil
        hoverRing.lineWidth = 2.5
        hoverRing.strokeColor = NSColor.white.cgColor
        hoverRing.zPosition = 2_000_000          // above the lifted petal (baseZ + 100000)
        hoverRing.opacity = 0
        hoverRing.shadowColor = NSColor.black.cgColor
        hoverRing.shadowOpacity = 0.45           // keyline so the ring reads on light petals too
        hoverRing.shadowRadius = 1.5
        hoverRing.shadowOffset = .zero
        layer?.addSublayer(hoverRing)
    }

    /// Trace an always-white ring around the (scaled) hovered petal that GLIDES
    /// between petals with a spring (Spatial's smooth selection ring), fading in
    /// on first hover and out when over no petal.
    private func updateHoverRing(for idx: Int?, animated: Bool) {
        guard let idx else {
            // Release: ease the ring out smoothly.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = hoverRing.presentation()?.opacity ?? hoverRing.opacity
            fade.toValue = 0
            fade.duration = 0.18
            hoverRing.opacity = 0
            hoverRing.add(fade, forKey: "ringFade")
            return
        }
        let petal = petals[idx]
        let scaled = petal.r * (1 + (petal.isCore ? hoverCoreBoost : hoverBoost)) + 1.5
        let rect = CGRect(x: petal.center.x - scaled, y: petal.center.y - scaled,
                          width: scaled * 2, height: scaled * 2)
        let newPath = CGPath(ellipseIn: rect, transform: nil)
        if animated {
            let a = CASpringAnimation(keyPath: "path")
            a.fromValue = hoverRing.presentation()?.path ?? hoverRing.path
            a.toValue = newPath
            a.stiffness = CLIPSpring.Preset.control.stiffness
            a.damping = CLIPSpring.Preset.control.caDamping
            a.duration = a.settlingDuration
            hoverRing.path = newPath
            hoverRing.add(a, forKey: "ringPath")
        } else {
            // Instant snap to the hovered leaf — hover feedback is immediate.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            hoverRing.removeAnimation(forKey: "ringPath")
            hoverRing.path = newPath
            CATransaction.commit()
        }
        hoverRing.opacity = 1
    }

    // MARK: Build — halo + disc

    private var conicColors: [CGColor] { (outerColors + [outerColors[0]]).map { $0.cgColor } }

    private func buildHaloDisc() {
        let d = discR * 2
        let discRect = CGRect(x: discCenter.x - discR, y: discCenter.y - discR, width: d, height: d)

        // 1. Soft coloured outer glow — a blurred conic spilling past the rim.
        let glow = CAGradientLayer()
        glow.type = .conic
        glow.frame = discRect.insetBy(dx: -12, dy: -12)
        glow.cornerRadius = glow.frame.width / 2
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 0.5, y: 0)
        glow.colors = conicColors
        glow.opacity = 0.85
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(11, forKey: "inputRadius"); glow.filters = [blur]
        }
        layer?.addSublayer(glow)

        // 2. Dark disc backdrop, floating with a soft shadow.
        let disc = CALayer()
        disc.frame = discRect
        disc.cornerRadius = discR
        disc.backgroundColor = discColor.cgColor
        disc.shadowColor = NSColor.black.cgColor
        disc.shadowOpacity = 0.34; disc.shadowRadius = 22   // soft float, fits in `pad`
        disc.shadowOffset = CGSize(width: 0, height: -8)
        layer?.addSublayer(disc)

        // 3. CRISP bright rainbow rim — a conic gradient masked to a thin stroked
        //    circle right at the disc edge, OFFSET from the blossom by the dark
        //    margin (Spatial's glowing ring). A full conic disc would be hidden by
        //    the dark disc; the ring mask reveals only the 4pt edge band.
        let rimWidth: CGFloat = 2.5
        let rim = CAGradientLayer()
        rim.type = .conic
        rim.frame = discRect
        rim.cornerRadius = discR
        rim.startPoint = CGPoint(x: 0.5, y: 0.5)
        rim.endPoint = CGPoint(x: 0.5, y: 0)
        rim.colors = conicColors
        let rimMask = CAShapeLayer()
        rimMask.frame = rim.bounds
        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.black.cgColor
        rimMask.lineWidth = rimWidth
        rimMask.path = CGPath(ellipseIn: CGRect(x: rimWidth / 2, y: rimWidth / 2,
                                                width: d - rimWidth, height: d - rimWidth), transform: nil)
        rim.mask = rimMask
        layer?.addSublayer(rim)

        // 4. Black ring just OUTSIDE the gradient (offset), defining the bright rim
        //    against the soft glow — Spatial's dark keyline around the spectrum.
        let blackRing = CAShapeLayer()
        blackRing.fillColor = nil
        blackRing.strokeColor = NSColor.black.cgColor
        blackRing.lineWidth = 2
        let br = discR + 1
        blackRing.path = CGPath(ellipseIn: CGRect(x: discCenter.x - br, y: discCenter.y - br,
                                                  width: br * 2, height: br * 2), transform: nil)
        layer?.addSublayer(blackRing)
    }

    // MARK: Build — flower

    private func buildPetals() {
        // Outer ring (12), valley-rotated 30° — drawn lowest.
        for (i, c) in outerColors.enumerated() {
            let deg = 30 + CGFloat(i) / CGFloat(outerColors.count) * 360
            addPetal(color: c, center: ringPoint(outerR, deg: deg), r: petalR, isCore: false, baseZ: zFor(deg, layer: 0))
        }
        // Inner ring (6) — above the outer ring.
        for (i, c) in innerColors.enumerated() {
            let deg = CGFloat(i) / CGFloat(innerColors.count) * 360
            addPetal(color: c, center: ringPoint(innerR, deg: deg), r: petalR, isCore: false, baseZ: zFor(deg, layer: 1))
        }
        // White core — on top, larger than the leaves.
        addPetal(color: .white, center: discCenter, r: coreR, isCore: true, baseZ: 2000)
    }

    /// Point on a ring at `deg` clockwise from the top (view coords, y-up).
    private func ringPoint(_ r: CGFloat, deg: CGFloat) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: discCenter.x + sin(a) * r, y: discCenter.y + cos(a) * r)
    }

    /// Bottom-of-flower petals sit on top (natural bloom); each layer is a band.
    private func zFor(_ deg: CGFloat, layer: CGFloat) -> CGFloat {
        layer * 1000 + (1 - cos(deg * .pi / 180)) * 50
    }

    private func addPetal(color: NSColor, center: CGPoint, r: CGFloat, isCore: Bool, baseZ: CGFloat) {
        let p = CAShapeLayer()
        p.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2), transform: nil)
        p.fillColor = color.cgColor
        // Spatial: each leaf has a faint outline + a small drop shadow, so the
        // circles read as distinct glossy chips stacked over one another.
        p.strokeColor = NSColor.white.withAlphaComponent(0.15).cgColor   // very subtle at rest; the hovered leaf gets the bright ring
        p.lineWidth = 1
        p.shadowColor = NSColor.black.cgColor
        p.shadowOpacity = 0.30
        p.shadowRadius = 2.5
        p.shadowOffset = CGSize(width: 0, height: -1.5)   // downward (picker view is y-up)
        // Explicit shadowPath so CoreAnimation doesn't re-derive each leaf's shadow
        // from its contents EVERY frame while scaling — that was the low-FPS cause.
        p.shadowPath = p.path
        p.zPosition = baseZ
        layer?.addSublayer(p)
        petals.append(Petal(layer: p, color: color, center: center, r: r, isCore: isCore, baseZ: baseZ))
    }

    // MARK: Hover + pick

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self)
        addTrackingArea(t); tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = nearestPetal(to: p)
        guard idx != hovered else { return }
        hovered = idx
        if idx != nil { CLIPHaptics.snap() }
        // (no cursor change on hover — keep the default arrow)
        applyHoverScales(hovered: idx)                    // grow instant, shrink smooth
        updateHoverRing(for: idx, animated: false)
        if !picked { onHoverPreview(idx.map { petals[$0].color }) }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        applyHoverScales(hovered: nil)                    // all ease back smoothly
        updateHoverRing(for: nil, animated: true)
        if !picked { onHoverPreview(nil) }
    }

    /// Spatial's flower hover: the hovered circle scales most and every other
    /// circle scales by a smooth Gaussian falloff of its distance to it, so the
    /// neighbours swell a little and the picker breathes as one — all on the
    /// snappy control spring.
    private func applyHoverScales(hovered idx: Int?) {
        let hc = idx.map { petals[$0].center }
        for (i, petal) in petals.enumerated() {
            let target: CGFloat
            if let idx, let hc {
                let d = hypot(petal.center.x - hc.x, petal.center.y - hc.y)
                let g = exp(-0.5 * (d / hoverSigma) * (d / hoverSigma))   // 1 at hovered → 0 far
                let boost = (i == idx && petal.isCore) ? hoverCoreBoost : hoverBoost
                target = 1 + boost * g
            } else {
                target = 1
            }
            // Only the hovered leaf jumps to the front; neighbours keep resting z.
            petal.layer.zPosition = petal.baseZ + (i == idx ? 100_000 : 0)
            guard abs(target - petalScale[i]) > 0.001 else { continue }
            let growing = target > petalScale[i]
            petalScale[i] = target
            // Spatial: pop up INSTANTLY when hovered, ease back SMOOTHLY when the
            // cursor moves off — so animate only when a leaf is shrinking.
            scale(petal.layer, target, center: petal.center, animated: !growing)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let idx = nearestPetal(to: p) { pick(petals[idx].color) }
    }

    private func pick(_ color: NSColor) {
        picked = true                 // freeze the preview; the commit stands
        CLIPHaptics.levelChange()
        onPick(color)
        dismiss()
    }

    private func nearestPetal(to p: CGPoint) -> Int? {
        // The circle whose CENTRE is nearest the cursor (within a small reach).
        // Picking by nearest centre — not "topmost circle containing the point" —
        // means small moves don't flip between overlapping leaves, so the hover is
        // stable and predictable (you always target the closest colour).
        var best: Int? = nil; var bestD = CGFloat.greatestFiniteMagnitude
        for (i, petal) in petals.enumerated() {
            let d = hypot(p.x - petal.center.x, p.y - petal.center.y)
            if d <= petal.r + 7, d < bestD { bestD = d; best = i }
        }
        return best
    }

    /// Spatial's leaves snap up INSTANTLY on hover and ease back SMOOTHLY on
    /// release — so `animated` is false while hovering (incl. moving between
    /// leaves) and true only on exit.
    private func scale(_ layer: CAShapeLayer, _ s: CGFloat, center pivot: CGPoint, animated: Bool) {
        let to = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0),
                                CATransform3DMakeScale(s, s, 1)),
            CATransform3DMakeTranslation(pivot.x, pivot.y, 0))
        if !animated {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "hoverScale")
            layer.transform = to
            CATransaction.commit()
            return
        }
        // Clearly-visible smooth return (slight overshoot) — the "scale back".
        let preset = CLIPSpring.Preset(response: 0.40, damping: 0.72)
        let a = CASpringAnimation(keyPath: "transform")
        a.fromValue = layer.presentation()?.transform ?? layer.transform
        a.toValue = to
        a.stiffness = preset.stiffness
        a.damping = preset.caDamping
        a.initialVelocity = 0
        if #available(macOS 14.0, *) { a.allowsOverdamping = true }
        a.duration = a.settlingDuration
        layer.transform = to
        layer.add(a, forKey: "hoverScale")
    }

    // MARK: Present / dismiss

    /// Present with the disc centre at `point`. Springs OUT of the bottom (the
    /// Color button) — scale 0.5→1 anchored at bottom-centre + a 12pt rise + a
    /// pop — matching the toolbar link-input panel's transition.
    func present(in host: NSView, at point: CGPoint) {
        frame = CGRect(x: point.x - discCenter.x, y: point.y - discCenter.y,
                       width: bounds.width, height: bounds.height)
        host.addSubview(self)
        let popper = CLIPSpring.Preset(response: 0.34, damping: 0.66)
        if let layer = layer {
            // Bloom from the disc centre (Spatial spreads its leaves out of the
            // centre) — scale 0.4 → 1 anchored at centre.
            let pivot = discCenter
            var small = CATransform3DConcat(CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0),
                                            CATransform3DMakeScale(0.4, 0.4, 1))
            small = CATransform3DConcat(small, CATransform3DMakeTranslation(pivot.x, pivot.y, 0))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.transform = small; layer.opacity = 0
            CATransaction.commit()
            let a = CASpringAnimation(keyPath: "transform")
            a.fromValue = small; a.toValue = CATransform3DIdentity
            a.stiffness = popper.stiffness
            a.damping = popper.caDamping
            a.duration = a.settlingDuration
            layer.transform = CATransform3DIdentity
            layer.add(a, forKey: "bloom")
        }
        CLIPSpring.run(duration: 0.16) { [weak self] in self?.layer?.opacity = 1 }
        window?.makeFirstResponder(self)

        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self else { return e }
            let p = self.convert(e.locationInWindow, from: nil)
            if !self.bounds.contains(p) { self.dismiss() }
            return e
        }
    }

    func dismiss() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        CLIPSpring.run(duration: 0.16, _: { [weak self] in self?.layer?.opacity = 0 }) { [weak self] in
            self?.removeFromSuperview()
        }
        onDismiss()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss() } else { super.keyDown(with: event) }
    }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Section-color mapping

    static func nearestSectionColor(to color: NSColor) -> SectionColor {
        let target = color.usingColorSpace(.sRGB) ?? color
        func dist(_ s: SectionColor) -> CGFloat {
            let c = NSColor(s.swiftUIColor).usingColorSpace(.sRGB) ?? .gray
            return pow(c.redComponent - target.redComponent, 2)
                 + pow(c.greenComponent - target.greenComponent, 2)
                 + pow(c.blueComponent - target.blueComponent, 2)
        }
        return SectionColor.allCases.min { dist($0) < dist($1) } ?? .slate
    }
}
