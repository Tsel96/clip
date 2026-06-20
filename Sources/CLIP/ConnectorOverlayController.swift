import AppKit
import SwiftUI   // ElbowRoute returns a SwiftUI Path (→ .cgPath)

/// Phase B — native connectors. Renders `state.connectors` as `CAShapeLayer`s
/// directly in the scrolled `FlippedContainer`, so the scroll view's
/// magnification pans/zooms them for free (no camera-sync code). Stroke +
/// arrowhead widths are divided by `magnification` to stay a constant on-screen
/// size. Reuses the existing `ElbowRoute` routing math via `Path.cgPath`.
///
/// Flag-gated off by default (`CanvasView.useNativeConnectors`); when off, the
/// SwiftUI `ConnectorsLayer` (config.overlay) renders connectors as before.
/// This type owns ONLY drawing — hit-testing / drag-to-connect stay where they
/// are until verified.
final class ConnectorOverlayController {

    private let root = CALayer()
    private struct Pair { let line: CAShapeLayer; let arrow: CAShapeLayer }
    private var pairs: [UUID: Pair] = [:]

    /// Base on-screen sizes (divided by magnification each refresh).
    private static let screenLineWidth: CGFloat = 2
    private static let arrowLen: CGFloat = 11
    private static let arrowHalf: CGFloat = 6

    func attach(to container: NSView) {
        container.wantsLayer = true
        root.zPosition = 50   // above cards, below the selection chrome
        container.layer?.addSublayer(root)
    }

    func removeFromSuperlayer() { root.removeFromSuperlayer() }

    /// `nodeFrames`: content-space frames keyed by node id (the same space the
    /// collection items live in). `selected`: the selected connector id, if any.
    func update(connectors: [Connector],
                nodeFrames: [UUID: CGRect],
                selected: UUID?,
                magnification: CGFloat) {
        let mag = max(magnification, 0.0001)
        let lineWidth = Self.screenLineWidth / mag

        var seen = Set<UUID>()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for c in connectors {
            guard let s = nodeFrames[c.sourceID],
                  let t = nodeFrames[c.targetID]
            else { continue }
            let route = ElbowRoute.build(source: s, target: t, cornerRadius: 14)
            seen.insert(c.id)

            let pair = pairs[c.id] ?? makePair(for: c.id)
            let color = (c.id == selected
                         ? NSColor.controlAccentColor
                         : NSColor.secondaryLabelColor).cgColor

            pair.line.path = route.path.cgPath
            pair.line.lineWidth = lineWidth
            pair.line.strokeColor = color

            pair.arrow.path = arrowPath(tip: route.arrowTip, from: route.arrowFrom, mag: mag)
            pair.arrow.fillColor = color
        }
        // Drop layers for connectors that no longer exist.
        for (id, p) in pairs where !seen.contains(id) {
            p.line.removeFromSuperlayer()
            p.arrow.removeFromSuperlayer()
            pairs[id] = nil
        }
        CATransaction.commit()
    }

    /// The connector whose line passes within `tolerance` (content units) of
    /// `point` — used by CanvasInputView to select/delete a connector. nil = none.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> UUID? {
        for (id, pair) in pairs {
            guard let path = pair.line.path else { continue }
            let outline = path.copy(strokingWithWidth: max(tolerance, 1),
                                    lineCap: .round, lineJoin: .round, miterLimit: 1)
            if outline.contains(point) { return id }
        }
        return nil
    }

    private func makePair(for id: UUID) -> Pair {
        let line = CAShapeLayer()
        line.fillColor = nil
        line.lineCap = .round
        line.lineJoin = .round
        let arrow = CAShapeLayer()
        arrow.strokeColor = nil
        root.addSublayer(line)
        root.addSublayer(arrow)
        let pair = Pair(line: line, arrow: arrow)
        pairs[id] = pair
        return pair
    }

    /// Filled triangle at `tip`, pointing along (tip − from). Sized in content
    /// units scaled by 1/mag so it stays a constant on-screen size.
    private func arrowPath(tip: CGPoint, from: CGPoint, mag: CGFloat) -> CGPath {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let len = max(hypot(dx, dy), 0.0001)
        let ux = dx / len, uy = dy / len
        let size = Self.arrowLen / mag
        let half = Self.arrowHalf / mag
        let baseX = tip.x - ux * size, baseY = tip.y - uy * size
        let px = -uy, py = ux   // perpendicular
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: baseX + px * half, y: baseY + py * half))
        path.addLine(to: CGPoint(x: baseX - px * half, y: baseY - py * half))
        path.closeSubpath()
        return path
    }
}
