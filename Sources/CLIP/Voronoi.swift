import Foundation
import CoreGraphics

/// A Voronoi cell — the convex polygon of all points closer to `seed`
/// than to any other seed in the input set.
struct VoronoiCell: Identifiable {
    let id: Int
    let seed: CGPoint
    let polygon: [CGPoint]
}

/// Naïve O(n²·v) Voronoi: for each seed, clip an initial bounding-box
/// polygon against the perpendicular bisector of every other seed using
/// Sutherland–Hodgman. Plenty fast for 9–20 clusters.
enum Voronoi {

    struct Seed { let id: Int; let point: CGPoint }

    static func compute(seeds: [Seed], bounds: CGRect) -> [VoronoiCell] {
        guard !seeds.isEmpty else { return [] }
        return seeds.map { seed in
            var poly: [CGPoint] = [
                CGPoint(x: bounds.minX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.maxY),
                CGPoint(x: bounds.minX, y: bounds.maxY)
            ]
            for other in seeds where other.id != seed.id {
                let h = perpBisector(seed.point, other.point)
                poly = clip(poly, against: h)
                if poly.isEmpty { break }
            }
            return VoronoiCell(id: seed.id, seed: seed.point, polygon: poly)
        }
    }

    // MARK: - Half-plane primitives

    /// `normal · p ≥ offset` is the "inside" of the half-plane. The bisector
    /// of (a, b) keeps the side containing `a`: normal points from b toward a.
    private struct HalfPlane { let nx: CGFloat; let ny: CGFloat; let offset: CGFloat }

    private static func perpBisector(_ a: CGPoint, _ b: CGPoint) -> HalfPlane {
        let mx = (a.x + b.x) * 0.5
        let my = (a.y + b.y) * 0.5
        var nx = a.x - b.x
        var ny = a.y - b.y
        let len = hypot(nx, ny)
        if len > 0 { nx /= len; ny /= len }
        return HalfPlane(nx: nx, ny: ny, offset: nx * mx + ny * my)
    }

    private static func signed(_ p: CGPoint, _ h: HalfPlane) -> CGFloat {
        h.nx * p.x + h.ny * p.y - h.offset
    }

    private static func intersect(_ a: CGPoint, _ b: CGPoint, _ h: HalfPlane) -> CGPoint {
        let da = signed(a, h)
        let db = signed(b, h)
        let denom = da - db
        let t = denom == 0 ? 0 : da / denom
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Sutherland-Hodgman: keeps the portion of `poly` for which
    /// `signed(p, h) ≥ 0`.
    private static func clip(_ poly: [CGPoint], against h: HalfPlane) -> [CGPoint] {
        guard !poly.isEmpty else { return [] }
        var output: [CGPoint] = []
        let n = poly.count
        for i in 0..<n {
            let curr = poly[i]
            let prev = poly[(i - 1 + n) % n]
            let currIn = signed(curr, h) >= 0
            let prevIn = signed(prev, h) >= 0
            if currIn {
                if !prevIn { output.append(intersect(prev, curr, h)) }
                output.append(curr)
            } else if prevIn {
                output.append(intersect(prev, curr, h))
            }
        }
        return output
    }
}
