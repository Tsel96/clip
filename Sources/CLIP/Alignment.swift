import Foundation
import CoreGraphics

/// A single alignment line drawn in world coordinates while dragging.
struct AlignmentGuide: Identifiable, Equatable {
    let id = UUID()

    enum Axis { case vertical, horizontal }
    let axis: Axis
    /// World x for vertical guides, world y for horizontal guides.
    let position: CGFloat
    /// World extent of the guide along the other axis (start, end).
    let extent: ClosedRange<CGFloat>
}

/// A measured gap drawn (pink, Stitch / Figma style) while dragging — the
/// segment runs the length of one gap in world coordinates, captioned
/// with its pixel distance.
struct SpacingIndicator: Identifiable, Equatable {
    let id = UUID()

    enum Axis { case horizontal, vertical }
    let axis: Axis
    /// The gap segment endpoints, in world coordinates.
    let from: CGPoint
    let to: CGPoint
    /// Measured gap length in world points.
    let distance: CGFloat
}

/// Computes a snapped frame + the guides that should be drawn for a node
/// being dragged. Pure function: no SwiftUI dependencies.
enum AlignmentEngine {

    /// Grid step in world units (Figma-style).
    static let gridStep: CGFloat = 8
    /// Distance in WORLD units within which an edge snaps. (Caller passes
    /// `4 / zoom` to keep the snap aggressiveness constant in screen pixels.)
    static let snapThresholdScreen: CGFloat = 4

    /// - Parameters:
    ///   - draggingRect: prospective world frame of the moving node.
    ///   - otherRects: rectangles of all OTHER nodes on the page.
    ///   - zoom: current camera zoom (so we can convert the screen-space
    ///           snap threshold into world units).
    ///   - snapToGrid: whether to also snap each axis to 8pt grid.
    /// - Returns: snapped frame + alignment guides for live rendering.
    static func snap(
        draggingRect rect: CGRect,
        otherRects: [CGRect],
        zoom: CGFloat,
        snapToGrid: Bool
    ) -> (rect: CGRect, guides: [AlignmentGuide]) {

        let worldThreshold = snapThresholdScreen / max(zoom, 0.01)
        var out = rect
        var guides: [AlignmentGuide] = []

        // Edge x values on the dragging rect.
        let myLefts:   [CGFloat] = [rect.minX, rect.midX, rect.maxX]
        let myTops:    [CGFloat] = [rect.minY, rect.midY, rect.maxY]

        // Find the best vertical snap (x-axis alignment).
        var bestDX: CGFloat = .infinity
        var bestSnapX: CGFloat? = nil
        var verticalGuideX: CGFloat? = nil
        var verticalGuideYRange: ClosedRange<CGFloat>? = nil

        for other in otherRects {
            let theirXs: [CGFloat] = [other.minX, other.midX, other.maxX]
            for (i, my) in myLefts.enumerated() {
                for their in theirXs {
                    let delta = their - my
                    if abs(delta) < worldThreshold && abs(delta) < abs(bestDX) {
                        bestDX = delta
                        // The corresponding rect.origin.x shift:
                        // index 0 = left edge, 1 = midX, 2 = right edge.
                        // Shifting by `delta` makes them line up.
                        bestSnapX = rect.origin.x + delta
                        if i == 1 { bestSnapX = (rect.midX + delta) - rect.width / 2 }
                        if i == 2 { bestSnapX = rect.origin.x + delta }
                        // For midX/right edges the shift is the same since
                        // we move the whole rect, so just set origin.x.
                        verticalGuideX = their
                        verticalGuideYRange = min(rect.minY, other.minY)...max(rect.maxY, other.maxY)
                    }
                }
            }
        }
        if let snapX = bestSnapX {
            out.origin.x = snapX
        }
        if let x = verticalGuideX, let range = verticalGuideYRange {
            guides.append(AlignmentGuide(axis: .vertical, position: x, extent: range))
        }

        // Same for horizontal snaps (y-axis alignment).
        var bestDY: CGFloat = .infinity
        var bestSnapY: CGFloat? = nil
        var horizontalGuideY: CGFloat? = nil
        var horizontalGuideXRange: ClosedRange<CGFloat>? = nil

        for other in otherRects {
            let theirYs: [CGFloat] = [other.minY, other.midY, other.maxY]
            for my in myTops {
                for their in theirYs {
                    let delta = their - my
                    if abs(delta) < worldThreshold && abs(delta) < abs(bestDY) {
                        bestDY = delta
                        bestSnapY = out.origin.y + delta
                        horizontalGuideY = their
                        horizontalGuideXRange = min(rect.minX, other.minX)...max(rect.maxX, other.maxX)
                    }
                }
            }
        }
        if let snapY = bestSnapY {
            out.origin.y = snapY
        }
        if let y = horizontalGuideY, let range = horizontalGuideXRange {
            guides.append(AlignmentGuide(axis: .horizontal, position: y, extent: range))
        }

        // Grid snap as a fallback (after alignment so alignment wins on close).
        if snapToGrid {
            if bestSnapX == nil {
                out.origin.x = (out.origin.x / Self.gridStep).rounded() * Self.gridStep
            }
            if bestSnapY == nil {
                out.origin.y = (out.origin.y / Self.gridStep).rounded() * Self.gridStep
            }
        }

        return (out, guides)
    }

