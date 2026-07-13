import XCTest
import CoreGraphics
@testable import CLIP

/// Fixed-input characterization tests for `TidyUpEngine.tidy`. The engine
/// documents itself as deterministic (edges are seeded in sorted order
/// "so... same input always yields the same output, important for
/// testability") — these tests hold it to that promise with exact-shape
/// inputs rather than fuzzing the solver.
final class TidyUpEngineTests: XCTestCase {

    private let eps: CGFloat = 0.01

    // A short row of 3 rects: same y (within tolerance) and near-equal,
    // slightly unequal gaps. Tidy is a *soft* weighted-least-squares solve
    // (a regularizer always pulls a bit toward the original position, by
    // design — see solveAxis), so it tightens misalignment sharply rather
    // than snapping to bit-exact equality; assert the spread collapses,
    // not that it hits zero.
    func testRowOfThreeAligns() {
        let rects: [CGRect] = [
            CGRect(x: 0,   y: 0, width: 100, height: 60),
            CGRect(x: 122, y: 2, width: 100, height: 60), // y off by 2 (< tolerance 3)
            CGRect(x: 242, y: 1, width: 100, height: 60),
        ]
        let (snapped, report) = TidyUpEngine.tidy(rects: rects, zoom: 1)

        XCTAssertEqual(snapped.count, 3)
        let ys = snapped.map(\.minY)
        let ySpread = (ys.max() ?? 0) - (ys.min() ?? 0)
        XCTAssertLessThan(ySpread, 0.5, "row alignment should collapse the 2pt y-jitter")

        // widths/heights are untouched by design.
        for r in snapped {
            XCTAssertEqual(r.width, 100, accuracy: eps)
            XCTAssertEqual(r.height, 60, accuracy: eps)
        }

        let gap1 = snapped[1].minX - snapped[0].maxX
        let gap2 = snapped[2].minX - snapped[1].maxX
        XCTAssertEqual(gap1, gap2, accuracy: 1.0, "near-equal gaps should merge toward one target spacing")
        XCTAssertFalse(report.alignmentClustersY.isEmpty)
    }

    // A 2x2 grid with small jitter (< the 3px screen tolerance) on every
    // edge: each row should end up much closer in y, each column much
    // closer in x, than the original jitter (same soft-solve caveat as above).
    func testTwoByTwoGridAlignsRowsAndColumns() {
        let rects: [CGRect] = [
            CGRect(x: 0,   y: 0,   width: 100, height: 80), // top-left
            CGRect(x: 152, y: 2,   width: 100, height: 80), // top-right
            CGRect(x: 2,   y: 120, width: 100, height: 80), // bottom-left
            CGRect(x: 150, y: 122, width: 100, height: 80), // bottom-right
        ]
        let (snapped, _) = TidyUpEngine.tidy(rects: rects, zoom: 1)
        XCTAssertEqual(snapped.count, 4)

        // Original jitter is 2pt on every edge; tidy should cut it well below that.
        XCTAssertLessThan(abs(snapped[0].minY - snapped[1].minY), 1.0, "top row moves toward a shared y")
        XCTAssertLessThan(abs(snapped[2].minY - snapped[3].minY), 1.0, "bottom row moves toward a shared y")
        XCTAssertLessThan(abs(snapped[0].minX - snapped[2].minX), 1.0, "left column moves toward a shared x")
        XCTAssertLessThan(abs(snapped[1].minX - snapped[3].minX), 1.0, "right column moves toward a shared x")
    }

    // An input that is already perfectly aligned and evenly spaced must be
    // a fixed point of tidy() — this is the idempotence guarantee the
    // energy-budget regularizer exists to preserve.
    func testAlreadyTidyInputIsUnchanged() {
        let rects: [CGRect] = [
            CGRect(x: 0,   y: 0, width: 80, height: 60),
            CGRect(x: 100, y: 0, width: 80, height: 60),
            CGRect(x: 200, y: 0, width: 80, height: 60),
        ]
        let (snapped, _) = TidyUpEngine.tidy(rects: rects, zoom: 1)
        for (original, result) in zip(rects, snapped) {
            XCTAssertEqual(result.minX, original.minX, accuracy: eps)
            XCTAssertEqual(result.minY, original.minY, accuracy: eps)
            XCTAssertEqual(result.width, original.width, accuracy: eps)
            XCTAssertEqual(result.height, original.height, accuracy: eps)
        }
    }

    // Fewer than 2 rects: documented early-out, no clusters, no crash.
    func testFewerThanTwoRectsIsANoOp() {
        let rects: [CGRect] = [CGRect(x: 5, y: 5, width: 40, height: 40)]
        let (snapped, report) = TidyUpEngine.tidy(rects: rects, zoom: 1)
        XCTAssertEqual(snapped, rects)
        XCTAssertEqual(report.droppedConstraints, 0)
        XCTAssertTrue(report.alignmentClustersX.isEmpty)
    }
}
