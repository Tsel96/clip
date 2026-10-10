import Foundation
import CoreGraphics

// MARK: - Public report types

/// Per-axis alignment cluster discovered by the iterative-refit RANSAC pass.
/// Each cluster represents a set of node edges that agree on a single
/// coordinate within tolerance.
struct TidyAlignmentCluster {
    enum Axis { case x, y }
    enum EdgeKind {
        case minEdge   // left for x, top for y
        case midEdge
        case maxEdge   // right for x, bottom for y
    }
    struct Member {
        let nodeIndex: Int
        let edgeKind: EdgeKind
        /// Pre-tidy coordinate value contributed by this node's edge.
        let originalCoord: CGFloat
    }
    let axis: Axis
    /// The mean of all inliers — the line every member should snap to.
    let coordinate: CGFloat
    let members: [Member]
    /// Inlier count − variance/tolerance² (treatise: "most inliers with
    /// least deviation"). Used to rank constraints during the solve.
    let score: Double
}

/// One spacing cluster from the agglomerative pass: a set of gaps within a
/// row or column whose normalized ratio `|d1-d2|/(d1+d2) < 0.15` brought
/// them under a common target.
struct TidySpacingCluster {
    enum Axis { case horizontal, vertical }
    struct Gap {
        let leftNodeIndex: Int
        let rightNodeIndex: Int
        let originalSize: CGFloat
    }
    let axis: Axis
    let target: CGFloat
    let gaps: [Gap]
    /// `inlierCount − normalizedVariance`. Used to rank against alignment
    /// clusters when ordering constraint addition.
    let score: Double
}

/// Diagnostic summary returned alongside the snapped rects.
struct TidyUpReport {
    let alignmentClustersX: [TidyAlignmentCluster]
    let alignmentClustersY: [TidyAlignmentCluster]
    let rowSpacingClusters: [TidySpacingCluster]
    let columnSpacingClusters: [TidySpacingCluster]
    let droppedConstraints: Int
}

// MARK: - TidyUpEngine

/// Bulk layout beautification engine. Pure value-in / value-out — no
/// SwiftUI, no `CanvasState`, no side effects. The pipeline replicates the
/// treatise's three phases:
///
///   1. **Deterministic RANSAC alignment clustering.** For N rects, emit
///      6N edges (left/midX/right for x, top/midY/bottom for y) and
///      iteratively refit clusters until each set of inliers stabilises.
///      Greedy: highest-scoring cluster wins, its inliers leave the pool,
///      repeat until no cluster of size ≥ 2 survives.
///   2. **Agglomerative spacing clustering.** For each row of nodes sharing
///      a horizontal alignment band (or column sharing a vertical band),
///      merge adjacent-gap clusters whose normalized ratio `|d1−d2| /
///      (d1+d2)` is below 0.15, until no merge qualifies.
///   3. **Weighted least-squares with incremental constraint addition.**
///      Each clustered edge / equal-spacing relation becomes a soft
///      constraint with a weight derived from its RANSAC / spacing score.
///      A regularizer pulls each node toward its original position so the
///      system is never under-determined. Constraints are added in score
///      order, the normal-equations system is re-solved (Gauss-Seidel
///      converges in O(N) iterations on diagonally-dominant systems), and
///      any constraint whose addition pushes the energy past its budget
///      is dropped — preserving "macroscopic layout intent."
///
/// The x and y axes are solved independently: Tidy Up does not resize
/// nodes, so width / height stay fixed and the two axes are mathematically
/// separable. The treatise's CHOLMOD step is replaced by Gauss-Seidel on
/// the dense normal-equations matrix because at our scale (N ≤ ~50, ⇒
/// matrix ≤ 50×50) the sparse-vs-dense choice is irrelevant; the iteration
/// itself is what the paper requires.
enum TidyUpEngine {

    /// Snap threshold the rest of the codebase already uses, in screen
    /// pixels. Converted to world units by the caller's zoom.
    static let alignmentToleranceScreen: CGFloat = 3
    /// Normalized-ratio threshold for the agglomerative spacing merge
    /// (treatise: "typically set around 0.15").
    static let spacingMergeRatio: Double = 0.15
    /// Per-node energy budget (squared world points). Each constraint
    /// whose acceptance pushes total energy past `budget = n · this`
    /// is dropped before further constraints are tried.
    static let energyBudgetPerNode: Double = 60 * 60

