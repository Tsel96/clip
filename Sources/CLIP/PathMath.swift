import SwiftUI
import CoreGraphics

/// Stroke processing utilities ported from the React prototype's
/// DrawingLayer.tsx — Ramer-Douglas-Peucker simplification and a
/// quadratic-bezier smoother that matches the original feel.
enum PathMath {

    /// Reduce point count while keeping the visual shape within `epsilon`.
    static func simplify(_ points: [CGPoint], epsilon: CGFloat = 1.5) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let first = points.first!
        let last = points.last!

        var maxDist: CGFloat = 0
        var maxIdx: Int = 0
        for i in 1..<(points.count - 1) {
            let d = perpendicularDistance(of: points[i], from: first, to: last)
            if d > maxDist { maxDist = d; maxIdx = i }
        }

        if maxDist > epsilon {
            let left  = simplify(Array(points[0...maxIdx]), epsilon: epsilon)
            let right = simplify(Array(points[maxIdx...]),  epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [first, last]
    }

    /// Build a smoothed quadratic-bezier `Path` through the given points.
    static func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 { return path }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 1..<(points.count - 1) {
            let curr = points[i]
            let next = points[i + 1]
            let mid = CGPoint(x: (curr.x + next.x) / 2, y: (curr.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: curr)
        }
        path.addLine(to: points.last!)
        return path
    }

    /// Tight bounding rectangle of a list of points, padded by `pad`.
    static func paddedBounds(of points: [CGPoint], pad: CGFloat) -> CGRect {
        guard !points.isEmpty else { return .zero }
        var minX = points[0].x, minY = points[0].y
        var maxX = minX, maxY = minY
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(
            x: minX - pad, y: minY - pad,
            width: maxX - minX + pad * 2,
            height: maxY - minY + pad * 2
        )
    }

    private static func perpendicularDistance(of p: CGPoint,
                                               from a: CGPoint,
                                               to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        if len == 0 {
            return ((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)).squareRoot()
        }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len
    }
}
