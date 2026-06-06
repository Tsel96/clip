import SwiftUI

/// Colorform's background visualisation. Each cluster gets its own
/// organic-shaped **Voronoi cell** rather than an overlapping radial blob,
/// so colors tile the canvas without one dominant "Slate background"
/// bleeding through. A heavy blur softens the cell boundaries so adjacent
/// cells appear to merge at their edges while their centres stay pure.
struct ColorformLayer: View {
    @EnvironmentObject var state: CanvasState
    @EnvironmentObject var cameraStore: CameraStore

    var body: some View {
        GeometryReader { geo in
            let cam = cameraStore.camera
            // Voronoi bounds = the seeds' own bounding rect plus a fixed
            // outer "halo" so cells extend a bit past the outermost seeds
            // but DON'T span the whole canvas. That way the cell constellation
            // is a finite blob with cream space around it (matches the
            // reference) rather than colours running to the viewport edges.
            let worldBounds = seedBoundingBox(padding: 420)
            let seeds = state.colorBulbs.map { Voronoi.Seed(id: $0.id, point: $0.center) }
            let cells = Voronoi.compute(seeds: seeds, bounds: worldBounds)
            let bulbsByID = Dictionary(uniqueKeysWithValues: state.colorBulbs.map { ($0.id, $0) })
            // World-space centre + extent of the seed constellation, used
            // for the organic outer mask below.
            let maskCentreWorld = CGPoint(
                x: worldBounds.midX,
                y: worldBounds.midY
            )
            let maskRadiusWorld = max(worldBounds.width, worldBounds.height) * 0.55
            let maskCentreScreen = CGPoint(
                x: maskCentreWorld.x * cam.zoom + cam.x,
                y: maskCentreWorld.y * cam.zoom + cam.y
            )
            let maskRadiusScreen = maskRadiusWorld * cam.zoom

            ZStack(alignment: .topLeading) {
                // Layer 1: solid-colored Voronoi cells, blurred → soft
                // cloudy regions with fuzzy boundaries between adjacent
                // colors. Masked by an organic blob so the constellation
                // doesn't end in a rectangular outline.
                ZStack(alignment: .topLeading) {
                    ForEach(cells) { cell in
                        if let bulb = bulbsByID[cell.id] {
                            CellShape(polygon: cell.polygon, camera: cam)
                                .fill(bulb.color.swiftUIColor)
                        }
                    }
                }
                .blur(radius: 64)
                .mask(
                    BlobMask(centre: maskCentreScreen, radius: maskRadiusScreen)
                )

                // Layer 2: subtle "glow" at each seed point. Masked
                // by the same blob so the seed glows don't poke out
                // past the colorform's organic outline.
                ZStack(alignment: .topLeading) {
                    ForEach(cells) { cell in
                        if let bulb = bulbsByID[cell.id] {
                            Circle()
                                .fill(
                                    RadialGradient(
                                        gradient: Gradient(stops: [
                                            .init(color: .white.opacity(0.35), location: 0.0),
                                            .init(color: .white.opacity(0.0),  location: 0.8),
                                        ]),
                                        center: .center,
                                        startRadius: 0,
                                        endRadius: 240
                                    )
                                )
                                .frame(width: 480, height: 480)
                                .position(
                                    x: bulb.center.x * cam.zoom + cam.x,
                                    y: bulb.center.y * cam.zoom + cam.y
                                )
                                .blendMode(.softLight)
                        }
                    }
                }
                .blur(radius: 36)
                .mask(
                    BlobMask(centre: maskCentreScreen, radius: maskRadiusScreen)
                )

                // Layer 3: labels, on top, never blurred. Positioned in
                // SCREEN coordinates so they always render at a constant
                // 22pt on-screen — no extra zoom counter-scale needed.
                ForEach(state.colorBulbs) { bulb in
                    Text(bulb.label)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.30), radius: 4, y: 1)
                        .shadow(color: bulb.color.swiftUIColor.opacity(0.6), radius: 8)
                        .position(
                            x: bulb.center.x * cam.zoom + cam.x,
                            y: bulb.center.y * cam.zoom + cam.y
                        )
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Tight rectangle around every cluster's seed point, expanded by
    /// `padding` on each side. Used as the Voronoi clip region so cells
    /// have a finite extent and the cream canvas shows around them.
    private func seedBoundingBox(padding: CGFloat) -> CGRect {
        guard !state.colorBulbs.isEmpty else {
            return CGRect(x: -500, y: -500, width: 1000, height: 1000)
        }
        var minX =  CGFloat.infinity, minY =  CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for b in state.colorBulbs {
            minX = min(minX, b.center.x); minY = min(minY, b.center.y)
            maxX = max(maxX, b.center.x); maxY = max(maxY, b.center.y)
        }
        return CGRect(
            x: minX - padding,
            y: minY - padding,
            width:  (maxX - minX) + padding * 2,
            height: (maxY - minY) + padding * 2
        )
    }
}

// MARK: - Blob mask

/// Soft, wobbly closed shape used as a mask over the cell layer so the
/// colorform constellation ends in an organic outline rather than the
/// rectangular outer edge of the seed bounding box. The wobble is
/// deterministic per session so the mask doesn't dance during zoom/pan.
private struct BlobMask: View {
    let centre: CGPoint
    let radius: CGFloat

    var body: some View {
        BlobShape(centre: centre, radius: radius)
            .fill(Color.white)
            .blur(radius: 40)
    }
}

private struct BlobShape: Shape {
    let centre: CGPoint
    let radius: CGFloat
    /// Per-vertex radial variation in (-1, 1). Static = stable across
    /// re-renders. 16 control points gives a nice round-but-wobbly outline.
    private static let wobble: [CGFloat] = [
         0.12, -0.06,  0.18, -0.14,  0.04,  0.22, -0.08,  0.10,
        -0.18,  0.14, -0.04,  0.20, -0.12,  0.08,  0.16, -0.10,
    ]

    func path(in rect: CGRect) -> Path {
        Path { p in
            let n = Self.wobble.count
            var pts: [CGPoint] = []
            for i in 0..<n {
                let theta = Double(i) / Double(n) * 2 * .pi
                let r = radius * (1.0 + Self.wobble[i] * 0.20)
                pts.append(CGPoint(
                    x: centre.x + r * CGFloat(cos(theta)),
                    y: centre.y + r * CGFloat(sin(theta))
                ))
            }
            // Connect with quadratic curves through the midpoints for
            // smooth, blob-like edges (no polygonal kinks).
            p.move(to: midpoint(pts[n - 1], pts[0]))
            for i in 0..<n {
                let next = midpoint(pts[i], pts[(i + 1) % n])
                p.addQuadCurve(to: next, control: pts[i])
            }
            p.closeSubpath()
        }
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
    }
}

// MARK: - Cell Shape

/// A SwiftUI `Shape` that draws a Voronoi cell's polygon in world coords
/// projected through the active camera.
private struct CellShape: Shape {
    let polygon: [CGPoint]
    let camera: Camera

    func path(in rect: CGRect) -> Path {
        Path { p in
            guard let first = polygon.first else { return }
            p.move(to: project(first))
            for pt in polygon.dropFirst() { p.addLine(to: project(pt)) }
            p.closeSubpath()
        }
    }

    private func project(_ world: CGPoint) -> CGPoint {
        CGPoint(
            x: world.x * camera.zoom + camera.x,
            y: world.y * camera.zoom + camera.y
        )
    }
}
