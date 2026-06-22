import AppKit

/// Phase B — native connectors, Obsidian-Canvas style. Renders `state.connectors`
/// as `CAShapeLayer`s directly in the scrolled `FlippedContainer`, so the scroll
/// view's magnification pans/zooms them for free. Each edge is a single green
/// cubic bezier (see `ConnectorPathMath`) with a filled arrowhead at the target
/// side-center and an optional text-label pill at the midpoint. Stroke / arrow /
/// label sizes are divided by `magnification` to stay a constant on-screen size,
/// so they redraw live as cards are dragged (`refreshConnectors(offsets:)`).
final class ConnectorOverlayController {

    private let root = CALayer()

    private struct Bundle {
        let line: CAShapeLayer
        let arrow: CAShapeLayer
        let dot: CAShapeLayer       // green-ring / yellow source port
        let labelBG: CALayer        // canvas mask (rest) OR green pill (selected)
        let labelWhite: CALayer     // white inner pill (selected only)
        let labelText: CATextLayer
    }
    private var bundles: [UUID: Bundle] = [:]

    /// Midpoint of each connector in content space — used by the double-click
    /// label editor to position its field. Refreshed every `redraw`.
    private(set) var midpoints: [UUID: CGPoint] = [:]

    // Cached inputs from the last full `update`, so a live card drag can redraw
    // from them + `liveOffsets` without rebuilding from the committed model.
    private var lastConnectors: [Connector] = []
    private var lastFrames: [UUID: CGRect] = [:]
    private var lastSelected: Set<UUID> = []
    private var lastMag: CGFloat = 1
    /// Per-node visual offsets while a card is being dragged (content units).
    /// Applied on EVERY redraw so a stray refresh can't reset the lines mid-drag.
    private var liveOffsets: [UUID: CGPoint] = [:]

    // Base on-screen sizes (divided by magnification each refresh).
    private static let screenLineWidth: CGFloat = 1      // 1px thinner
    private static let selectedLineWidth: CGFloat = 2.5
    private static let arrowLen: CGFloat = 10
    private static let arrowHalf: CGFloat = 4.5
    private static let labelFontSize: CGFloat = 18   // SCREEN-constant (÷mag)
    private static let dotDiameter: CGFloat = 11     // source port (≈20% smaller) — green ring + yellow centre
    private static let dotRing: CGFloat = 2.5
    private static let hoverDotDiameter: CGFloat = 13  // connect-hover port (≈20% smaller)
    private static let hoverDotRing: CGFloat = 2.5
    /// Canvas backdrop colour (light theme #EDF0F1) — masks the line behind the label.
    private static let labelBackground = NSColor(srgbRed: 0.929, green: 0.941, blue: 0.945, alpha: 1)
    /// Label text #16181A (Figma).
    private static let labelTextColor = NSColor(srgbRed: 0.086, green: 0.094, blue: 0.102, alpha: 1)

    /// Brand green (#3DA726) for the line/arrow; brighter green when selected.
    private static let green = NSColor(srgbRed: 0.239, green: 0.655, blue: 0.149, alpha: 1)
    private static let greenSelected = NSColor(srgbRed: 0.298, green: 0.769, blue: 0.196, alpha: 1)
    /// Yellow source dot (#F0EC00, Figma 88-441).
    private static let dotYellow = NSColor(srgbRed: 0.943, green: 0.926, blue: 0.0, alpha: 1)

    func attach(to container: NSView) {
        container.wantsLayer = true
        root.zPosition = 50   // above cards, below the selection chrome
        container.layer?.addSublayer(root)
    }

    // MARK: - Connect-hover port (Figma 100-297)

