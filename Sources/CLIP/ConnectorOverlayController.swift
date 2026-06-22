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
        let dot: CAShapeLayer       // yellow source dot
        let labelBG: CALayer
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
    private static let screenLineWidth: CGFloat = 2
    private static let selectedLineWidth: CGFloat = 3.5
    private static let arrowLen: CGFloat = 10
    private static let arrowHalf: CGFloat = 4.5
    private static let labelFontSize: CGFloat = 17   // CONTENT units (Figma: SF Mono Semibold 17) → scales with zoom
    private static let dotDiameter: CGFloat = 9      // yellow source dot (Figma 88-441), screen-constant
    private static let hoverDotDiameter: CGFloat = 16  // connect-hover port (Figma 100-297)
    private static let hoverDotRing: CGFloat = 3
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

    func showHoverDot(at point: CGPoint, mag: CGFloat) {
        let d = Self.hoverDotDiameter / mag
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverDot.lineWidth = Self.hoverDotRing / mag
        hoverDot.path = CGPath(ellipseIn: CGRect(x: point.x - d / 2, y: point.y - d / 2,
                                                 width: d, height: d), transform: nil)
        hoverDot.isHidden = false
        CATransaction.commit()
    }

    func hideHoverDot() {
        guard !hoverDot.isHidden else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverDot.isHidden = true
        CATransaction.commit()
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

            b.line.path = route.path
            b.line.lineWidth = (isSel ? Self.selectedLineWidth : Self.screenLineWidth) / mag
            b.line.strokeColor = color

            b.arrow.path = arrowPath(tip: route.arrowTip, from: route.arrowFrom, mag: mag)
            b.arrow.fillColor = color

            // Yellow source dot (Figma 88-441), screen-constant.
            let d = Self.dotDiameter / mag
            b.dot.path = CGPath(ellipseIn: CGRect(x: route.sourceAnchor.x - d / 2,
                                                  y: route.sourceAnchor.y - d / 2,
                                                  width: d, height: d), transform: nil)

            layoutLabel(b, text: c.label, center: route.midpoint, mag: mag, selected: isSel)
        }
        // Drop layers for connectors that no longer exist.
        for (id, b) in bundles where !seen.contains(id) {
            b.line.removeFromSuperlayer(); b.arrow.removeFromSuperlayer()
            b.dot.removeFromSuperlayer()
            b.labelBG.removeFromSuperlayer(); b.labelText.removeFromSuperlayer()
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
        dot.fillColor = Self.dotYellow.cgColor
        dot.strokeColor = nil

        let labelBG = CALayer()
        labelBG.backgroundColor = Self.labelBackground.cgColor
        labelBG.cornerCurve = .continuous
        labelBG.isHidden = true

        let labelText = CATextLayer()
        labelText.alignmentMode = .center
        labelText.truncationMode = .none
        labelText.isWrapped = false
        labelText.isHidden = true

        root.addSublayer(line)
        root.addSublayer(arrow)
        root.addSublayer(dot)
        root.addSublayer(labelBG)
        root.addSublayer(labelText)
        let b = Bundle(line: line, arrow: arrow, dot: dot, labelBG: labelBG, labelText: labelText)
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
            b.labelBG.isHidden = true; b.labelText.isHidden = true
            return
        }
        b.labelBG.isHidden = false; b.labelText.isHidden = false

        let shown = text.uppercased()              // Figma: uppercase label text
        let fs = Self.labelFontSize                // content units → scales with zoom
        let font = NSFont.monospacedSystemFont(ofSize: fs, weight: .semibold)   // SF Mono Semibold (Figma)
        let measured = (shown as NSString).size(withAttributes: [.font: font])
        let padH: CGFloat = 8, padV: CGFloat = 4
        let w = measured.width + padH * 2
        let h = measured.height + padV * 2

        b.labelBG.frame = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        b.labelBG.cornerRadius = 5
        b.labelBG.borderWidth = selected ? 2 : 0
        b.labelBG.borderColor = Self.greenSelected.cgColor

        b.labelText.frame = CGRect(x: center.x - measured.width / 2,
                                   y: center.y - measured.height / 2,
                                   width: measured.width, height: measured.height)
        b.labelText.string = NSAttributedString(string: shown, attributes: [
            .font: font,
            .foregroundColor: Self.labelTextColor      // Figma #16181A
        ])
        b.labelText.contentsScale = 3              // crisp when zoomed in
    }
}
