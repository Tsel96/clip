import Foundation
import CoreGraphics

// MARK: - Public layout value

/// The structural classification of a Smart Selection. `nil` means the
/// selection doesn't qualify and no chrome should appear.
enum SmartSelectionLayout: Equatable {

    /// One-dimensional row. `orderedIDs` is sorted left-to-right by minX.
    /// `gap` is the uniform horizontal gap between adjacent siblings.
    /// `bandY` is the shared y-band (intersection of all element y-projections).
    case row1D(orderedIDs: [UUID], gap: CGFloat, bandY: ClosedRange<CGFloat>)

    /// One-dimensional column. `orderedIDs` is sorted top-to-bottom by minY.
    /// `gap` is the uniform vertical gap between adjacent siblings.
    /// `bandX` is the shared x-band (intersection of all element x-projections).
    case column1D(orderedIDs: [UUID], gap: CGFloat, bandX: ClosedRange<CGFloat>)

    /// Two-dimensional grid. `orderedIDs[row][col]` is the node id at that
    /// matrix slot, ordered top-to-bottom and left-to-right. `gapX` is the
    /// uniform horizontal gap between columns; `gapY` is the uniform vertical
    /// gap between rows.
    case grid2D(orderedIDs: [[UUID]], gapX: CGFloat, gapY: CGFloat)

    /// Flat row-major sequence of IDs — convenient for indexed iteration
    /// during reorder / cascade reflows.
    var flatOrderedIDs: [UUID] {
        switch self {
        case .row1D(let ids, _, _):    return ids
        case .column1D(let ids, _, _): return ids
        case .grid2D(let rows, _, _):  return rows.flatMap { $0 }
        }
    }

    var elementCount: Int { flatOrderedIDs.count }
}

// MARK: - Classifier

/// Pure, stateless classifier. Given the current selection's id-rect pairs,
/// returns the strongest qualifying `SmartSelectionLayout` (preferring 2D
/// over 1D) or `nil` if the selection is not tidy enough to drive Smart
/// Selection chrome.
///
/// Uniformity test (treatise § "Agglomerative Clustering for Equal Spacing"):
/// a set of gaps is "uniform" iff for every pair `(d1, d2)` the normalized
/// ratio `|d1 − d2| / (d1 + d2) < 0.15`. Equivalently, since the max-min
/// pair dominates: `(maxGap − minGap) / (maxGap + minGap) < 0.15`.
enum SmartSelectionClassifier {

    /// Same threshold as `TidyUpEngine.spacingMergeRatio`.
    static let gapUniformityRatio: Double = 0.15
    /// Two nodes count as in the same band if the difference between their
    /// mid-edge coordinates on the perpendicular axis is below this
    /// fraction of the smaller rect's perpendicular extent. Chosen
    /// generously so a Smart Selection survives small visual jitter — the
    /// solver will tighten it on Tidy Up.
    static let bandTolerance: CGFloat = 0.5

    /// Classify the supplied (id, rect) pairs. Order doesn't matter — the
    /// classifier sorts internally.
    static func classify(items: [(id: UUID, rect: CGRect)]) -> SmartSelectionLayout? {
        guard items.count >= 2 else { return nil }
        // Try the most-specific structure first so a tidy 3×3 grid is
        // never reported as nine "rows of one".
        if let grid = tryGrid2D(items: items) { return grid }
        if let row = tryRow1D(items: items)  { return row }
        if let col = tryColumn1D(items: items) { return col }
        return nil
    }

    // MARK: - Row1D

