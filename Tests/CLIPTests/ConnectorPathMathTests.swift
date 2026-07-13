import XCTest
import CoreGraphics
@testable import CLIP

/// Table-driven coverage of `bestSide`'s angle-boundary logic plus a
/// geometric sanity check on `route()`. All rects below are square
/// (width == height == 100) so the half-angle `hw` is exactly 45°,
/// giving clean boundary values at ±45°/±135°.
final class ConnectorPathMathTests: XCTestCase {

    private let square = CGRect(x: -50, y: -50, width: 100, height: 100) // centered at origin

    private func other(dx: CGFloat, dy: CGFloat) -> CGRect {
        CGRect(x: dx - 50, y: dy - 50, width: 100, height: 100)
    }

    // MARK: - bestSide: four cardinal directions

    func testBestSideCardinalDirections() {
        let cases: [(dx: CGFloat, dy: CGFloat, expected: ConnSide, label: String)] = [
            (100, 0, .right,  "directly right"),
            (0, 100, .bottom, "directly below (y grows downward)"),
            (-100, 0, .left,  "directly left"),
            (0, -100, .top,   "directly above"),
        ]
        for c in cases {
            let side = ConnectorPathMath.bestSide(of: square, toward: other(dx: c.dx, dy: c.dy))
            XCTAssertEqual(side, c.expected, c.label)
        }
    }

    // MARK: - bestSide: exact boundary angles (hw = 45° for a square rect)

    func testBestSideBoundaryAngles() {
        // At exactly ±45°/±135° the comparisons are `>`/`<=`, so each
        // boundary belongs to exactly one side — verify which.
        let cases: [(dx: CGFloat, dy: CGFloat, expected: ConnSide, label: String)] = [
            (1, 1,   .right,  "+45°: upper bound of right is inclusive"),
            (1, -1,  .top,    "-45°: excluded from right, falls through to top"),
            (-1, 1,  .bottom, "+135°: upper bound of bottom is inclusive"),
            (-1, -1, .left,   "-135°: inclusive lower bound of left"),
        ]
        for c in cases {
            let side = ConnectorPathMath.bestSide(of: square, toward: other(dx: c.dx, dy: c.dy))
            XCTAssertEqual(side, c.expected, c.label)
        }
    }

    // MARK: - route() sanity

    func testRouteEndpointsLandOnExpectedSidesAndRespectStandoff() {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = CGRect(x: 300, y: 0, width: 100, height: 100) // directly to the right

        let route = ConnectorPathMath.route(source: source, target: target)

        XCTAssertEqual(route.sourceSide, .right)
        XCTAssertEqual(route.targetSide, .left)
        XCTAssertEqual(route.sourceCenter, ConnectorPathMath.sideCenter(of: source, .right))
        XCTAssertEqual(route.arrowTip, ConnectorPathMath.sideCenter(of: target, .left))

        // Standoff: the visible line starts/ends `standoffDistance` away
        // from the port, along the side normal.
        XCTAssertEqual(route.sourceCenter.distance(to: route.sourceAnchor),
                        ConnectorPathMath.standoffDistance, accuracy: 0.001)
        XCTAssertEqual(route.arrowTip.distance(to: route.arrowFrom),
                        ConnectorPathMath.standoffDistance, accuracy: 0.001)
        XCTAssertGreaterThan(route.sourceAnchor.x, route.sourceCenter.x, "standoff steps outward, toward target")
        XCTAssertLessThan(route.arrowFrom.x, route.arrowTip.x, "standoff steps outward, toward source")

        // Midpoint sits between the two standoff points on this straight,
        // horizontally-symmetric layout.
        XCTAssertEqual(route.midpoint.y, route.sourceAnchor.y, accuracy: 0.001)
        XCTAssertGreaterThan(route.midpoint.x, route.sourceAnchor.x)
        XCTAssertLessThan(route.midpoint.x, route.arrowFrom.x)
    }

    func testRouteRespectsCustomStandoff() {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = CGRect(x: 300, y: 0, width: 100, height: 100)
        let route = ConnectorPathMath.route(source: source, target: target, standoff: 20)
        XCTAssertEqual(route.sourceCenter.distance(to: route.sourceAnchor), 20, accuracy: 0.001)
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
