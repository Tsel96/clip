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

    // MARK: Geometry
    private let discR: CGFloat = 68
    private let petalD: CGFloat = 36         // ALL circles share this diameter (core + petals)
    private let pad: CGFloat = 36            // room for the glow + drop shadow (must not clip)
    private var discCenter: CGPoint = .zero
    private var innerR: CGFloat = 0
    private var outerR: CGFloat = 0

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

    init() {
        // Disc only — the control bar is the candy folder toolbar this blooms ABOVE.
        let viewSide = discR * 2 + pad * 2
        super.init(frame: CGRect(x: 0, y: 0, width: viewSide, height: viewSide))
        wantsLayer = true
        layerUsesCoreImageFilters = true
        discCenter = CGPoint(x: viewSide / 2, y: viewSide / 2)
        // Geometric-nesting ring radii (BlossomColorPicker layout.ts).
        let radii = Self.layerRadii(counts: [innerColors.count, outerColors.count],
                                    coreSize: petalD, petalSize: petalD)
        innerR = radii[0]; outerR = radii[1]
        buildHaloDisc()
        buildPetals()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout math (port of BlossomColorPicker calculateLayerRadii)

    private static func layerRadii(counts: [Int], coreSize: CGFloat, petalSize: CGFloat) -> [CGFloat] {
        var radii: [CGFloat] = []
        let W = petalSize, Rc = coreSize / 2, Rp = petalSize / 2
        for i in 0..<counts.count {
            let N = CGFloat(counts[i])
            let overlap: CGFloat = counts[i] <= 8 ? 0.45 : counts[i] <= 12 ? 0.5 : 0.55
            let lateral = (N * W * overlap) / (2 * .pi)
            var r: CGFloat
            if i == 0 {
                let coreOverlap = counts[i] <= 5 ? W * 0.35 : W * 0.25
                r = max(Rc + Rp - coreOverlap, lateral)
            } else {
                let prevR = radii[i - 1], prevN = CGFloat(counts[i - 1])
                let sparsity = (prevN * W) / (2 * .pi * prevR)
                let step: CGFloat = sparsity < 0.85 ? W * 0.15 : sparsity > 1.1 ? W * 0.45 : W * 0.35
                r = max(prevR + step, lateral)
                r = max(r, prevR + W * 0.1)
            }
            radii.append(r)
        }
        return radii
    }

    // MARK: Build — halo + disc

    private var conicColors: [CGColor] { (outerColors + [outerColors[0]]).map { $0.cgColor } }

    private func buildHaloDisc() {
        let d = discR * 2
        let discRect = CGRect(x: discCenter.x - discR, y: discCenter.y - discR, width: d, height: d)

        // Soft outer glow — a lightly-blurred conic spilling just past the rim.
        let bloom = CAGradientLayer()
        bloom.type = .conic
        bloom.frame = discRect.insetBy(dx: -9, dy: -9)
        bloom.cornerRadius = bloom.frame.width / 2
        bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
        bloom.endPoint = CGPoint(x: 0.5, y: 0)
        bloom.colors = conicColors
        bloom.opacity = 0.72
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(9, forKey: "inputRadius"); bloom.filters = [blur]
        }
        layer?.addSublayer(bloom)

        // Crisp spectrum rim: a conic disc just larger than the dark disc.
        let rim = CAGradientLayer()
        rim.type = .conic
        rim.frame = discRect.insetBy(dx: -2.5, dy: -2.5)
        rim.cornerRadius = rim.frame.width / 2
        rim.startPoint = CGPoint(x: 0.5, y: 0.5)
        rim.endPoint = CGPoint(x: 0.5, y: 0)
        rim.colors = conicColors
        layer?.addSublayer(rim)

        let disc = CALayer()
        disc.frame = discRect
        disc.cornerRadius = discR
        disc.backgroundColor = discColor.cgColor
        disc.shadowColor = NSColor.black.cgColor
        disc.shadowOpacity = 0.34; disc.shadowRadius = 22   // soft float, fits in `pad`
        disc.shadowOffset = CGSize(width: 0, height: -8)
        layer?.addSublayer(disc)
    }

    // MARK: Build — flower

    private func buildPetals() {
        let r = petalD / 2
        // Outer ring (12), valley-rotated 30° — drawn lowest.
        for (i, c) in outerColors.enumerated() {
            let deg = 30 + CGFloat(i) / CGFloat(outerColors.count) * 360
            addPetal(color: c, center: ringPoint(outerR, deg: deg), r: r, isCore: false, baseZ: zFor(deg, layer: 0))
        }
        // Inner ring (6) — above the outer ring.
        for (i, c) in innerColors.enumerated() {
            let deg = CGFloat(i) / CGFloat(innerColors.count) * 360
            addPetal(color: c, center: ringPoint(innerR, deg: deg), r: r, isCore: false, baseZ: zFor(deg, layer: 1))
        }
        // White core — on top.
        addPetal(color: .white, center: discCenter, r: r, isCore: true, baseZ: 2000)
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
        p.zPosition = baseZ
        // No stroke/shadow — overlap + the dark disc behind give the separation,
        // and a per-petal shadow read as an ugly outline on the hovered (scaled) one.
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
        if idx != hovered {
            hovered = idx
            CLIPHaptics.snap()
            (idx != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
            for (i, petal) in petals.enumerated() {
                let s: CGFloat = i == idx ? (petal.isCore ? 1.85 : 1.4) : 1.0
                petal.layer.zPosition = petal.baseZ + (i == idx ? 100000 : 0)
                scale(petal.layer, s, center: petal.center)
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        NSCursor.arrow.set()
        for petal in petals { scale(petal.layer, 1.0, center: petal.center) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let idx = nearestPetal(to: p) { pick(petals[idx].color) }
    }

    private func pick(_ color: NSColor) {
        CLIPHaptics.levelChange()
        onPick(color)
        dismiss()
    }

    private func nearestPetal(to p: CGPoint) -> Int? {
        // Topmost (highest z) circle containing the point.
        var best: Int? = nil; var bestZ: CGFloat = -1
        for (i, petal) in petals.enumerated() {
            if hypot(p.x - petal.center.x, p.y - petal.center.y) <= petal.r, petal.baseZ >= bestZ {
                best = i; bestZ = petal.baseZ
            }
        }
        return best
    }

    private func scale(_ layer: CAShapeLayer, _ s: CGFloat, center pivot: CGPoint) {
        let to = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0),
                                CATransform3DMakeScale(s, s, 1)),
            CATransform3DMakeTranslation(pivot.x, pivot.y, 0))
        let a = CASpringAnimation(keyPath: "transform")
        a.fromValue = layer.presentation()?.transform ?? layer.transform
        a.toValue = to
        a.stiffness = CLIPSpring.Preset.control.stiffness
        a.damping = CLIPSpring.Preset.control.caDamping
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