    /// Tidy Up the supplied rectangles.
    /// - Parameter rects: world-space rectangles to snap.
    /// - Parameter zoom: the current camera zoom (used to convert the
    ///   3-screen-pixel tolerance to world units).
    /// - Returns: the new world-space rectangles (same order as input,
    ///   widths + heights unchanged) plus a diagnostic report.
    static func tidy(
        rects: [CGRect],
        zoom: CGFloat
    ) -> (rects: [CGRect], report: TidyUpReport) {
        guard rects.count >= 2 else {
            return (rects, TidyUpReport(
                alignmentClustersX: [], alignmentClustersY: [],
                rowSpacingClusters: [], columnSpacingClusters: [],
                droppedConstraints: 0))
        }

        let tolerance = alignmentToleranceScreen / max(zoom, 0.0001)

        // --- Phase 1: RANSAC alignment clustering on each axis. ---
        let edgesX = buildEdges(rects: rects, axis: .x)
        let edgesY = buildEdges(rects: rects, axis: .y)
        let clustersX = ransacCluster(edges: edgesX, axis: .x, tolerance: tolerance)
        let clustersY = ransacCluster(edges: edgesY, axis: .y, tolerance: tolerance)

        // --- Phase 2: row / column identification via midEdge clusters. ---
        let rows = bandsFromMidEdgeClusters(clusters: clustersY)
        let columns = bandsFromMidEdgeClusters(clusters: clustersX)

        // --- Phase 3: agglomerative spacing within each band. ---
        var rowSpacingClusters: [TidySpacingCluster] = []
        for row in rows {
            let cs = agglomerativeSpacing(
                rectIndices: row,
                rects: rects,
                axis: .horizontal
            )
            rowSpacingClusters.append(contentsOf: cs)
        }
        var columnSpacingClusters: [TidySpacingCluster] = []
        for col in columns {
            let cs = agglomerativeSpacing(
                rectIndices: col,
                rects: rects,
                axis: .vertical
            )
            columnSpacingClusters.append(contentsOf: cs)
        }

        // --- Phase 4: solve x and y independently. ---
        let xResult = solveAxis(
            originals: rects.map(\.minX),
            sizes: rects.map(\.width),
            alignmentClusters: clustersX,
            spacingClusters: rowSpacingClusters
        )
        let yResult = solveAxis(
            originals: rects.map(\.minY),
            sizes: rects.map(\.height),
            alignmentClusters: clustersY,
            spacingClusters: columnSpacingClusters
        )

        let snapped: [CGRect] = rects.indices.map { i in
            CGRect(
                x: xResult.coords[i], y: yResult.coords[i],
                width: rects[i].width, height: rects[i].height
            )
        }

        let report = TidyUpReport(
            alignmentClustersX: clustersX,
            alignmentClustersY: clustersY,
            rowSpacingClusters: rowSpacingClusters,
            columnSpacingClusters: columnSpacingClusters,
            droppedConstraints: xResult.dropped + yResult.dropped
        )
        return (snapped, report)
    }

    // MARK: - Phase 1: edge generation

    private struct Edge {
        let nodeIndex: Int
        let kind: TidyAlignmentCluster.EdgeKind
        let value: CGFloat
    }

    private static func buildEdges(
        rects: [CGRect],
        axis: TidyAlignmentCluster.Axis
    ) -> [Edge] {
        var out: [Edge] = []
        out.reserveCapacity(rects.count * 3)
        for (i, r) in rects.enumerated() {
            switch axis {
            case .x:
                out.append(Edge(nodeIndex: i, kind: .minEdge, value: r.minX))
                out.append(Edge(nodeIndex: i, kind: .midEdge, value: r.midX))
                out.append(Edge(nodeIndex: i, kind: .maxEdge, value: r.maxX))
            case .y:
                out.append(Edge(nodeIndex: i, kind: .minEdge, value: r.minY))
                out.append(Edge(nodeIndex: i, kind: .midEdge, value: r.midY))
                out.append(Edge(nodeIndex: i, kind: .maxEdge, value: r.maxY))
            }
        }
        return out
    }

    // MARK: - Phase 1: deterministic RANSAC iterative refit

