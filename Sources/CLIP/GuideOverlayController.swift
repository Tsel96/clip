import AppKit

/// Phase B native alignment guides. Renders the snap guides (from
/// `AlignmentEngine`) as red `CAShapeLayer`s directly in the scrolled
/// `FlippedContainer` (content space → the scroll's magnification scales them;
/// line width ÷ magnification keeps them a constant on-screen width). Fed
/// DIRECTLY by `CanvasInputView` during a move — no `@Published` write, so it
/// never re-renders the cards mid-drag (the reason the SwiftUI guide overlay was
/// never wired into the native drag).
final class GuideOverlayController {

    private let root = CALayer()
    private var layers: [CAShapeLayer] = []        // red alignment guides
    private var spacingLayers: [CAShapeLayer] = [] // pink equal-gap indicators

    func attach(to container: NSView) {
        container.wantsLayer = true
        root.zPosition = 60   // above connectors + cards
        container.layer?.addSublayer(root)
    }

    /// `guides` carry WORLD coords; `worldMin` is `worldBounds.origin` (content
    /// space = world − worldMin). Pass `[]` to clear (drag end / ⌘ held).
    func update(_ guides: [AlignmentGuide],
                spacing: [SpacingIndicator] = [],
                worldMin: CGPoint, magnification: CGFloat) {
        let mag = max(magnification, 0.0001)
        let lineWidth = 1.0 / mag

        while layers.count < guides.count {
            let l = CAShapeLayer()
            l.strokeColor = NSColor.systemRed.cgColor
            l.fillColor = nil
            root.addSublayer(l)
            layers.append(l)
        }
        while spacingLayers.count < spacing.count {
            let l = CAShapeLayer()
            l.strokeColor = NSColor.systemPink.cgColor
            l.fillColor = nil
            root.addSublayer(l)
            spacingLayers.append(l)
        }

        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, layer) in layers.enumerated() {
            guard i < guides.count else { layer.isHidden = true; layer.path = nil; continue }
            let g = guides[i]
            let path = CGMutablePath()
            switch g.axis {
            case .vertical:
                let x = g.position - worldMin.x
                path.move(to: CGPoint(x: x, y: g.extent.lowerBound - worldMin.y))
                path.addLine(to: CGPoint(x: x, y: g.extent.upperBound - worldMin.y))
            case .horizontal:
                let y = g.position - worldMin.y
                path.move(to: CGPoint(x: g.extent.lowerBound - worldMin.x, y: y))
                path.addLine(to: CGPoint(x: g.extent.upperBound - worldMin.x, y: y))
            }
            layer.path = path
            layer.lineWidth = lineWidth
            layer.isHidden = false
        }
        for (i, layer) in spacingLayers.enumerated() {
            guard i < spacing.count else { layer.isHidden = true; layer.path = nil; continue }
            let s = spacing[i]
            let path = CGMutablePath()
            path.move(to: CGPoint(x: s.from.x - worldMin.x, y: s.from.y - worldMin.y))
            path.addLine(to: CGPoint(x: s.to.x - worldMin.x, y: s.to.y - worldMin.y))
            layer.path = path
            layer.lineWidth = lineWidth
            layer.isHidden = false
        }
        CATransaction.commit()
    }
}
