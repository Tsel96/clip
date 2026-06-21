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
    private static let labelFontSize: CGFloat = 13

    /// Brand green (#3DA726) for the line/arrow; brighter green when selected.
    private static let green = NSColor(srgbRed: 0.239, green: 0.655, blue: 0.149, alpha: 1)
    private static let greenSelected = NSColor(srgbRed: 0.298, green: 0.769, blue: 0.196, alpha: 1)

    func attach(to container: NSView) {
        container.wantsLayer = true
        root.zPosition = 50   // above cards, below the selection chrome
        container.layer?.addSublayer(root)
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

            layoutLabel(b, text: c.label, center: route.midpoint, mag: mag, selected: isSel)
        }
        // Drop layers for connectors that no longer exist.
        for (id, b) in bundles where !seen.contains(id) {
            b.line.removeFromSuperlayer(); b.arrow.removeFromSuperlayer()
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

        let labelBG = CALayer()
        labelBG.backgroundColor = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1).cgColor
        labelBG.borderColor = Self.green.withAlphaComponent(0.45).cgColor
        labelBG.cornerCurve = .continuous
        labelBG.isHidden = true

        let labelText = CATextLayer()
        labelText.alignmentMode = .center
        labelText.truncationMode = .end
        labelText.foregroundColor = NSColor(srgbRed: 0.1, green: 0.12, blue: 0.1, alpha: 1).cgColor
        labelText.isHidden = true

        root.addSublayer(line)
        root.addSublayer(arrow)
        root.addSublayer(labelBG)
        root.addSublayer(labelText)
        let b = Bundle(line: line, arrow: arrow, labelBG: labelBG, labelText: labelText)
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

    /// Position/size the midpoint label pill (content units; text stays constant
    /// on screen). Hidden when the label is empty.
    private func layoutLabel(_ b: Bundle, text: String, center: CGPoint, mag: CGFloat, selected: Bool) {
        guard !text.isEmpty else {
            b.labelBG.isHidden = true; b.labelText.isHidden = true
            return
        }
        b.labelBG.isHidden = false; b.labelText.isHidden = false

        let fontSize = Self.labelFontSize          // on-screen size
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let padH: CGFloat = 7, padV: CGFloat = 3
        // Convert on-screen sizes into content units (÷ mag).
        let w = (measured.width + padH * 2) / mag
        let h = (measured.height + padV * 2) / mag

        b.labelBG.frame = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        b.labelBG.cornerRadius = h / 2
        b.labelBG.borderWidth = (selected ? 1.5 : 1) / mag

        b.labelText.frame = b.labelBG.frame
        b.labelText.string = text
        b.labelText.fontSize = fontSize / mag
        b.labelText.font = font
        // Vertically center one line of text inside the pill.
        let textH = measured.height / mag
        b.labelText.frame.origin.y = center.y - textH / 2
        b.labelText.frame.size.height = textH
        b.labelText.contentsScale = max(2, 2 * mag)
    }
}
