import CoreGraphics
import Foundation

/// Obsidian-Canvas-style connector geometry: a single cubic bezier between two
/// node rects, exiting/entering the *center of a side face*, with a short 7-px
/// standoff stub and side-normal control arms. Ported from Obsidian's edge math
/// (see the `obsidian-canvas-connectors` memory). All inputs/outputs are in the
/// canvas content-coordinate space (the flipped collection-view document space),
/// so widths/standoff scale naturally with magnification.
enum ConnSide: Int, CaseIterable {
    case top, right, bottom, left
}

/// One resolved connector route.
struct BezierRoute {
    let path: CGPath          // so → to cubic bezier (the visible stroke)
    let arrowTip: CGPoint     // target side-center (where the arrowhead points)
    let arrowFrom: CGPoint    // target standoff (arrow heading = from → tip)
    let midpoint: CGPoint     // bezier t=0.5 (label anchor)
    let sourceSide: ConnSide
    let targetSide: ConnSide
}

enum ConnectorPathMath {

    static let standoffDistance: CGFloat = 7
    static let armMin: CGFloat = 40
    /// Curvature: control arms = half the standoff distance (classic node-editor
    /// S-curve), so the bend scales with distance and reads as a smooth Obsidian
    /// curve at any zoom — NOT a tight 150-cap that goes straight when far apart.
    static let armFactor: CGFloat = 0.5

    static func sideCenter(of r: CGRect, _ side: ConnSide) -> CGPoint {
        switch side {
        case .top:    return CGPoint(x: r.midX, y: r.minY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .left:   return CGPoint(x: r.minX, y: r.midY)
        case .right:  return CGPoint(x: r.maxX, y: r.midY)
        }
    }

    /// Step `d` px outward from a side center along the side normal.
    static func standoff(_ c: CGPoint, _ side: ConnSide, _ d: CGFloat = standoffDistance) -> CGPoint {
        switch side {
        case .top:    return CGPoint(x: c.x, y: c.y - d)
        case .bottom: return CGPoint(x: c.x, y: c.y + d)
        case .left:   return CGPoint(x: c.x - d, y: c.y)
        case .right:  return CGPoint(x: c.x + d, y: c.y)
        }
    }

    /// Bezier control point: project from a standoff along the side normal by `arm`.
    static func control(_ s: CGPoint, _ side: ConnSide, _ arm: CGFloat) -> CGPoint {
        switch side {
        case .top:    return CGPoint(x: s.x, y: s.y - arm)
        case .bottom: return CGPoint(x: s.x, y: s.y + arm)
        case .left:   return CGPoint(x: s.x - arm, y: s.y)
        case .right:  return CGPoint(x: s.x + arm, y: s.y)
        }
    }

    /// Auto-pick the side of `rect` that faces `toward` (Obsidian V5: angle vs the
    /// rect's own aspect half-angle). Y increases downward (flipped content space).
    static func bestSide(of rect: CGRect, toward other: CGRect) -> ConnSide {
        let dx = other.midX - rect.midX
        let dy = other.midY - rect.midY
        let angle = atan2(dy, dx)                               // right=0, down=+π/2
        let hw = atan2(rect.height / 2, max(rect.width / 2, 0.001))
        if angle > -hw && angle <= hw            { return .right }
        if angle > hw  && angle <= .pi - hw      { return .bottom }
        if angle > .pi - hw || angle <= -(.pi - hw) { return .left }
        return .top
    }

    /// Build the bezier between two rects. Sides auto-derived unless supplied.
    static func route(source: CGRect, target: CGRect,
                      sourceSide: ConnSide? = nil, targetSide: ConnSide? = nil) -> BezierRoute {
        let ss = sourceSide ?? bestSide(of: source, toward: target)
        let ts = targetSide ?? bestSide(of: target, toward: source)
        let s  = sideCenter(of: source, ss)
        let t  = sideCenter(of: target, ts)
        let so = standoff(s, ss)
        let to = standoff(t, ts)
        let dist = hypot(to.x - so.x, to.y - so.y)
        let arm = max(armMin, dist * armFactor)
        let cp1 = control(so, ss, arm)
        let cp2 = control(to, ts, arm)

        let path = CGMutablePath()
        path.move(to: so)
        path.addCurve(to: to, control1: cp1, control2: cp2)

        // Cubic bezier midpoint at t=0.5: ⅛·so + ⅜·cp1 + ⅜·cp2 + ⅛·to
        let mid = CGPoint(
            x: 0.125 * so.x + 0.375 * cp1.x + 0.375 * cp2.x + 0.125 * to.x,
            y: 0.125 * so.y + 0.375 * cp1.y + 0.375 * cp2.y + 0.125 * to.y
        )
        // Arrowhead sits at the target side-center, pointing in from the standoff.
        return BezierRoute(path: path, arrowTip: t, arrowFrom: to, midpoint: mid,
                           sourceSide: ss, targetSide: ts)
    }
}
