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
        // Alignment / spacing guide LINES removed per user request — render
        // nothing. (Only the red/pink guide visuals are suppressed here; any
        // snapping math lives in CanvasInputView and is unaffected.)
        _ = (guides, spacing, worldMin, magnification)
        guard !layers.isEmpty || !spacingLayers.isEmpty else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in layers { l.isHidden = true; l.path = nil }
        for l in spacingLayers { l.isHidden = true; l.path = nil }
        CATransaction.commit()
    }
}