    /// Screen-space tolerance for "these two gaps count as equal."
    static let equalSpacingToleranceScreen: CGFloat = 8

    /// Equal-spacing pass. If the dragged rect sits between a left/right
    /// (or top/bottom) neighbour with near-equal gaps, nudge it so the
    /// gaps are *exactly* equal and return the pink measurement segments.
    /// Only adjusts an axis the caller still allows (so it never fights
    /// the edge-alignment pass over the same coordinate).
    static func equalSpacing(
        draggingRect rect: CGRect,
        otherRects: [CGRect],
        zoom: CGFloat,
        allowX: Bool,
        allowY: Bool
    ) -> (rect: CGRect, indicators: [SpacingIndicator]) {

        let z = max(zoom, 0.01)
        let reach = snapThresholdScreen / z          // overlap slack
        let tolerance = equalSpacingToleranceScreen / z
        var out = rect

        // Horizontal — equalise the gap to the nearest left & right
        // neighbour that overlaps the dragged rect vertically.
        var xGap: (left: CGFloat, right: CGFloat, gap: CGFloat)? = nil
        if allowX {
            let yOverlap: (CGRect) -> Bool = { $0.minY < rect.maxY && $0.maxY > rect.minY }
            let leftN = otherRects
                .filter { yOverlap($0) && $0.maxX <= rect.minX + reach }
                .max { $0.maxX < $1.maxX }
            let rightN = otherRects
                .filter { yOverlap($0) && $0.minX >= rect.maxX - reach }
                .min { $0.minX < $1.minX }
            if let l = leftN, let r = rightN {
                let gap = (r.minX - l.maxX - rect.width) / 2
                let leftGap = rect.minX - l.maxX
                let rightGap = r.minX - rect.maxX
                if gap > 0, abs(leftGap - rightGap) <= tolerance {
                    out.origin.x = l.maxX + gap
                    xGap = (l.maxX, r.minX, gap)
                }
            }
        }

        // Vertical — same, with the axes swapped.
        var yGap: (top: CGFloat, bottom: CGFloat, gap: CGFloat)? = nil
        if allowY {
            let xOverlap: (CGRect) -> Bool = { $0.minX < rect.maxX && $0.maxX > rect.minX }
            let topN = otherRects
                .filter { xOverlap($0) && $0.maxY <= rect.minY + reach }
                .max { $0.maxY < $1.maxY }
            let botN = otherRects
                .filter { xOverlap($0) && $0.minY >= rect.maxY - reach }
                .min { $0.minY < $1.minY }
            if let t = topN, let b = botN {
                let gap = (b.minY - t.maxY - rect.height) / 2
                let topGap = rect.minY - t.maxY
                let botGap = b.minY - rect.maxY
                if gap > 0, abs(topGap - botGap) <= tolerance {
                    out.origin.y = t.maxY + gap
                    yGap = (t.maxY, b.minY, gap)
                }
            }
        }

        // Build the measurement segments from the *final* rect.
        var indicators: [SpacingIndicator] = []
        if let xg = xGap {
            let y = out.midY
            indicators.append(SpacingIndicator(
                axis: .horizontal,
                from: CGPoint(x: xg.left, y: y),
                to:   CGPoint(x: out.minX, y: y),
                distance: xg.gap))
            indicators.append(SpacingIndicator(
                axis: .horizontal,
                from: CGPoint(x: out.maxX, y: y),
                to:   CGPoint(x: xg.right, y: y),
                distance: xg.gap))
        }
        if let yg = yGap {
            let x = out.midX
            indicators.append(SpacingIndicator(
                axis: .vertical,
                from: CGPoint(x: x, y: yg.top),
                to:   CGPoint(x: x, y: out.minY),
                distance: yg.gap))
            indicators.append(SpacingIndicator(
                axis: .vertical,
                from: CGPoint(x: x, y: out.maxY),
                to:   CGPoint(x: x, y: yg.bottom),
                distance: yg.gap))
        }

        return (out, indicators)
    }
}
