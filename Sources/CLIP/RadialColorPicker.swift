import AppKit

private func hex(_ v: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

// MARK: - Native radial color picker (Spatial's flower color wheel, 1:1)

/// A pixel-faithful copy of Spatial's color selector: a dark disc carrying a
/// "flower" of colour circles (white centre + a 6-petal pastel inner ring + a
/// 12-petal vibrant outer ring), wrapped in a soft rainbow bloom, with a dark
/// `#1D2023` control bar below holding three icons (save / eyedropper / eject).
/// Colours + geometry were sampled directly from `/Applications/Spatial.app`.
/// Hovering a petal scales it (the white centre blooms big); clicking picks.
/// Pure CALayer + AppKit — no SwiftUI.
final class RadialColorPicker: NSView {

    var onPick: (NSColor) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    // MARK: Geometry (points; sampled from Spatial's resting flower)
    private let discR: CGFloat = 68          // disc radius
    private let whiteR: CGFloat = 15         // centre white circle radius
    private let innerRingR: CGFloat = 29     // inner (pastel) ring centre radius
    private let innerPetalR: CGFloat = 14
    private let outerRingR: CGFloat = 50     // outer (vibrant) ring centre radius
    private let outerPetalR: CGFloat = 12
    private let pad: CGFloat = 18            // halo bloom room
    private let gap: CGFloat = 12            // disc → bar gap
    private let barH: CGFloat = 50
    private let barW: CGFloat = 170

    private var discCenter: CGPoint = .zero

    // MARK: Palette (exact sRGB hexes sampled from Spatial)
    /// Inner ring, clockwise from top: neutral, yellow, green, blue, lavender, pink.
    private let innerColors: [NSColor] = [
        hex(0xDEDFE0), hex(0xFBF9EB), hex(0xE9F9EB), hex(0xE6F5F9), hex(0xEDECFB), hex(0xFBECF4),
    ]
    /// Outer ring, clockwise from top: black, orange, gold, lime, green, teal,
    /// cyan, blue, indigo, magenta, pink, red.
    private let outerColors: [NSColor] = [
        hex(0x2A2A2E), hex(0xFF9770), hex(0xFFC64E), hex(0xBFE84E), hex(0x35EE75), hex(0x00F0C9),
        hex(0x29D1E7), hex(0x60A7FE), hex(0x9A7EFD), hex(0xE86EEA), hex(0xFF6DB7), hex(0xFF7382),
    ]
    private let discColor = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.063, alpha: 1)  // #0E0E10
    private let barColor  = NSColor(srgbRed: 0.114, green: 0.125, blue: 0.137, alpha: 1)  // #1D2023
    private let iconColor = NSColor(srgbRed: 0.62, green: 0.63, blue: 0.64, alpha: 1)

    private struct Petal { let layer: CAShapeLayer; let color: NSColor; let center: CGPoint; let r: CGFloat; let isCenter: Bool; let baseZ: CGFloat }
    private var petals: [Petal] = []
    private var hovered: Int? = nil
    private var tracking: NSTrackingArea?
    private var outsideMonitor: Any?
    private var iconRects: [CGRect] = []     // [save, sampler, eject] in view coords

    init() {
        let viewW = barW + pad * 2
        let viewH = pad + discR * 2 + gap + barH + pad
        super.init(frame: CGRect(x: 0, y: 0, width: viewW, height: viewH))
        wantsLayer = true
        layerUsesCoreImageFilters = true
        // disc centre (view coords are y-up): bar sits at the bottom, disc above.
        discCenter = CGPoint(x: viewW / 2, y: pad + barH + gap + discR)
        buildHaloDisc()
        buildPetals()
        buildBar()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Build — halo + disc

    /// 12 vibrant hues as a closed conic ramp (matches the outer-petal order so
    /// the rim spectrum lines up with the petals beneath it).
    private var conicColors: [CGColor] {
        let ring = Array(outerColors[1...]) + [outerColors[1]]   // skip black, close loop
        return ring.map { $0.cgColor }
    }

    private func buildHaloDisc() {
        let d = discR * 2
        let discRect = CGRect(x: discCenter.x - discR, y: discCenter.y - discR, width: d, height: d)

        // Soft multicolour bloom behind the disc (blurred conic spilling past the rim).
        let bloom = CAGradientLayer()
        bloom.type = .conic
        bloom.frame = discRect.insetBy(dx: -13, dy: -13)
        bloom.cornerRadius = bloom.frame.width / 2
        bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
        bloom.endPoint = CGPoint(x: 0.5, y: 0)
        bloom.colors = conicColors
        bloom.opacity = 0.9
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(11, forKey: "inputRadius")
            bloom.filters = [blur]
        }
        layer?.addSublayer(bloom)

        // Crisp spectrum rim: a conic disc just larger than the dark disc; the
        // dark disc on top leaves a thin bright spectrum ring.
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
        disc.shadowOpacity = 0.28
        disc.shadowRadius = 14
        disc.shadowOffset = CGSize(width: 0, height: -6)
        layer?.addSublayer(disc)
    }

    // MARK: Build — flower petals

    private func buildPetals() {
        // White centre.
        addPetal(color: .white, center: discCenter, r: whiteR, isCenter: true, z: 6)
        // Outer vibrant ring (12) — drawn first / lowest.
        for i in 0..<outerColors.count {
            let c = ringPoint(outerRingR, deg: CGFloat(i) / 12 * 360)
            addPetal(color: outerColors[i], center: c, r: outerPetalR, isCenter: false, z: 2)
        }
        // Inner pastel ring (6) — above the outer ring.
        for i in 0..<innerColors.count {
            let c = ringPoint(innerRingR, deg: CGFloat(i) / 6 * 360)
            addPetal(color: innerColors[i], center: c, r: innerPetalR, isCenter: false, z: 4)
        }
    }

    /// A point on a ring at `deg` clockwise from the top (view coords, y-up).
    private func ringPoint(_ r: CGFloat, deg: CGFloat) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: discCenter.x + sin(a) * r, y: discCenter.y + cos(a) * r)
    }

    private func addPetal(color: NSColor, center: CGPoint, r: CGFloat, isCenter: Bool, z: CGFloat) {
        let p = CAShapeLayer()
        p.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2), transform: nil)
        p.fillColor = color.cgColor
        p.zPosition = z
        if isCenter {
            p.shadowColor = NSColor.black.cgColor
            p.shadowOpacity = 0.22; p.shadowRadius = 4
        }
        layer?.addSublayer(p)
        petals.append(Petal(layer: p, color: color, center: center, r: r, isCenter: isCenter, baseZ: z))
    }

    // MARK: Build — control bar

    private func buildBar() {
        let barRect = CGRect(x: (bounds.width - barW) / 2, y: pad, width: barW, height: barH)
        let bar = CALayer()
        bar.frame = barRect
        bar.cornerRadius = barH / 2
        bar.cornerCurve = .continuous
        bar.backgroundColor = barColor.cgColor
        bar.shadowColor = NSColor.black.cgColor
        bar.shadowOpacity = 0.30
        bar.shadowRadius = 12
        bar.shadowOffset = CGSize(width: 0, height: -4)
        layer?.addSublayer(bar)

        let names = ["arrow.down.to.line", "drop", "eject"]
        let fracs: [CGFloat] = [0.2, 0.5, 0.8]
        iconRects = []
        for (name, f) in zip(names, fracs) {
            let cx = barRect.minX + barW * f
            let cy = barRect.midY
            let box = CGRect(x: cx - 16, y: cy - 16, width: 32, height: 32)
            iconRects.append(box)
            let icon = CALayer()
            icon.frame = box
            icon.contentsGravity = .resizeAspect
            icon.contents = Self.symbol(name, size: 19, color: iconColor)
            layer?.addSublayer(icon)
        }
    }

    /// A template SF Symbol rendered into a tinted CGImage for a CALayer.
    private static func symbol(_ name: String, size: CGFloat, color: NSColor) -> CGImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        let img = NSImage(size: base.size)
        img.lockFocus()
        color.set()
        let r = NSRect(origin: .zero, size: base.size)
        base.draw(in: r)
        r.fill(using: .sourceAtop)
        img.unlockFocus()
        var rect = r
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
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
                let s: CGFloat = i == idx ? (petal.isCenter ? 1.9 : 1.42) : 1.0
                petal.layer.zPosition = petal.baseZ + (i == idx ? 40 : 0)
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
        // Control-bar icons first.
        for (i, r) in iconRects.enumerated() where r.contains(p) { barAction(i); return }
        // Petals.
        if let idx = nearestPetal(to: p) { pick(petals[idx].color); return }
        // Empty space inside the view → ignore (outside is handled by the monitor).
    }

    private func barAction(_ i: Int) {
        switch i {
        case 1:  // eyedropper / sampler
            NSColorSampler().show { [weak self] c in if let c { self?.pick(c) } else { self?.dismiss() } }
        default: // save (0) and eject/clear (2) just close for now
            dismiss()
        }
    }

    private func pick(_ color: NSColor) {
        CLIPHaptics.levelChange()
        onPick(color)
        dismiss()
    }

    private func nearestPetal(to p: CGPoint) -> Int? {
        // Topmost (highest z) petal whose circle contains the point.
        var best: Int? = nil; var bestZ: CGFloat = -1
        for (i, petal) in petals.enumerated() {
            if hypot(p.x - petal.center.x, p.y - petal.center.y) <= petal.r,
               petal.baseZ >= bestZ { best = i; bestZ = petal.baseZ }
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

    /// Present so the disc centre sits at `point` (host coords), blooming up.
    func present(in host: NSView, at point: CGPoint) {
        frame = CGRect(x: point.x - discCenter.x, y: point.y - discCenter.y,
                       width: bounds.width, height: bounds.height)
        host.addSubview(self)
        if let layer = layer {
            let small = CATransform3DConcat(
                CATransform3DConcat(CATransform3DMakeTranslation(-discCenter.x, -discCenter.y, 0),
                                    CATransform3DMakeScale(0.35, 0.35, 1)),
                CATransform3DMakeTranslation(discCenter.x, discCenter.y, 0))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.transform = small; layer.opacity = 0
            CATransaction.commit()
            let a = CASpringAnimation(keyPath: "transform")
            a.fromValue = small; a.toValue = CATransform3DIdentity
            a.stiffness = CLIPSpring.Preset.settle.stiffness
            a.damping = CLIPSpring.Preset.settle.caDamping
            a.duration = a.settlingDuration
            layer.transform = CATransform3DIdentity
            layer.add(a, forKey: "bloom")
        }
        CLIPSpring.run(duration: 0.18) { [weak self] in self?.layer?.opacity = 1 }
        window?.makeFirstResponder(self)

        // Click anywhere outside the picker dismisses it.
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

    // MARK: Section-color mapping (model stores presets, not arbitrary RGB)

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