    /// Green-ring / yellow-centre dot shown on a card's side-centre while the
    /// connector tool hovers it — signals "drag a connector from here".
    private lazy var hoverDot: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = Self.dotYellow.cgColor
        l.strokeColor = Self.green.cgColor
        l.zPosition = 70                       // above the connector lines
        l.isHidden = true
        root.addSublayer(l)
        return l
    }()

    private var hoverGen = 0

    func showHoverDot(at point: CGPoint, mag: CGFloat) {
        hoverGen += 1
        let d = Self.hoverDotDiameter / mag
        let wasHidden = hoverDot.isHidden
        // Centred bounds + position so the scale spring grows from the dot's centre.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverDot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        hoverDot.position = point
        hoverDot.lineWidth = Self.hoverDotRing / mag
        hoverDot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d), transform: nil)
        hoverDot.transform = CATransform3DIdentity
        hoverDot.isHidden = false
        CATransaction.commit()
        if wasHidden { hoverDot.add(Self.popSpring(from: 0.2, to: 1), forKey: "pop") }
    }

    func hideHoverDot() {
        guard !hoverDot.isHidden else { return }
        hoverGen += 1
        let gen = hoverGen
        hoverDot.add(Self.popSpring(from: 1, to: 0.2), forKey: "pop")
        // Hide once the spring-down settles — unless it was re-shown meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, self.hoverGen == gen else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.hoverDot.isHidden = true
            self.hoverDot.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    /// Pleasurable scale spring (≈ Motion.pop) for the connect port.
    private static func popSpring(from: CGFloat, to: CGFloat) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = from; a.toValue = to
        a.mass = 1; a.stiffness = 220; a.damping = 15; a.initialVelocity = 0
        a.duration = a.settlingDuration
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        return a
    }

    func removeFromSuperlayer() { root.removeFromSuperlayer() }

    /// Full refresh from the model: cache the inputs, then redraw (applying any
    /// active live drag offsets). `nodeFrames` are the committed content-space
    /// frames (no drag offset — that's `liveOffsets`).
    func update(connectors: [Connector],
                nodeFrames: [UUID: CGRect],
                selected: Set<UUID>,
                magnification: CGFloat) {
        lastConnectors = connectors
        lastFrames = nodeFrames
        lastSelected = selected
        lastMag = max(magnification, 0.0001)
        redraw()
    }

    /// Set per-node drag offsets and redraw immediately. Called every drag tick
    /// (`liveReposition`) so the lines track the cards live; persists across any
    /// other `update`/`redraw` until cleared with `[:]` on drop.
    func setLiveDragOffsets(_ offsets: [UUID: CGPoint]) {
        liveOffsets = offsets
        redraw()
    }

    private func redraw() {
        let mag = lastMag
        var seen = Set<UUID>()
        var mids: [UUID: CGPoint] = [:]

        CATransaction.begin(); CATransaction.setDisableActions(true)
        for c in lastConnectors {
            guard var s = lastFrames[c.sourceID], var t = lastFrames[c.targetID] else { continue }
            if let o = liveOffsets[c.sourceID] { s.origin.x += o.x; s.origin.y += o.y }
            if let o = liveOffsets[c.targetID] { t.origin.x += o.x; t.origin.y += o.y }
            seen.insert(c.id)
            let isSel = lastSelected.contains(c.id)
            let route = ConnectorPathMath.route(source: s, target: t)
            mids[c.id] = route.midpoint

            let b = bundles[c.id] ?? makeBundle(for: c.id)
            let color = (isSel ? Self.greenSelected : Self.green).cgColor

            // Break the line under the label so it doesn't cross the text (Figma).
            b.line.path = c.label.isEmpty ? route.path
                : gappedLinePath(route, gap: labelGapWidth(c.label, mag: mag, selected: isSel))
            b.line.lineWidth = (isSel ? Self.selectedLineWidth : Self.screenLineWidth) / mag
            b.line.strokeColor = color

            b.arrow.path = arrowPath(tip: route.arrowTip, from: route.arrowFrom, mag: mag)
            b.arrow.fillColor = color

            // Source port (Figma 88-480): green ring + yellow centre, screen-constant.
            let d = Self.dotDiameter / mag
            b.dot.lineWidth = Self.dotRing / mag
            b.dot.path = CGPath(ellipseIn: CGRect(x: route.sourceAnchor.x - d / 2,
                                                  y: route.sourceAnchor.y - d / 2,
                                                  width: d, height: d), transform: nil)

            layoutLabel(b, text: c.label, center: route.midpoint, mag: mag, selected: isSel)
        }
        // Drop layers for connectors that no longer exist.
        for (id, b) in bundles where !seen.contains(id) {
            b.line.removeFromSuperlayer(); b.arrow.removeFromSuperlayer()
            b.dot.removeFromSuperlayer()
            b.labelBG.removeFromSuperlayer(); b.labelWhite.removeFromSuperlayer()
            b.labelText.removeFromSuperlayer()
            bundles[id] = nil
        }
        midpoints = mids
        CATransaction.commit()
    }

    // MARK: - Drag-to-connect preview

    private var previewLine: CAShapeLayer?
    private var previewArrow: CAShapeLayer?

    /// Draw the in-flight drag-to-connect bezier (dashed green) from `sourceRect`
    /// to `targetRect` (a 0-size rect at the cursor when not hovering a node).
    func setPreview(sourceRect: CGRect, targetRect: CGRect, magnification: CGFloat) {
        let mag = max(magnification, 0.0001)
        if previewLine == nil {
            let line = CAShapeLayer()
            line.fillColor = nil
            line.lineCap = .round
            line.strokeColor = Self.green.cgColor
            line.zPosition = 60
            let arrow = CAShapeLayer()
            arrow.strokeColor = nil
            arrow.fillColor = Self.green.cgColor
            arrow.zPosition = 60
            root.addSublayer(line); root.addSublayer(arrow)
            previewLine = line; previewArrow = arrow
        }
        let route = ConnectorPathMath.route(source: sourceRect, target: targetRect)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLine?.path = route.path
        previewLine?.lineWidth = Self.screenLineWidth / mag
        previewLine?.lineDashPattern = [NSNumber(value: 5 / mag), NSNumber(value: 4 / mag)]
        previewArrow?.path = arrowPath(tip: route.arrowTip, from: route.arrowFrom, mag: mag)
        CATransaction.commit()
    }

    func clearPreview() {
        previewLine?.removeFromSuperlayer(); previewLine = nil
        previewArrow?.removeFromSuperlayer(); previewArrow = nil
    }

    /// The connector whose line passes within `tolerance` (content units) of
    /// `point` — used by CanvasInputView to select / edit / delete a connector.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> UUID? {
        for (id, b) in bundles {
            guard let path = b.line.path else { continue }
            let outline = path.copy(strokingWithWidth: max(tolerance, 1),
                                    lineCap: .round, lineJoin: .round, miterLimit: 1)
            if outline.contains(point) { return id }
        }
        return nil
    }

    // MARK: - Layer construction

    private func makeBundle(for id: UUID) -> Bundle {
        let line = CAShapeLayer()
        line.fillColor = nil
        line.lineCap = .round
        line.lineJoin = .round

        let arrow = CAShapeLayer()
        arrow.strokeColor = nil

        let dot = CAShapeLayer()
        dot.fillColor = Self.dotYellow.cgColor       // yellow centre
        dot.strokeColor = Self.green.cgColor         // green ring (matches the hover port)

        let labelBG = CALayer()
        labelBG.cornerCurve = .continuous
        labelBG.isHidden = true

        let labelWhite = CALayer()
        labelWhite.backgroundColor = NSColor.white.cgColor
        labelWhite.cornerCurve = .continuous
        labelWhite.isHidden = true

        let labelText = CATextLayer()
        labelText.alignmentMode = .center
        labelText.truncationMode = .none
        labelText.isWrapped = false
        labelText.isHidden = true

        root.addSublayer(line)
        root.addSublayer(arrow)
        root.addSublayer(dot)
        root.addSublayer(labelBG)
        root.addSublayer(labelWhite)
        root.addSublayer(labelText)
        let b = Bundle(line: line, arrow: arrow, dot: dot,
                       labelBG: labelBG, labelWhite: labelWhite, labelText: labelText)
        bundles[id] = b
        return b
    }

    /// Filled triangle at `tip`, pointing along (tip − from). Constant on-screen.
    private func arrowPath(tip: CGPoint, from: CGPoint, mag: CGFloat) -> CGPath {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let len = max(hypot(dx, dy), 0.0001)
        let ux = dx / len, uy = dy / len
        let size = Self.arrowLen / mag
        let half = Self.arrowHalf / mag
        let baseX = tip.x - ux * size, baseY = tip.y - uy * size
        let px = -uy, py = ux
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: baseX + px * half, y: baseY + py * half))
        path.addLine(to: CGPoint(x: baseX - px * half, y: baseY - py * half))
        path.closeSubpath()
        return path
    }

    /// Position the midpoint label in CONTENT space (so it scales with zoom like
    /// the cards / Obsidian). A subtle canvas-coloured chip masks the line behind
    /// the dark text. Uses an attributed string so the font + colour render
    /// reliably (a bare `CATextLayer.font = NSFont` often draws nothing).
    private func layoutLabel(_ b: Bundle, text: String, center: CGPoint, mag: CGFloat, selected: Bool) {
        guard !text.isEmpty else {
            b.labelBG.isHidden = true; b.labelWhite.isHidden = true; b.labelText.isHidden = true
            return
        }
        b.labelText.isHidden = false

        let shown = text.uppercased()              // Figma: uppercase label text
        // DAMPENED zoom: content size = base / √mag → on-screen size = base · √mag, so
        // it shrinks when zooming out but far less than the cards (which scale by mag).
        let m = sqrt(mag)
        let fs = Self.labelFontSize / m
        let font = NSFont.monospacedSystemFont(ofSize: fs, weight: .semibold)   // SF Mono Semibold (Figma)
        let measured = (shown as NSString).size(withAttributes: [.font: font])
        func centred(_ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        }

        if selected {
            // Green pill + white inner pill (Figma 100-319).
            let whitePadH = 14 / m, whitePadV = 8 / m, greenPad = 4 / m
            let whiteW = measured.width + whitePadH * 2, whiteH = measured.height + whitePadV * 2
            b.labelBG.isHidden = false
            b.labelBG.frame = centred(whiteW + greenPad * 2, whiteH + greenPad * 2)
            b.labelBG.cornerRadius = (whiteH + greenPad * 2) / 2
            b.labelBG.backgroundColor = Self.green.cgColor
            b.labelWhite.isHidden = false
            b.labelWhite.frame = centred(whiteW, whiteH)
            b.labelWhite.cornerRadius = whiteH / 2
        } else {
            // Rest: plain text on the line, NO background chip (Figma 88-482).
            b.labelBG.isHidden = true
            b.labelWhite.isHidden = true
        }

        b.labelText.frame = centred(measured.width, measured.height)
        b.labelText.string = NSAttributedString(string: shown, attributes: [
            .font: font,
            .foregroundColor: Self.labelTextColor      // Figma #16181A
        ])
        b.labelText.contentsScale = 3              // crisp when zoomed in
    }

    // MARK: - Label line gap

    /// Width (content units) of the gap the line should leave for the label.
    private func labelGapWidth(_ text: String, mag: CGFloat, selected: Bool) -> CGFloat {
        let m = sqrt(mag)
        let font = NSFont.monospacedSystemFont(ofSize: Self.labelFontSize / m, weight: .semibold)
        let w = (text.uppercased() as NSString).size(withAttributes: [.font: font]).width
        return w + (selected ? 44 : 22) / m            // text + the pill / breathing room
    }

    /// The bezier with a centred `gap` removed (two sub-curves) so the label sits
    /// in a clean break in the line (Figma — line interrupts under the label).
    private func gappedLinePath(_ r: BezierRoute, gap: CGFloat) -> CGPath {
        let p0 = r.sourceAnchor, p1 = r.control1, p2 = r.control2, p3 = r.arrowFrom
        let chord = hypot(p3.x - p0.x, p3.y - p0.y)
        let net = hypot(p1.x - p0.x, p1.y - p0.y) + hypot(p2.x - p1.x, p2.y - p1.y)
                + hypot(p3.x - p2.x, p3.y - p2.y)
        let len = max((chord + net) / 2, 1)            // cheap cubic-length estimate
        let tHalf = min(0.42, (gap / 2) / len)
        let path = CGMutablePath()
        let s1 = Self.subCurve(p0, p1, p2, p3, 0, 0.5 - tHalf)
        path.move(to: s1.0); path.addCurve(to: s1.3, control1: s1.1, control2: s1.2)
        let s2 = Self.subCurve(p0, p1, p2, p3, 0.5 + tHalf, 1)
        path.move(to: s2.0); path.addCurve(to: s2.3, control1: s2.1, control2: s2.2)
        return path
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// The [ta, tb] portion of cubic bezier (p0,p1,p2,p3) → (start, c1, c2, end).
    private static func subCurve(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
                                 _ ta: CGFloat, _ tb: CGFloat) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        // De Casteljau: split at ta, keep the second half [ta,1] …
        let a1 = lerp(p0, p1, ta), b1 = lerp(p1, p2, ta), c1 = lerp(p2, p3, ta)
        let d1 = lerp(a1, b1, ta), e1 = lerp(b1, c1, ta)
        let q0 = lerp(d1, e1, ta), q1 = e1, q2 = c1, q3 = p3
        // … then take [0, u] of that, where u maps tb onto the sub-curve.
        let u = (tb - ta) / max(1 - ta, 0.0001)
        let a2 = lerp(q0, q1, u), b2 = lerp(q1, q2, u), c2 = lerp(q2, q3, u)
        let d2 = lerp(a2, b2, u), e2 = lerp(b2, c2, u)
        return (q0, a2, d2, lerp(d2, e2, u))
    }
}
