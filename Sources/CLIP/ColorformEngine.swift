import Foundation
import CoreGraphics

// MARK: - Public types

/// One color group on the canvas. Members share a dominant color.
struct ColorCluster: Identifiable, Hashable {
    let id: Int
    let center: RGB          // centroid in RGB (display color of the bulb)
    let label: String        // nearest named anchor, e.g. "Indigo"
    let memberIDs: [UUID]
}

/// One rendered "bulb" — a soft radial gradient + label that lives in
/// canvas-world coordinates. Painted by `ColorformLayer`.
struct ColorBulb: Identifiable, Hashable {
    let id: Int             // matches the cluster id
    let center: CGPoint     // world-space (un-transformed) centre
    let radius: CGFloat     // world-space outer radius (where the gradient fades to 0)
    let color: RGB
    let label: String
}

// MARK: - Engine

/// Pure, deterministic clustering + layout for Colorform mode.
/// Nothing in here touches `CanvasState` — the engine takes inputs, returns
/// outputs, and `CanvasState.recomputeColorform()` does the binding.
enum ColorformEngine {

    // MARK: Clustering

    /// Anchor-based bucketing: each color is assigned to its nearest named
    /// anchor (Crimson, Coral, Amber, … Onyx, Slate, Ivory) using a
    /// weighted-HSV distance with hue counted 3×. Anchors with at least
    /// one member become clusters. Returned biggest-first so the layout
    /// can pack the dominant color at the canvas origin.
    ///
    /// Replaces an earlier k-means implementation that, on libraries
    /// skewed toward grayscale content (the typical case), tended to
    /// collapse every cluster into "Slate" because the initial seeds
    /// landed on grays and the few vivid outliers got absorbed. Anchors
    /// guarantee diverse labels and stable layout across re-entries.
    static func cluster(_ colors: [UUID: RGB]) -> [ColorCluster] {
        let entries = colors.sorted { $0.key.uuidString < $1.key.uuidString }
        guard !entries.isEmpty else { return [] }

        // Bucket every (id, rgb) by its nearest anchor name.
        var buckets: [String: [(id: UUID, rgb: RGB)]] = [:]
        for (id, rgb) in entries {
            let name = NamedColors.label(for: HSV(rgb: rgb))
            buckets[name, default: []].append((id, rgb))
        }

        // Display color = the **most saturated member's RGB**. This makes
        // a cluster of pure-red cards render as pure red (not muted
        // "Crimson"), a cluster of pure greens render as pure green, etc.
        // Falls through to the anchor's idealised color only when every
        // member is gray (so neutral buckets still get a sensible swatch).
        var clusters: [ColorCluster] = []
        var nextID = 0
        for (label, members) in buckets {
            let mostVivid = members.max { a, b in
                HSV(rgb: a.rgb).s < HSV(rgb: b.rgb).s
            }
            let baseColor = mostVivid?.rgb ?? RGB(r: 0.5, g: 0.5, b: 0.5)
            // If even the most-saturated member is essentially gray, take
            // the anchor color so the bulb still reads as something
            // (otherwise neutral clusters render as a near-invisible
            // soft cloud).
            let displayColor: RGB
            if HSV(rgb: baseColor).s < 0.20,
               let anchor = NamedColors.anchorRGB(name: label) {
                displayColor = anchor
            } else {
                displayColor = baseColor
            }
            clusters.append(ColorCluster(
                id: nextID,
                center: displayColor,
                label: label,
                memberIDs: members.map(\.id).sorted { $0.uuidString < $1.uuidString }
            ))
            nextID += 1
        }
        return clusters.sorted {
            if $0.memberIDs.count != $1.memberIDs.count {
                return $0.memberIDs.count > $1.memberIDs.count
            }
            return $0.label < $1.label
        }
    }

    // MARK: Layout

