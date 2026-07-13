import XCTest
@testable import CLIP

/// Baseline smoke test — proves the test target links against the app
/// module. Real suites live alongside (TidyUpEngine, ConnectorPathMath,
/// MediaStore, Persistence).
final class SmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertGreaterThan(Motion.structureResponse, 0)
    }
}