    private static func tryRow1D(items: [(id: UUID, rect: CGRect)]) -> SmartSelectionLayout? {
        let sorted = items.sorted { $0.rect.minX < $1.rect.minX }
        // Every pair's y-bands must overlap. Equivalent to: max(minY) < min(maxY).
        let maxMinY = sorted.map { $0.rect.minY }.max() ?? 0
        let minMaxY = sorted.map { $0.rect.maxY }.min() ?? 0
        guard minMaxY > maxMinY else { return nil }

        // Compute consecutive x-gaps. All must be positive (rects don't
        // overlap horizontally) and uniform.
        var gaps: [CGFloat] = []
        for i in 0..<(sorted.count - 1) {
            let g = sorted[i + 1].rect.minX - sorted[i].rect.maxX
            guard g > 0 else { return nil }
            gaps.append(g)
        }
        guard gapsUniform(gaps) else { return nil }
        let meanGap = gaps.map(Double.init).reduce(0, +) / Double(gaps.count)
        return .row1D(
            orderedIDs: sorted.map(\.id),
            gap: CGFloat(meanGap),
            bandY: maxMinY...minMaxY
        )
    }

    // MARK: - Column1D

    private static func tryColumn1D(items: [(id: UUID, rect: CGRect)]) -> SmartSelectionLayout? {
        let sorted = items.sorted { $0.rect.minY < $1.rect.minY }
        let maxMinX = sorted.map { $0.rect.minX }.max() ?? 0
        let minMaxX = sorted.map { $0.rect.maxX }.min() ?? 0
        guard minMaxX > maxMinX else { return nil }
        var gaps: [CGFloat] = []
        for i in 0..<(sorted.count - 1) {
            let g = sorted[i + 1].rect.minY - sorted[i].rect.maxY
            guard g > 0 else { return nil }
            gaps.append(g)
        }
        guard gapsUniform(gaps) else { return nil }
        let meanGap = gaps.map(Double.init).reduce(0, +) / Double(gaps.count)
        return .column1D(
            orderedIDs: sorted.map(\.id),
            gap: CGFloat(meanGap),
            bandX: maxMinX...minMaxX
        )
    }

    // MARK: - Grid2D

    private static func tryGrid2D(items: [(id: UUID, rect: CGRect)]) -> SmartSelectionLayout? {
        guard items.count >= 4 else { return nil }   // 2×2 minimum

        // Bucket nodes into rows by midY proximity. Two nodes share a row
        // if `|midY_a − midY_b| ≤ bandTolerance · min(height_a, height_b)`.
        let rowBuckets = clusterRectsByPerpendicularMid(
            items: items,
            byY: true
        )
        let colBuckets = clusterRectsByPerpendicularMid(
            items: items,
            byY: false
        )
        // For a rectangular grid: number of rows × number of columns = total.
        guard rowBuckets.count >= 2, colBuckets.count >= 2,
              rowBuckets.count * colBuckets.count == items.count
        else { return nil }

        // Sort row buckets by ascending mean-midY, col buckets by ascending mean-midX.
        let sortedRows = rowBuckets.sorted { (a, b) -> Bool in
            meanMidY(a) < meanMidY(b)
        }
        let sortedCols = colBuckets.sorted { (a, b) -> Bool in
            meanMidX(a) < meanMidX(b)
        }

        // For each row bucket, sort its members by minX. Validate Row1D-ness
        // of every row with the same uniformity criterion.
        var orderedRows: [[UUID]] = []
        var rowGaps: [CGFloat] = []
        var firstRowGap: CGFloat? = nil
        for row in sortedRows {
            let sorted = row.sorted { $0.rect.minX < $1.rect.minX }
            // y-band overlap inside the row.
            let maxMinY = sorted.map { $0.rect.minY }.max() ?? 0
            let minMaxY = sorted.map { $0.rect.maxY }.min() ?? 0
            guard minMaxY > maxMinY else { return nil }
            // Gap uniformity.
            var gaps: [CGFloat] = []
            for i in 0..<(sorted.count - 1) {
                let g = sorted[i + 1].rect.minX - sorted[i].rect.maxX
                guard g > 0 else { return nil }
                gaps.append(g)
            }
            guard gapsUniform(gaps) else { return nil }
            let mean = gaps.map(Double.init).reduce(0, +) / Double(gaps.count)
            if let prev = firstRowGap {
                // All rows must share the same gap-X (within ratio).
                let pairRatio = abs(Double(prev) - mean) / (Double(prev) + mean)
                guard pairRatio < gapUniformityRatio else { return nil }
            } else {
                firstRowGap = CGFloat(mean)
            }
            rowGaps.append(CGFloat(mean))
            orderedRows.append(sorted.map(\.id))
        }
        // Likewise validate columns.
        var colGaps: [CGFloat] = []
        var firstColGap: CGFloat? = nil
        for col in sortedCols {
            let sorted = col.sorted { $0.rect.minY < $1.rect.minY }
            let maxMinX = sorted.map { $0.rect.minX }.max() ?? 0
            let minMaxX = sorted.map { $0.rect.maxX }.min() ?? 0
            guard minMaxX > maxMinX else { return nil }
            var gaps: [CGFloat] = []
            for i in 0..<(sorted.count - 1) {
                let g = sorted[i + 1].rect.minY - sorted[i].rect.maxY
                guard g > 0 else { return nil }
                gaps.append(g)
            }
            guard gapsUniform(gaps) else { return nil }
            let mean = gaps.map(Double.init).reduce(0, +) / Double(gaps.count)
            if let prev = firstColGap {
                let pairRatio = abs(Double(prev) - mean) / (Double(prev) + mean)
                guard pairRatio < gapUniformityRatio else { return nil }
            } else {
                firstColGap = CGFloat(mean)
            }
            colGaps.append(CGFloat(mean))
        }

        // Mean of mean-gaps for the final reported value.
        let meanGapX = rowGaps.map(Double.init).reduce(0, +) / Double(rowGaps.count)
        let meanGapY = colGaps.map(Double.init).reduce(0, +) / Double(colGaps.count)

        return .grid2D(
            orderedIDs: orderedRows,
            gapX: CGFloat(meanGapX),
            gapY: CGFloat(meanGapY)
        )
    }