    /// Lay every clustered node on a phyllotaxis spiral inside its cluster,
    /// then place clusters on an outer phyllotaxis with **constant pitch**
    /// so the layout doesn't get dominated by the biggest cluster. Every
    /// bulb gets a uniform minimum visible radius so single-member buckets
    /// aren't dwarfed by a 5-member Slate.
    static func layout(
        clusters: [ColorCluster],
        nodeSizes: [UUID: CGSize]
    ) -> (positions: [UUID: CGPoint], bulbs: [ColorBulb]) {

        guard !clusters.isEmpty else { return ([:], []) }

        struct LaidCluster {
            let cluster: ColorCluster
            let localPositions: [UUID: CGPoint]
            let contentRadius: CGFloat   // tightest radius around the member cards
        }

        let goldenAngle = .pi * (3 - sqrt(5.0))    // ≈ 137.5°
        let uniformBulbRadius: CGFloat = 380
        // `gridPitch` is the centre-to-centre distance between cluster
        // seeds. Computed dynamically below so it's at least as large as
        // the biggest cluster's grid extent — guarantees no card from one
        // cluster lands inside another cluster's territory.

        // 1. Inner grid per cluster (guaranteed non-overlapping). Use the
        // smallest near-square grid that fits all members: cols = ceil(√n),
        // rows = ceil(n / cols). Cards inside a cluster sit on a grid
        // centred on the cluster's seed, with a fixed `gap` between them.
        var laid: [LaidCluster] = []
        let cardGap: CGFloat = 36
        for c in clusters {
            let sizes = c.memberIDs.compactMap { nodeSizes[$0] }
            let sum = sizes.reduce(CGSize.zero) {
                CGSize(width: $0.width + $1.width, height: $0.height + $1.height)
            }
            let avgW = sizes.isEmpty ? 320 : sum.width / CGFloat(sizes.count)
            let avgH = sizes.isEmpty ? 200 : sum.height / CGFloat(sizes.count)

            let m = c.memberIDs.count
            let cols = max(1, Int(ceil(sqrt(Double(m)))))
            let rows = max(1, Int(ceil(Double(m) / Double(cols))))

            // Pitch = card extent + gap. Same per row/col so the grid is
            // uniform regardless of mild per-card size differences.
            let pitchX = avgW + cardGap
            let pitchY = avgH + cardGap
            let gridW = CGFloat(cols) * pitchX - cardGap
            let gridH = CGFloat(rows) * pitchY - cardGap

            var positions: [UUID: CGPoint] = [:]
            for (i, id) in c.memberIDs.enumerated() {
                let col = i % cols
                let row = i / cols
                let sz = nodeSizes[id] ?? CGSize(width: avgW, height: avgH)
                // Top-left of the card such that its centre lands on the
                // grid cell's centre, and the whole grid is centred on (0,0).
                let cellCenterX = -gridW / 2 + (CGFloat(col) + 0.5) * pitchX
                let cellCenterY = -gridH / 2 + (CGFloat(row) + 0.5) * pitchY
                positions[id] = CGPoint(
                    x: cellCenterX - sz.width  / 2,
                    y: cellCenterY - sz.height / 2
                )
            }
            // Outer radius for the cluster = half-diagonal of the grid.
            let contentRadius = hypot(gridW, gridH) / 2
            laid.append(LaidCluster(cluster: c, localPositions: positions, contentRadius: contentRadius))
        }

        // 2. Cluster centres: **Poisson-disk** style random placement.
        // Each seed is at least `minDist` from every existing seed, but
        // otherwise chosen uniformly in a bounded disc. That produces the
        // organic, no-axis cell shapes the user wants while still
        // guaranteeing every cluster's inner grid has enough room.
        let n = laid.count
        let maxContentRadius = laid.map(\.contentRadius).max() ?? 200
        let minDist = max(720, maxContentRadius * 2 + 280)
        // Region radius scales with cluster count — gives the layout
        // room to spread without leaving huge empty halos.
        let regionRadius = CGFloat(sqrt(Double(n))) * minDist * 0.62

        var clusterCentres: [CGPoint] = []
        var attempts = 0
        let maxAttempts = 3000
        // Place the first seed at origin so the constellation feels
        // centred regardless of how the random sampler proceeds.
        if n > 0 { clusterCentres.append(.zero) }
        while clusterCentres.count < n, attempts < maxAttempts {
            attempts += 1
            // Deterministic pseudo-random angle + radius (uses two
            // independent jitter streams so points are well-spread).
            let theta = Double(pseudoJitter(seed: attempts * 7919) + 1) * .pi  // [0, 2π)
            let rNorm = (pseudoJitter(seed: attempts * 6113) + 1) / 2          // [0, 1)
            let r = sqrt(rNorm) * regionRadius                                 // uniform in disc
            let candidate = CGPoint(
                x: r * CGFloat(cos(theta)),
                y: r * CGFloat(sin(theta))
            )
            let tooClose = clusterCentres.contains { existing in
                hypot(existing.x - candidate.x, existing.y - candidate.y) < minDist
            }
            if !tooClose { clusterCentres.append(candidate) }
        }
        // Fallback: if rejection sampling didn't yield enough seeds
        // (very dense library), fill remaining slots on a backup hex
        // grid so the layout never silently drops a cluster.
        if clusterCentres.count < n {
            let cols = max(1, Int(ceil(sqrt(Double(n)))))
            let rowPitch = minDist * CGFloat(sqrt(3.0) / 2.0)
            var idx = 0
            while clusterCentres.count < n {
                let col = idx % cols
                let row = idx / cols
                let rowOffset = (row % 2 == 1) ? minDist / 2 : 0
                let candidate = CGPoint(
                    x: CGFloat(col) * minDist + rowOffset - minDist * CGFloat(cols) / 2,
                    y: CGFloat(row) * rowPitch - rowPitch * CGFloat(n / cols) / 2
                )
                let tooClose = clusterCentres.contains { existing in
                    hypot(existing.x - candidate.x, existing.y - candidate.y) < minDist
                }
                if !tooClose { clusterCentres.append(candidate) }
                idx += 1
                if idx > n * 4 { break }   // bail out, shouldn't happen
            }
        }

        // 3. Combine; bulb radius is max(content + 60, minBulbRadius) so
        // even a single-member cluster paints a confident, visible blob.
        var positions: [UUID: CGPoint] = [:]
        var bulbs: [ColorBulb] = []
        for (i, lc) in laid.enumerated() {
            let centre = clusterCentres[i]
            for (id, local) in lc.localPositions {
                positions[id] = CGPoint(x: centre.x + local.x, y: centre.y + local.y)
            }
            // Uniform visual size; the underlying card cluster can still
            // be larger or smaller (handled by the inner phyllotaxis).
            let radius = max(uniformBulbRadius, lc.contentRadius + 40)
            bulbs.append(ColorBulb(
                id: lc.cluster.id,
                center: centre,
                radius: radius,
                color: lc.cluster.center,
                label: lc.cluster.label
            ))
        }
        return (positions, bulbs)
    }
}