    /// Iterative-refit greedy clustering. The treatise's loop:
    ///   init → inlier test → refit (mean) → convergence → score → pick best
    /// — repeated until no qualifying cluster (≥ 2 inliers) remains.
    ///
    /// Iteration over the `remaining` set is sorted by edge index so the
    /// algorithm is fully deterministic — same input always yields the
    /// same output, important for testability.
    /// First index whose value is ≥ `x` (values sorted ascending).
    private static func lowerBound(_ values: [Double], _ x: Double) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First index whose value is > `x` (values sorted ascending).
    private static func upperBound(_ values: [Double], _ x: Double) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] <= x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func ransacCluster(
        edges: [Edge],
        axis: TidyAlignmentCluster.Axis,
        tolerance: CGFloat
    ) -> [TidyAlignmentCluster] {

        var remaining = Set(edges.indices)
        var out: [TidyAlignmentCluster] = []

        while !remaining.isEmpty {
            var bestScore: Double = -.infinity
            var bestSeedHasCluster = false
            var bestMean: Double = 0
            var bestInliers: Set<Int> = []

            // Deterministic seed order.
            let seeds = remaining.sorted()
            // The pool sorted by value, so each inlier test is a binary-searched
            // window [line - tol, line + tol] instead of a scan of every edge
            // (that scan, per seed per refit, made this O(R³) on big selections).
            let pool = seeds.sorted {
                edges[$0].value != edges[$1].value ? edges[$0].value < edges[$1].value : $0 < $1
            }
            let poolValues = pool.map { Double(edges[$0].value) }

            for seed in seeds {
                var line = Double(edges[seed].value)
                var inliers = Set<Int>([seed])

                // Iterate to convergence (bounded at 32 — typical = 2-4).
                for _ in 0..<32 {
                    let lo = lowerBound(poolValues, line - Double(tolerance))
                    let hi = upperBound(poolValues, line + Double(tolerance))
                    let fresh = Set(pool[lo..<hi])
                    var sum = 0.0
                    for k in lo..<hi { sum += poolValues[k] }
                    let count = hi - lo
                    let newLine = count > 0 ? sum / Double(count) : line
                    let stable = (fresh == inliers) && abs(newLine - line) < 1e-6
                    inliers = fresh
                    line = newLine
                    if stable { break }
                }

                guard inliers.count >= 2 else { continue }

                var variance = 0.0
                for j in inliers {
                    let d = Double(edges[j].value) - line
                    variance += d * d
                }
                variance /= Double(inliers.count)
                let tol2 = Double(tolerance) * Double(tolerance)
                let score = Double(inliers.count) - variance / max(tol2, 1e-9)

                if score > bestScore {
                    bestScore = score
                    bestMean = line
                    bestInliers = inliers
                    bestSeedHasCluster = true
                }
            }

            guard bestSeedHasCluster else { break }

            // Dedupe: at most one edge per node in a cluster, keeping the
            // edge closest to the cluster mean. The discarded edges leave
            // the pool too — they belonged to this cluster spatially.
            let sortedInliers = bestInliers.sorted { lhs, rhs in
                abs(Double(edges[lhs].value) - bestMean) <
                abs(Double(edges[rhs].value) - bestMean)
            }
            var seenNodes = Set<Int>()
            var deduped: [Int] = []
            for j in sortedInliers {
                let nodeIdx = edges[j].nodeIndex
                if seenNodes.contains(nodeIdx) { continue }
                seenNodes.insert(nodeIdx)
                deduped.append(j)
            }

            // Remove every inlier — discarded or kept — from the pool so
            // we don't loop indefinitely on the same coordinate region.
            for j in bestInliers { remaining.remove(j) }

            guard deduped.count >= 2 else { continue }

            let members = deduped.map { j -> TidyAlignmentCluster.Member in
                let e = edges[j]
                return TidyAlignmentCluster.Member(
                    nodeIndex: e.nodeIndex,
                    edgeKind: e.kind,
                    originalCoord: e.value
                )
            }
            out.append(TidyAlignmentCluster(
                axis: axis,
                coordinate: CGFloat(bestMean),
                members: members,
                score: bestScore
            ))
        }

        return out
    }

    // MARK: - Phase 2: row / column identification

    /// Group node indices by which mid-edge cluster their nodes belong to.
    /// Returns one band per cluster — sorting along the gap axis is done
    /// later in `agglomerativeSpacing`.
    private static func bandsFromMidEdgeClusters(
        clusters: [TidyAlignmentCluster]
    ) -> [[Int]] {
        var bands: [[Int]] = []
        for cluster in clusters {
            let mid = cluster.members.filter { $0.edgeKind == .midEdge }
            guard mid.count >= 2 else { continue }
            bands.append(mid.map(\.nodeIndex))
        }
        return bands
    }

    // MARK: - Phase 3: agglomerative spacing clustering

    private static func agglomerativeSpacing(
        rectIndices: [Int],
        rects: [CGRect],
        axis: TidySpacingCluster.Axis
    ) -> [TidySpacingCluster] {

        let sorted = rectIndices.sorted { lhs, rhs in
            switch axis {
            case .horizontal: return rects[lhs].minX < rects[rhs].minX
            case .vertical:   return rects[lhs].minY < rects[rhs].minY
            }
        }
        guard sorted.count >= 2 else { return [] }

        struct RawGap {
            let leftNodeIndex: Int
            let rightNodeIndex: Int
            let size: CGFloat
        }
        var rawGaps: [RawGap] = []
        for i in 0..<(sorted.count - 1) {
            let l = sorted[i], r = sorted[i + 1]
            let size: CGFloat = {
                switch axis {
                case .horizontal: return rects[r].minX - rects[l].maxX
                case .vertical:   return rects[r].minY - rects[l].maxY
                }
            }()
            guard size > 0 else { continue }
            rawGaps.append(RawGap(leftNodeIndex: l, rightNodeIndex: r, size: size))
        }
        guard !rawGaps.isEmpty else { return [] }

        struct Working {
            var memberGapIndices: [Int]
            var mean: Double
        }
        var clusters: [Working] = rawGaps.enumerated().map { (i, g) in
            Working(memberGapIndices: [i], mean: Double(g.size))
        }

        // Merge nearest-pair until no qualifying merge remains.
        while clusters.count >= 2 {
            var bestPair: (i: Int, j: Int, ratio: Double)? = nil
            for i in 0..<clusters.count {
                for j in (i + 1)..<clusters.count {
                    let d1 = clusters[i].mean
                    let d2 = clusters[j].mean
                    let denom = d1 + d2
                    guard denom > 1e-9 else { continue }
                    let ratio = abs(d1 - d2) / denom
                    if ratio < spacingMergeRatio,
                       bestPair == nil || ratio < bestPair!.ratio {
                        bestPair = (i, j, ratio)
                    }
                }
            }
            guard let p = bestPair else { break }
            let na = clusters[p.i].memberGapIndices.count
            let nb = clusters[p.j].memberGapIndices.count
            let merged = (clusters[p.i].mean * Double(na) +
                          clusters[p.j].mean * Double(nb)) / Double(na + nb)
            clusters[p.i].mean = merged
            clusters[p.i].memberGapIndices.append(contentsOf: clusters[p.j].memberGapIndices)
            clusters.remove(at: p.j)
        }

        return clusters.compactMap { w -> TidySpacingCluster? in
            guard !w.memberGapIndices.isEmpty else { return nil }
            var variance = 0.0
            for idx in w.memberGapIndices {
                let d = Double(rawGaps[idx].size) - w.mean
                variance += d * d
            }
            variance /= Double(w.memberGapIndices.count)
            let denom = w.mean * w.mean
            let score = Double(w.memberGapIndices.count) -
                        (denom > 1e-9 ? variance / denom : 0)
            let gaps = w.memberGapIndices.map { i in
                TidySpacingCluster.Gap(
                    leftNodeIndex: rawGaps[i].leftNodeIndex,
                    rightNodeIndex: rawGaps[i].rightNodeIndex,
                    originalSize: rawGaps[i].size
                )
            }
            return TidySpacingCluster(
                axis: axis,
                target: CGFloat(w.mean),
                gaps: gaps,
                score: score
            )
        }
    }

    // MARK: - Phase 4: weighted LSQ with incremental constraint addition

    /// One row of the weighted-LSQ system. The variables here are the new
    /// world-coordinates of the N nodes along the axis being solved.
    private struct Constraint {
        /// Sparse coefficient list — 1 entry for alignment, 2 for spacing.
        let terms: [(idx: Int, coef: Double)]
        let rhs: Double
        let weight: Double
        /// Used only for sorting — higher score = added earlier.
        let score: Double
    }

    private struct SolveResult {
        let coords: [CGFloat]
        let dropped: Int
    }

    private static func solveAxis(
        originals: [CGFloat],
        sizes: [CGFloat],
        alignmentClusters: [TidyAlignmentCluster],
        spacingClusters: [TidySpacingCluster]
    ) -> SolveResult {

        let n = originals.count
        guard n > 0 else { return SolveResult(coords: [], dropped: 0) }

        var pending: [Constraint] = []

        for cluster in alignmentClusters {
            for m in cluster.members {
                let off: Double
                switch m.edgeKind {
                case .minEdge: off = 0
                case .midEdge: off = Double(sizes[m.nodeIndex]) / 2
                case .maxEdge: off = Double(sizes[m.nodeIndex])
                }
                pending.append(Constraint(
                    terms: [(m.nodeIndex, 1.0)],
                    rhs: Double(cluster.coordinate) - off,
                    weight: max(1.0, cluster.score),
                    score: cluster.score
                ))
            }
        }
        for cluster in spacingClusters {
            for g in cluster.gaps {
                pending.append(Constraint(
                    terms: [(g.leftNodeIndex, -1.0), (g.rightNodeIndex, 1.0)],
                    rhs: Double(sizes[g.leftNodeIndex]) + Double(cluster.target),
                    weight: max(1.0, cluster.score),
                    score: cluster.score
                ))
            }
        }
        pending.sort { $0.score > $1.score }

        // The normal-equation system (AᵀWA + reg²·I) x = AᵀWb + reg²·orig is
        // kept SPARSE and updated incrementally: each constraint touches one
        // or two nodes, so adding (or rolling back) one is O(1), and each
        // Gauss-Seidel sweep is O(n + nnz) instead of rebuilding and sweeping
        // a dense n×n matrix per constraint (which was O(C·n³) overall and
        // froze Tidy Up on ~100 cards).
        let regWeight = 1.0
        let reg2 = regWeight * regWeight
        let originalsD = originals.map(Double.init)
        var system = SparseSystem(n: n)
        for i in 0..<n {
            system.diag[i] = reg2
            system.rhs[i] = reg2 * originalsD[i]
        }
        var currentCoords = originalsD
        var currentEnergy = 0.0
        var dropped = 0
        let totalBudget = energyBudgetPerNode * Double(n)

        for c in pending {
            system.add(c, sign: 1)
            let newCoords = system.solve(warmStart: currentCoords)
            var newEnergy = 0.0
            for i in 0..<n {
                let d = newCoords[i] - originalsD[i]
                newEnergy += d * d
            }
            let stepBudget = energyBudgetPerNode / 2 + c.weight * 200
            if newEnergy <= totalBudget && (newEnergy - currentEnergy) <= stepBudget {
                currentCoords = newCoords
                currentEnergy = newEnergy
            } else {
                system.add(c, sign: -1)          // roll the constraint back out
                dropped += 1
            }
        }

        return SolveResult(
            coords: currentCoords.map { CGFloat($0) },
            dropped: dropped
        )
    }

    /// Sparse symmetric system for `solveAxis`: diagonal + per-row
    /// off-diagonal entries (spacing constraints couple two nodes).
    private struct SparseSystem {
        var diag: [Double]
        var off: [[Int: Double]]
        var rhs: [Double]

        init(n: Int) {
            diag = [Double](repeating: 0, count: n)
            off = [[Int: Double]](repeating: [:], count: n)
            rhs = [Double](repeating: 0, count: n)
        }

        /// Add (`sign` = 1) or remove (`sign` = -1) one constraint's
        /// contribution to AᵀWA and AᵀWb.
        mutating func add(_ c: Constraint, sign: Double) {
            let w2 = sign * c.weight * c.weight
            for (a, coefA) in c.terms {
                rhs[a] += w2 * coefA * c.rhs
                for (b, coefB) in c.terms {
                    let val = w2 * coefA * coefB
                    if a == b {
                        diag[a] += val
                    } else {
                        let next = (off[a][b] ?? 0) + val
                        off[a][b] = abs(next) < 1e-12 ? nil : next
                    }
                }
            }
        }

        /// Gauss-Seidel from `warmStart`. The regularizer keeps the matrix
        /// diagonally dominant ⇒ guaranteed convergence; warm-starting from
        /// the previous solution means a new constraint usually settles in a
        /// handful of sweeps.
        func solve(warmStart: [Double]) -> [Double] {
            let n = diag.count
            var x = warmStart
            let maxIter = max(50, n * 4)
            let tol = 1e-6
            for _ in 0..<maxIter {
                var maxDelta = 0.0
                for i in 0..<n {
                    let mii = diag[i]
                    guard mii > 1e-12 else { continue }
                    var sigma = 0.0
                    for (j, mij) in off[i] { sigma += mij * x[j] }
                    let xi = (rhs[i] - sigma) / mii
                    let delta = abs(xi - x[i])
                    if delta > maxDelta { maxDelta = delta }
                    x[i] = xi
                }
                if maxDelta < tol { break }
            }
            return x
        }
    }
}