    // MARK: - Helpers

    /// Test "all-pairs uniform" via the max-min shortcut equivalent to the
    /// treatise's full pairwise ratio test.
    private static func gapsUniform(_ gaps: [CGFloat]) -> Bool {
        guard let minG = gaps.min(), let maxG = gaps.max() else { return false }
        let denom = Double(minG) + Double(maxG)
        guard denom > 1e-9 else { return false }
        return Double(maxG - minG) / denom < gapUniformityRatio
    }

    /// Bucket nodes into rows (`byY = true`) or columns (`byY = false`) by
    /// mid-edge proximity. Used for grid identification.
    private static func clusterRectsByPerpendicularMid(
        items: [(id: UUID, rect: CGRect)],
        byY: Bool
    ) -> [[(id: UUID, rect: CGRect)]] {
        // Sort by the relevant mid-coordinate.
        let sorted = items.sorted { lhs, rhs in
            byY ? (lhs.rect.midY < rhs.rect.midY) : (lhs.rect.midX < rhs.rect.midX)
        }
        var buckets: [[(id: UUID, rect: CGRect)]] = []
        for item in sorted {
            let mid = byY ? item.rect.midY : item.rect.midX
            let extent = byY ? item.rect.height : item.rect.width
            if let last = buckets.last,
               let ref = last.last {
                let refMid = byY ? ref.rect.midY : ref.rect.midX
                let refExt = byY ? ref.rect.height : ref.rect.width
                let tolerance = bandTolerance * min(extent, refExt)
                if abs(mid - refMid) <= tolerance {
                    buckets[buckets.count - 1].append(item)
                    continue
                }
            }
            buckets.append([item])
        }
        return buckets
    }

    private static func meanMidY(_ items: [(id: UUID, rect: CGRect)]) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let sum = items.map(\.rect.midY).reduce(0, +)
        return sum / CGFloat(items.count)
    }
    private static func meanMidX(_ items: [(id: UUID, rect: CGRect)]) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let sum = items.map(\.rect.midX).reduce(0, +)
        return sum / CGFloat(items.count)
    }
}
