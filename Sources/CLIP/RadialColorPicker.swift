import AppKit

// MARK: - Native radial color picker (Spatial's flower color wheel)

/// A self-contained native color picker shaped like Spatial's flower wheel: two
/// rings of hue petals (saturated outer, lighter inner) around a white center,
/// on a dark glowing disc. Hovering a petal scales it + fires a soft haptic;
/// clicking picks. Springs in/out. No SwiftUI — pure CALayer + AppKit events.
final class RadialColorPicker: NSView {

    var onPick: (NSColor) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    private struct Petal { let layer: CAShapeLayer; let color: NSColor; let center: CGPoint }
    private var petals: [Petal] = []
    private let disc = CALayer()
    private let centerDot = CAShapeLayer()
    private var tracking: NSTrackingArea?
    private var hovered: Int? = nil

    private let diameter: CGFloat

    init(diameter: CGFloat = 168) {
        self.diameter = diameter
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        buildDisc()
        buildPetals()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var R: CGFloat { diameter / 2 }

    private let halo = CAGradientLayer()

    private func buildDisc() {
        // Rainbow conic halo behind the dark disc (the colorful glow ring in
        // Spatial's picker). The dark disc on top leaves a thin spectrum ring.
        halo.type = .conic
        halo.frame = bounds.insetBy(dx: -7, dy: -7)
        halo.cornerRadius = halo.frame.width / 2
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 0.5, y: 0)
        halo.colors = (0...12).map { NSColor(hue: CGFloat($0) / 12, saturation: 0.9, brightness: 1, alpha: 1).cgColor }
        halo.shadowColor = NSColor.black.cgColor
        halo.shadowOpacity = 0.30
        halo.shadowRadius = 20
        halo.shadowOffset = CGSize(width: 0, height: 8)
        layer?.addSublayer(halo)

        disc.frame = bounds
        disc.cornerRadius = R
        disc.backgroundColor = NSColor(white: 0.10, alpha: 0.96).cgColor   // halo provides the drop shadow
        layer?.addSublayer(disc)
        // White center "pick neutral" dot.
        let cr = R * 0.17
        centerDot.path = CGPath(ellipseIn: CGRect(x: center.x - cr, y: center.y - cr,
                                                  width: cr * 2, height: cr * 2), transform: nil)
        centerDot.fillColor = NSColor.white.cgColor
        centerDot.shadowColor = NSColor.black.cgColor
        centerDot.shadowOpacity = 0.25
        centerDot.shadowRadius = 3
        layer?.addSublayer(centerDot)
    }

    private func buildPetals() {
        let count = 12
        // ring: (innerR, outerR, saturation, brightness)
        let rings: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (R * 0.50, R * 0.95, 0.90, 0.96),   // outer — saturated
            (R * 0.20, R * 0.52, 0.52, 1.00),   // inner — light tints
        ]
        for (innerR, outerR, sat, bri) in rings {
            for i in 0..<count {
                let angle = (CGFloat(i) / CGFloat(count)) * .pi * 2 - .pi / 2
                let color = NSColor(hue: CGFloat(i) / CGFloat(count),
                                    saturation: sat, brightness: bri, alpha: 1)
                let mid = CGPoint(x: center.x + cos(angle) * (innerR + outerR) / 2,
                                  y: center.y + sin(angle) * (innerR + outerR) / 2)
                let p = CAShapeLayer()
                p.path = petalPath(angle: angle, innerR: innerR, outerR: outerR, count: count)
                p.fillColor = color.cgColor
                p.strokeColor = NSColor.black.withAlphaComponent(0.10).cgColor
                p.lineWidth = 0.5
                layer?.addSublayer(p)
                petals.append(Petal(layer: p, color: color, center: mid))
            }
        }
    }

    /// A rounded capsule "petal" radiating from the center — gives the soft
    /// flower look (vs a hard pie wedge), like Spatial's wheel.
    private func petalPath(angle: CGFloat, innerR: CGFloat, outerR: CGFloat, count: Int) -> CGPath {
        let midR = (innerR + outerR) / 2
        let length = outerR - innerR
        let width = (.pi * 2 / CGFloat(count)) * midR * 0.62      // arc-width with a gap
        let mid = CGPoint(x: center.x + cos(angle) * midR, y: center.y + sin(angle) * midR)
        let rect = CGRect(x: -length / 2, y: -width / 2, width: length, height: width)
        var t = CGAffineTransform(translationX: mid.x, y: mid.y).rotated(by: angle)
        return CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: &t)
    }

    // MARK: Hover + pick

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = nearestPetal(to: p)
        if idx != hovered {
            hovered = idx
            CLIPHaptics.snap()                            // tick when the highlighted color changes
            NSCursor.pointingHand.set()
            for (i, petal) in petals.enumerated() { scale(petal.layer, i == idx ? 1.18 : 1.0) }
        }
    }
    override func mouseExited(with event: NSEvent) {
        hovered = nil
        NSCursor.arrow.set()
        for petal in petals { scale(petal.layer, 1.0) }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - center.x, p.y - center.y) <= R * 0.17 {
            pick(.white); return
        }
        if let idx = nearestPetal(to: p) { pick(petals[idx].color) }
    }

    private func pick(_ color: NSColor) {
        CLIPHaptics.levelChange()
        onPick(color)
        dismiss()
    }

    private func nearestPetal(to p: CGPoint) -> Int? {
        // Only consider the petal whose path contains the point (exact).
        for (i, petal) in petals.enumerated() where petal.layer.path?.contains(p) == true { return i }
        return nil
    }

    private func scale(_ layer: CAShapeLayer, _ s: CGFloat) {
        let c = layer.path.map { $0.boundingBox } ?? bounds
        let pivot = CGPoint(x: c.midX, y: c.midY)
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
        layer.zPosition = s > 1 ? 10 : 0
    }

    // MARK: Present / dismiss

    /// Present centered at `point` (in `host` coords), springing up from small.
    func present(in host: NSView, at point: CGPoint) {
        frame = CGRect(x: point.x - R, y: point.y - R, width: diameter, height: diameter)
        host.addSubview(self)
        if let layer = layer {
            let c = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
            let small = CATransform3DConcat(
                CATransform3DConcat(CATransform3DMakeTranslation(-c.x, -c.y, 0),
                                    CATransform3DMakeScale(0.4, 0.4, 1)),
                CATransform3DMakeTranslation(c.x, c.y, 0))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.transform = small; layer.opacity = 0
            CATransaction.commit()
        }
        CLIPSpring.scale(self, to: 1.0, preset: .settle)               // spring small → full
        CLIPSpring.run(duration: 0.18) { [weak self] in self?.layer?.opacity = 1 }
        window?.makeFirstResponder(self)
    }

    func dismiss() {
        CLIPSpring.run(duration: 0.16, _: { [weak self] in self?.layer?.opacity = 0 }) { [weak self] in
            self?.removeFromSuperview()
        }
        onDismiss()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss() } else { super.keyDown(with: event) }
    }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Section-color mapping (the model stores 5 presets, not arbitrary RGB)

    /// Nearest `SectionColor` preset to an arbitrary picked color — lets the
    /// flower wheel drive the existing section palette without a model change.
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
