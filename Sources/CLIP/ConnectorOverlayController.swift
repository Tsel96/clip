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
    /// Clickable label region per connector (content space) — so clicking the
    /// label text selects the connector even in the rest (no-pill) state.
    private(set) var labelHitRects: [UUID: CGRect] = [:]

    // Cached inputs from the last full `update`, so a live card drag can redraw
    // from them + `liveOffsets` without rebuilding from the committed model.
    private var lastConnectors: [Connector] = []
    private var lastFrames: [UUID: CGRect] = [:]
    private var lastSelected: Set<UUID> = []
    private var lastMag: CGFloat = 1
    /// Per-node visual offsets while a card is being dragged (content units).
    /// Applied on EVERY redraw so a stray refresh can't reset the lines mid-drag.
    private var liveOffsets: [UUID: CGPoint] = [:]
    /// While the user drags a connector's LABEL, its absolute offset from the
    /// bezier midpoint (content units). Visual only; persisted to the model on drop.
    private var liveLabelDrag: (id: UUID, offset: CGPoint)?

    // Base on-screen sizes (divided by magnification each refresh).
    private static let screenLineWidth: CGFloat = 1      // 1px thinner
    private static let selectedLineWidth: CGFloat = 2.5
    private static let arrowLen: CGFloat = 7.8  // on-screen apex→base length (Polygon-6 arrowhead, −35%)
    private static let labelFontSize: CGFloat = 18   // SCREEN-constant (÷mag)
    private static let dotDiameter: CGFloat = 11     // source port (≈20% smaller) — green ring + yellow centre
    private static let dotRing: CGFloat = 2.5
    private static let hoverDotDiameter: CGFloat = 13  // connect-hover port (≈20% smaller)
    private static let hoverDotRing: CGFloat = 2.5
    /// Floor for a port's ON-SCREEN diameter — the √mag dampening alone shrank
    /// ports to a few px around 17% zoom; this keeps them grabbable when far out.
    private static let minScreenDot: CGFloat = 9

    /// Port diameter in CONTENT units: dampened √mag zoom (on-screen ≈ base·√mag),
    /// but never below `minScreenDot` on screen (on-screen = content·mag).
    private static func portDiameter(base: CGFloat, mag: CGFloat) -> CGFloat {
        max(base / sqrt(mag), minScreenDot / mag)
    }
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

    /// The dot's live on-screen scale (presentation value) — the retarget
    /// origin for the coalescing show/hide spring.
    private func hoverDotLiveScale() -> CGFloat {
        if let n = hoverDot.presentation()?.value(forKeyPath: "transform.scale.x") as? NSNumber {
            return CGFloat(truncating: n)
        }
        return CGFloat(hoverDot.transform.m11)
    }

    func showHoverDot(at point: CGPoint, mag: CGFloat) {
        hoverGen += 1
        // Dampened √mag zoom with a screen-size floor (matching the source port).
        let d = Self.portDiameter(base: Self.hoverDotDiameter, mag: mag)
        let wasHidden = hoverDot.isHidden
        // Retarget origin BEFORE touching the model transform: a show that
        // lands mid-hide picks up from the live shrinking scale, no jump.
        let from = wasHidden ? 0.2 : hoverDotLiveScale()
        // Centred bounds + position so the scale spring grows from the dot's centre.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverDot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        hoverDot.position = point
        hoverDot.lineWidth = d * (Self.hoverDotRing / Self.hoverDotDiameter)
        hoverDot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d), transform: nil)
        hoverDot.transform = CATransform3DIdentity
        hoverDot.isHidden = false
        CATransaction.commit()
        // Same key both directions → one coalescing spring; the model value is
        // committed above, so no fill-forwards residue accumulates.
        hoverDot.add(Self.popSpring(from: from, to: 1), forKey: "pop")
    }

    func hideHoverDot() {
        guard !hoverDot.isHidden else { return }
        hoverGen += 1
        let gen = hoverGen
        let from = hoverDotLiveScale()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverDot.transform = CATransform3DMakeScale(0.2, 0.2, 1)
        CATransaction.commit()
        hoverDot.add(Self.popSpring(from: from, to: 0.2), forKey: "pop")
        // Hide once the spring-down settles — unless it was re-shown meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, self.hoverGen == gen else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.hoverDot.isHidden = true
            self.hoverDot.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    /// Pleasurable scale spring for the connect port — the native mirror of
    /// `Motion.pop` via `CLIPSpring.Preset.pop`. Model values are committed
    /// by the callers, so no fill-forwards / never-removed residue.
    private static func popSpring(from: CGFloat, to: CGFloat) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = from; a.toValue = to
        a.mass = 1
        a.stiffness = CLIPSpring.Preset.pop.stiffness
        a.damping = CLIPSpring.Preset.pop.caDamping
        a.initialVelocity = 0
        a.duration = a.settlingDuration
        return a
    }

    func removeFromSuperlayer() { root.removeFromSuperlayer() }

    /// Show/hide ALL connector chrome (lines, ports, labels) — driven by the
    /// `showConnectors` toggle in the bottom-left control bar.
    func setVisible(_ visible: Bool) { root.isHidden = !visible }

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
        // NB: do NOT clear `liveLabelDrag` here — an unrelated refresh mid-drag
        // would wipe the offset and the label would stop following the cursor.
        // It's cleared explicitly by `commitLabelOffset` on mouse-up (which also
        // patches the cache so there's no snap-back).
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
        var lblRects: [UUID: CGRect] = [:]

        CATransaction.begin(); CATransaction.setDisableActions(true)
        for c in lastConnectors {
            guard var s = lastFrames[c.sourceID], var t = lastFrames[c.targetID] else { continue }
            if let o = liveOffsets[c.sourceID] { s.origin.x += o.x; s.origin.y += o.y }
            if let o = liveOffsets[c.targetID] { t.origin.x += o.x; t.origin.y += o.y }
            seen.insert(c.id)
            let isSel = lastSelected.contains(c.id)
            // Standoff is screen-constant (÷mag) so the line always ends where the
            // (also screen-constant) arrowhead begins — otherwise at high zoom the
            // 7-content-unit standoff balloons to a big gap before the arrow.
            let route = ConnectorPathMath.route(source: s, target: t,
                                                sourceSide: c.sourceSide, targetSide: c.targetSide,
                                                standoff: ConnectorPathMath.standoffDistance / mag)

            let b = bundles[c.id] ?? makeBundle(for: c.id)
            let color = (isSel ? Self.greenSelected : Self.green).cgColor

            // Label centre = midpoint + the user's (live-dragged or stored) offset.
            let hasLabel = !c.label.isEmpty
            let off = (liveLabelDrag?.id == c.id ? liveLabelDrag!.offset : (c.labelOffset ?? .zero))
            let labelCenter = CGPoint(x: route.midpoint.x + off.x, y: route.midpoint.y + off.y)
            mids[c.id] = labelCenter            // editor opens at the (dragged) label

            // Bend the curve THROUGH the label so the LINE FOLLOWS it: shifting both
            // control points by 4/3·offset moves B(0.5) onto the label (0 offset = the
            // plain route). The arrow/source endpoints stay pinned to their cards.
            let bx = hasLabel ? (4.0 / 3.0) * off.x : 0, by = hasLabel ? (4.0 / 3.0) * off.y : 0
            let p0 = route.sourceAnchor, p3 = route.arrowFrom
            let c1 = CGPoint(x: route.control1.x + bx, y: route.control1.y + by)
            let c2 = CGPoint(x: route.control2.x + bx, y: route.control2.y + by)
            let fullPath = CGMutablePath()
            fullPath.move(to: p0); fullPath.addCurve(to: p3, control1: c1, control2: c2)

            // Break the line under the label (at the curve point nearest the label).
            let lblBox = labelGapBox(c.label, mag: mag, selected: isSel)
            b.line.path = hasLabel
                ? gappedLinePath(p0: p0, p1: c1, p2: c2, p3: p3, labelCenter: labelCenter,
                                 labelW: lblBox.w, labelH: lblBox.h)
                : fullPath
            // Thicker when zoomed IN: a content-scaling width (≈1.8× content-
            // constant, so it grows clearly with the canvas) floored to a visible
            // screen minimum when zoomed out.
            let baseW = isSel ? Self.selectedLineWidth : Self.screenLineWidth
            b.line.lineWidth = max(baseW * 1.8, baseW / mag)
            b.line.strokeColor = color

            b.arrow.path = arrowPath(tip: route.arrowTip, from: route.arrowFrom, mag: mag)
            b.arrow.fillColor = color

            // Source port (Figma 88-480): green ring + yellow centre, DAMPENED zoom
            // (√mag) with a screen-size floor. Drawn at the side-CENTER (on the card
            // edge), NOT the standoff — else it floats off the card when zoomed in.
            let d = Self.portDiameter(base: Self.dotDiameter, mag: mag)
            b.dot.lineWidth = d * (Self.dotRing / Self.dotDiameter)
            b.dot.path = CGPath(ellipseIn: CGRect(x: route.sourceCenter.x - d / 2,
                                                  y: route.sourceCenter.y - d / 2,
                                                  width: d, height: d), transform: nil)

            if let r = layoutLabel(b, id: c.id, text: c.label, center: labelCenter, mag: mag, selected: isSel) {
                lblRects[c.id] = r
            }
        }
        labelHitRects = lblRects
        // Fade out + drop layers for connectors that no longer exist — matches
        // the 0.22s card-delete exit so a deleted card's connectors leave with
        // it instead of vanishing a frame early.
        for (id, b) in bundles where !seen.contains(id) {
            let layers = [b.line, b.arrow, b.dot, b.labelBG, b.labelWhite, b.labelText]
            for l in layers {
                let o = CABasicAnimation(keyPath: "opacity")
                o.fromValue = l.presentation()?.opacity ?? l.opacity
                o.toValue = 0
                o.duration = 0.22
                o.timingFunction = CLIPSpring.easeOutSoft
                l.opacity = 0
                l.add(o, forKey: "exitFade")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                layers.forEach { $0.removeFromSuperlayer() }
            }
            bundles[id] = nil
            labelKeys[id] = nil
        }
        midpoints = mids
        CATransaction.commit()
    }

    // MARK: - Drag-to-connect preview

    private var previewLine: CAShapeLayer?
    private var previewArrow: CAShapeLayer?

    /// Draw the in-flight drag-to-connect bezier (dashed green) from `sourceRect`
    /// to `targetRect` (a 0-size rect at the cursor when not hovering a node).
    func setPreview(sourceRect: CGRect, targetRect: CGRect,
                    sourceSide: ConnSide? = nil, targetSide: ConnSide? = nil,
                    magnification: CGFloat) {
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
        let route = ConnectorPathMath.route(source: sourceRect, target: targetRect,
                                            sourceSide: sourceSide, targetSide: targetSide,
                                            standoff: ConnectorPathMath.standoffDistance / mag)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLine?.path = route.path
        previewLine?.lineWidth = max(Self.screenLineWidth * 1.8, Self.screenLineWidth / mag)
        previewLine?.lineDashPattern = [NSNumber(value: 5 / mag), NSNumber(value: 4 / mag)]
        previewArrow?.path = arrowPath(tip: route.arrowTip, from: route.arrowFrom, mag: mag)
        CATransaction.commit()
    }

    func clearPreview() {
        previewLine?.removeFromSuperlayer(); previewLine = nil
        previewArrow?.removeFromSuperlayer(); previewArrow = nil
    }

    /// The connector whose LABEL contains `point` (content space) — for click-to-
    /// select and drag-to-reposition the label.
    func labelHitTest(_ point: CGPoint) -> UUID? {
        for (id, rect) in labelHitRects where rect.contains(point) { return id }
        return nil
    }

    /// Stored label offset for `id` (the drag-start reference).
    func storedLabelOffset(_ id: UUID) -> CGPoint {
        lastConnectors.first(where: { $0.id == id })?.labelOffset ?? .zero
    }

    /// Live label drag — visual only, redraws immediately; cleared on drop.
    func setLiveLabelOffset(id: UUID, offset: CGPoint) { liveLabelDrag = (id, offset); redraw() }
    func clearLiveLabelOffset() { liveLabelDrag = nil; redraw() }
    /// Commit a dragged label offset: patch the cached connector so the redraw
    /// keeps it in place, then clear the live drag (no snap-back before the model
    /// round-trips). The undoable model write happens separately via the config.
    func commitLabelOffset(_ id: UUID, _ offset: CGPoint) {
        if let i = lastConnectors.firstIndex(where: { $0.id == id }) {
            lastConnectors[i].labelOffset = offset
        }
        liveLabelDrag = nil
        redraw()
    }

    /// The connector whose line passes within `tolerance` (content units) of
    /// `point` — used by CanvasInputView to select / edit / delete a connector.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> UUID? {
        // A click on the label region counts as a hit on its connector.
        for (id, rect) in labelHitRects where rect.contains(point) { return id }
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
        // A new connector fades in rather than popping into existence in a
        // single frame (explicit animation — runs despite the disabled-actions
        // transaction redraw() wraps us in).
        for l in [line, arrow, dot] {
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = 0; o.toValue = 1
            o.duration = 0.14
            o.timingFunction = CLIPSpring.easeOutSoft
            l.add(o, forKey: "enterFade")
        }
        let b = Bundle(line: line, arrow: arrow, dot: dot,
                       labelBG: labelBG, labelWhite: labelWhite, labelText: labelText)
        bundles[id] = b
        return b
    }

    /// The Polygon-6 arrowhead (a wide, soft, rounded triangle) in its own 29×20
    /// design space — apex at the TOP (≈ y 0), base notch at the bottom. Built once;
    /// each arrow transforms a copy onto its tip.
    private static let arrowTemplate: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 12.3281, y: 1.46101))
        p.addCurve(to: CGPoint(x: 13.7787, y: 0.0666322), control1: CGPoint(x: 13.014, y: 0.618925), control2: CGPoint(x: 13.3569, y: 0.197882))
        p.addCurve(to: CGPoint(x: 14.6495, y: 0.0666322), control1: CGPoint(x: 14.0623, y: -0.0215984), control2: CGPoint(x: 14.3659, y: -0.0215984))
        p.addCurve(to: CGPoint(x: 16.1001, y: 1.46101), control1: CGPoint(x: 15.0713, y: 0.197882), control2: CGPoint(x: 15.4142, y: 0.618925))
        p.addLine(to: CGPoint(x: 24.6641, y: 11.9752))
        p.addCurve(to: CGPoint(x: 28.4155, y: 17.8832), control1: CGPoint(x: 27.2697, y: 15.1741), control2: CGPoint(x: 28.5724, y: 16.7736))
        p.addCurve(to: CGPoint(x: 27.2847, y: 19.6672), control1: CGPoint(x: 28.3124, y: 18.6127), control2: CGPoint(x: 27.9004, y: 19.2626))
        p.addCurve(to: CGPoint(x: 20.3408, y: 18.7957), control1: CGPoint(x: 26.3481, y: 20.2826), control2: CGPoint(x: 24.3457, y: 19.787))
        p.addLine(to: CGPoint(x: 14.2141, y: 17.2792))
        p.addLine(to: CGPoint(x: 8.08744, y: 18.7957))
        p.addCurve(to: CGPoint(x: 1.14355, y: 19.6672), control1: CGPoint(x: 4.08255, y: 19.787), control2: CGPoint(x: 2.0801, y: 20.2826))
        p.addCurve(to: CGPoint(x: 0.0126801, y: 17.8832), control1: CGPoint(x: 0.527801, y: 19.2626), control2: CGPoint(x: 0.115837, y: 18.6127))
        p.addCurve(to: CGPoint(x: 3.76411, y: 11.9752), control1: CGPoint(x: -0.144223, y: 16.7736), control2: CGPoint(x: 1.15855, y: 15.1741))
        p.addLine(to: CGPoint(x: 12.3281, y: 1.46101))
        p.closeSubpath()
        return p
    }()
    /// Template apex (centre of the pointed tip) — placed exactly on the arrowTip.
    private static let arrowApex = CGPoint(x: 14.2141, y: 0)
    /// Template apex→base span (viewBox height) — the template scales so this = arrowLen.
    private static let arrowTemplateHeight: CGFloat = 20

    /// The rounded Polygon-6 arrowhead at `tip`, pointing along (tip − from).
    /// Constant on-screen (÷mag): the template (apex up) is rotated so its apex
    /// points toward the tip, scaled to `arrowLen`, and translated onto the tip.
    private func arrowPath(tip: CGPoint, from: CGPoint, mag: CGFloat) -> CGPath {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let len = max(hypot(dx, dy), 0.0001)
        let ux = dx / len, uy = dy / len
        // Arrowhead grows with zoom-in to match the (now zoom-scaling) line,
        // floored to its base on-screen size when zoomed out.
        let arrowContent = max(Self.arrowLen * 1.4, Self.arrowLen / mag)
        let scale = arrowContent / Self.arrowTemplateHeight
        let theta = atan2(uy, ux) + .pi / 2          // maps the template "up" (0,−1) → (ux,uy)
        var tf = CGAffineTransform(translationX: tip.x, y: tip.y)
        tf = tf.rotated(by: theta)
        tf = tf.scaledBy(x: scale, y: scale)
        tf = tf.translatedBy(x: -Self.arrowApex.x, y: -Self.arrowApex.y)
        return Self.arrowTemplate.copy(using: &tf) ?? Self.arrowTemplate
    }

    /// Text-measurement cache: `redraw()` runs on EVERY drag tick and pan
    /// frame, and `size(withAttributes:)` + a CATextLayer string rebuild per
    /// labeled connector per frame is measurable work. Key = text + font
    /// size; mag is constant during a drag, so drags are pure cache hits
    /// (zoom changes the size legitimately and re-measures).
    private var labelSizeCache: [String: CGSize] = [:]
    /// Last applied (text|fontSize) key per connector — skips re-setting the
    /// CATextLayer string (which re-rasterizes glyphs) when nothing changed.
    private var labelKeys: [UUID: String] = [:]

    private func measuredLabel(_ shown: String, fontSize: CGFloat, font: NSFont) -> CGSize {
        let key = "\(String(format: "%.3f", fontSize))|\(shown)"
        if let hit = labelSizeCache[key] { return hit }
        if labelSizeCache.count > 512 { labelSizeCache.removeAll(keepingCapacity: true) }
        let size = (shown as NSString).size(withAttributes: [.font: font])
        labelSizeCache[key] = size
        return size
    }

    /// Position the midpoint label in CONTENT space (so it scales with zoom like
    /// the cards / Obsidian). A subtle canvas-coloured chip masks the line behind
    /// the dark text. Uses an attributed string so the font + colour render
    /// reliably (a bare `CATextLayer.font = NSFont` often draws nothing).
    @discardableResult
    private func layoutLabel(_ b: Bundle, id: UUID, text: String, center: CGPoint, mag: CGFloat, selected: Bool) -> CGRect? {
        guard !text.isEmpty else {
            b.labelBG.isHidden = true; b.labelWhite.isHidden = true; b.labelText.isHidden = true
            return nil
        }
        b.labelText.isHidden = false

        let shown = text.uppercased()              // Figma: uppercase label text
        // DAMPENED zoom: content size = base / √mag → on-screen size = base · √mag, so
        // it shrinks when zooming out but far less than the cards (which scale by mag).
        let m = sqrt(mag)
        let fs = Self.labelFontSize / m
        let font = NSFont.monospacedSystemFont(ofSize: fs, weight: .semibold)   // SF Mono Semibold (Figma)
        let measured = measuredLabel(shown, fontSize: fs, font: font)
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
        // Rebuild the attributed string ONLY when text/size changed — setting
        // an equal-but-new string still re-rasterizes the text layer.
        let key = "\(String(format: "%.3f", fs))|\(shown)"
        if labelKeys[id] != key {
            labelKeys[id] = key
            b.labelText.string = NSAttributedString(string: shown, attributes: [
                .font: font,
                .foregroundColor: Self.labelTextColor      // Figma #16181A
            ])
            b.labelText.contentsScale = 3              // crisp when zoomed in
        }
        // Clickable region (a touch larger than the glyphs) so a click on the label
        // selects the connector even in the rest (no-pill) state.
        return centred(measured.width + 18 / m, measured.height + 14 / m)
    }

    // MARK: - Label line gap

    /// The label's bounding box (content units) incl. breathing room. The line gap
    /// is the box's extent PROJECTED onto the line direction (computed in
    /// `gappedLinePath`), so a vertical connector through a wide label only breaks
    /// for the label's HEIGHT — not its full width (the "huge vertical gap" bug).
    private func labelGapBox(_ text: String, mag: CGFloat, selected: Bool) -> (w: CGFloat, h: CGFloat) {
        let m = sqrt(mag)
        let fs = Self.labelFontSize / m
        let font = NSFont.monospacedSystemFont(ofSize: fs, weight: .semibold)
        let size = measuredLabel(text.uppercased(), fontSize: fs, font: font)
        let breathing = (selected ? 44 : 22) / m       // pill / breathing room
        return (size.width + breathing, size.height + breathing)
    }

    /// The bezier with a gap removed at the curve point NEAREST the label, so the
    /// break sits under the label wherever it's been dragged (Figma — line
    /// interrupts under the label). The gap length = the label box's extent along
    /// the LOCAL line direction, so it's tight for any connector orientation.
    private func gappedLinePath(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint,
                                labelCenter: CGPoint, labelW: CGFloat, labelH: CGFloat) -> CGPath {
        func at(_ t: CGFloat) -> CGPoint {
            let u = 1 - t, a = (1-t)*(1-t)*(1-t), b = 3*u*u*t, c = 3*u*t*t, d = t*t*t
            return CGPoint(x: a*p0.x + b*p1.x + c*p2.x + d*p3.x,
                           y: a*p0.y + b*p1.y + c*p2.y + d*p3.y)
        }
        // t* minimising |B(t) − labelCenter| (the label's projection onto the curve).
        var tStar: CGFloat = 0.5, best = CGFloat.greatestFiniteMagnitude
        var t: CGFloat = 0
        while t <= 1.0001 {
            let pt = at(t), dd = hypot(pt.x - labelCenter.x, pt.y - labelCenter.y)
            if dd < best { best = dd; tStar = t }
            t += 0.02
        }
        // Convert the fixed-width gap to a t-range using the LOCAL speed |B'(t*)|.
        let u = 1 - tStar
        let vx = 3*u*u*(p1.x-p0.x) + 6*u*tStar*(p2.x-p1.x) + 3*tStar*tStar*(p3.x-p2.x)
        let vy = 3*u*u*(p1.y-p0.y) + 6*u*tStar*(p2.y-p1.y) + 3*tStar*tStar*(p3.y-p2.y)
        let speed = max(hypot(vx, vy), 1)
        // Gap length = the label box's extent along the LOCAL line direction
        // (support width of an axis-aligned box): |dirx|·W + |diry|·H. A horizontal
        // line removes the label WIDTH; a vertical line only the HEIGHT.
        let dirx = abs(vx) / speed, diry = abs(vy) / speed
        let gap = dirx * labelW + diry * labelH
        let tHalf = (gap / 2) / speed
        let ta = max(0, tStar - tHalf), tb = min(1, tStar + tHalf)
        let path = CGMutablePath()
        if ta > 0.001 {
            let s1 = Self.subCurve(p0, p1, p2, p3, 0, ta)
            path.move(to: s1.0); path.addCurve(to: s1.3, control1: s1.1, control2: s1.2)
        }
        if tb < 0.999 {
            let s2 = Self.subCurve(p0, p1, p2, p3, tb, 1)
            path.move(to: s2.0); path.addCurve(to: s2.3, control1: s2.1, control2: s2.2)
        }
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