// MARK: - Deterministic jitter

/// Stateless hash → value in roughly (-1, 1). Used to perturb cluster
/// centres so the Voronoi tessellation produces irregular cell shapes
/// without depending on `Random`'s nondeterminism (we want stable layouts
/// across re-entries to Colorform).
private func pseudoJitter(seed: Int) -> CGFloat {
    var x = UInt32(truncatingIfNeeded: seed &+ 0x9E37_79B9)
    x ^= x << 13
    x ^= x >> 17
    x ^= x << 5
    let f = Double(x) / Double(UInt32.max)        // [0, 1)
    return CGFloat(f * 2 - 1)                     // [-1, 1)
}

// MARK: - HSV (internal)

private struct HSV: Hashable {
    var h: Double   // [0,1) — wraps
    var s: Double   // [0,1]
    var v: Double   // [0,1]

    init(h: Double, s: Double, v: Double) { self.h = h; self.s = s; self.v = v }
    init(rgb: RGB) { let t = rgb.hsv; self.h = t.h; self.s = t.s; self.v = t.v }

    /// Weighted distance in HSV space — hue counts 3× because that's what
    /// humans key on first when grouping colors. Hue distance is circular.
    static func weightedDistance(_ a: HSV, _ b: HSV) -> Double {
        let rawDh = abs(a.h - b.h)
        let dh = min(rawDh, 1 - rawDh)        // [0, 0.5]; circular
        let ds = abs(a.s - b.s)
        let dv = abs(a.v - b.v)
        return (dh * 2) * 3 + ds * 1 + dv * 1  // dh*2 normalises to [0,1]
    }

    var rgb: RGB { RGB.fromHue(h, saturation: s, value: v) }
}

// MARK: - Named anchors

private enum NamedColors {
    /// 17 anchors covering the color wheel + neutrals. Cluster label is
    /// whichever anchor has the smallest weighted-HSV distance to the
    /// cluster centroid.
    private static let anchors: [(name: String, hsv: HSV)] = [
        ("Crimson", HSV(h: 0.00,  s: 0.85, v: 0.70)),
        ("Coral",   HSV(h: 0.04,  s: 0.65, v: 0.95)),
        ("Amber",   HSV(h: 0.10,  s: 0.85, v: 0.95)),
        ("Lemon",   HSV(h: 0.15,  s: 0.80, v: 0.95)),
        ("Lime",    HSV(h: 0.22,  s: 0.80, v: 0.85)),
        ("Mint",    HSV(h: 0.40,  s: 0.55, v: 0.85)),
        ("Teal",    HSV(h: 0.48,  s: 0.65, v: 0.70)),
        ("Sky",     HSV(h: 0.55,  s: 0.55, v: 0.95)),
        ("Indigo",  HSV(h: 0.65,  s: 0.70, v: 0.70)),
        ("Violet",  HSV(h: 0.73,  s: 0.65, v: 0.75)),
        ("Magenta", HSV(h: 0.85,  s: 0.70, v: 0.85)),
        ("Pink",    HSV(h: 0.92,  s: 0.55, v: 0.95)),
        ("Mocha",   HSV(h: 0.07,  s: 0.40, v: 0.40)),
        ("Onyx",    HSV(h: 0.00,  s: 0.05, v: 0.12)),
        ("Slate",   HSV(h: 0.60,  s: 0.10, v: 0.50)),
        ("Ivory",   HSV(h: 0.10,  s: 0.05, v: 0.93)),
    ]

    static func label(for hsv: HSV) -> String {
        // Special-case grays/neutrals: when saturation is very low, ignore
        // hue and pick by value alone — otherwise a near-white pixel might
        // map to "Lemon" just because of trace yellow tint.
        if hsv.s < 0.12 {
            if hsv.v < 0.22 { return "Onyx" }
            if hsv.v > 0.88 { return "Ivory" }
            return "Slate"
        }
        var bestName = anchors[0].name
        var bestD = Double.infinity
        for (name, a) in anchors {
            let d = HSV.weightedDistance(hsv, a)
            if d < bestD { bestD = d; bestName = name }
        }
        return bestName
    }

    /// Returns the anchor's idealised RGB for use as a cluster's display
    /// color (so every bulb's color matches its label, regardless of
    /// member content).
    static func anchorRGB(name: String) -> RGB? {
        anchors.first(where: { $0.name == name })?.hsv.rgb
    }
}
