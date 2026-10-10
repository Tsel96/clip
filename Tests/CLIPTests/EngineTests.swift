import XCTest
import CoreGraphics
import ImageIO
@testable import CLIP

final class TidyUpEngineTests: XCTestCase {

    func testNearlyAlignedCardsSnapToACommonEdge() {
        let rects = [
            CGRect(x: 100, y: 100, width: 200, height: 150),
            CGRect(x: 102, y: 300, width: 200, height: 150),
            CGRect(x: 99, y: 500, width: 200, height: 150),
        ]
        let (out, _) = TidyUpEngine.tidy(rects: rects, zoom: 1)
        XCTAssertEqual(out.count, rects.count)
        // The solver is a weighted least-squares pull toward alignment (it
        // balances against staying put), so the edges converge, not snap.
        let spreadBefore = rects.map(\.minX).max()! - rects.map(\.minX).min()!
        let spreadAfter = out.map(\.minX).max()! - out.map(\.minX).min()!
        XCTAssertLessThan(spreadAfter, spreadBefore / 2, "left edges should pull together: \(out.map(\.minX))")
    }

    func testSizesAreNeverChanged() {
        let rects = (0..<12).map { i in
            CGRect(x: Double(i % 4) * 230 + Double(i % 3), y: Double(i / 4) * 180,
                   width: 200 + Double(i), height: 150 - Double(i))
        }
        let (out, _) = TidyUpEngine.tidy(rects: rects, zoom: 1)
        XCTAssertEqual(out.map(\.size), rects.map(\.size))
    }

    func testDegenerateInputs() {
        XCTAssertEqual(TidyUpEngine.tidy(rects: [], zoom: 1).rects, [])
        let one = [CGRect(x: 5, y: 5, width: 10, height: 10)]
        XCTAssertEqual(TidyUpEngine.tidy(rects: one, zoom: 1).rects, one)
        // Zero-size and zero-zoom input must not produce NaN.
        let zeros = [CGRect.zero, CGRect.zero, CGRect(x: 1, y: 1, width: 0, height: 0)]
        let out = TidyUpEngine.tidy(rects: zeros, zoom: 0).rects
        XCTAssertTrue(out.allSatisfy { $0.origin.x.isFinite && $0.origin.y.isFinite })
    }

    /// Regression guard for the old O(C·n³) solver, which took seconds here.
    func testLargeSelectionFinishesQuickly() {
        var rng = SeededRandom(seed: 42)
        let rects = (0..<150).map { _ in
            CGRect(x: rng.next(in: 0...4000), y: rng.next(in: 0...4000),
                   width: rng.next(in: 80...400), height: rng.next(in: 80...400))
        }
        let start = Date()
        let (out, _) = TidyUpEngine.tidy(rects: rects, zoom: 1)
        XCTAssertEqual(out.count, rects.count)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}

final class ColorExtractionTests: XCTestCase {

    /// RGBA image filled by `paint`.
    private func image(side: Int = 64, _ paint: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        paint(ctx)
        return ctx.makeImage()!
    }

    func testSolidRedIsRed() throws {
        let img = image { $0.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64)) }
        let rgb = try XCTUnwrap(ColorExtraction.dominantColor(from: img))
        XCTAssertGreaterThan(rgb.r, 0.8)
        XCTAssertLessThan(rgb.g, 0.2)
        XCTAssertLessThan(rgb.b, 0.2)
    }

    func testTransparentBackgroundIsNotReadAsBlack() throws {
        // White logo covering a third of an otherwise transparent image.
        let img = image { ctx in
            ctx.clear(CGRect(x: 0, y: 0, width: 64, height: 64))
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 22))
        }
        let rgb = try XCTUnwrap(ColorExtraction.dominantColor(from: img))
        XCTAssertGreaterThan(rgb.r, 0.9, "transparent pixels dragged the colour toward black: \(rgb)")
    }

    func testThumbnailDecodeIsSmall() throws {
        let big = image(side: 1024) { $0.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); $0.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, big, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let thumb = try XCTUnwrap(ColorExtraction.thumbnail(from: data as Data))
        XCTAssertLessThanOrEqual(max(thumb.width, thumb.height), 128)
    }
}

final class URLPolicyTests: XCTestCase {

    func testWebClipsOnlyLoadWebPages() {
        XCTAssertTrue(WebClipURLPolicy.isWebURL(URL(string: "https://example.com")!))
        XCTAssertTrue(WebClipURLPolicy.isWebURL(URL(string: "HTTP://example.com")!))
        XCTAssertFalse(WebClipURLPolicy.isWebURL(URL(string: "file:///Users/me/secret.txt")!))
        XCTAssertFalse(WebClipURLPolicy.isWebURL(URL(string: "javascript:alert(1)")!))
    }

    func testTweetMediaMustComeFromTwitterCDN() {
        XCTAssertNotNil(TweetData.twitterMediaURL("https://video.twimg.com/ext_tw_video/1/pu/vid/a.mp4"))
        XCTAssertNotNil(TweetData.twitterMediaURL("https://pbs.twimg.com/media/abc.jpg"))
        XCTAssertNil(TweetData.twitterMediaURL("http://video.twimg.com/a.mp4"))
        XCTAssertNil(TweetData.twitterMediaURL("https://evil.example/twimg.com/a.mp4"))
        XCTAssertNil(TweetData.twitterMediaURL("https://nottwimg.com/a.mp4"))
        XCTAssertNil(TweetData.twitterMediaURL("file:///etc/passwd"))
    }

    func testTweetIDExtraction() {
        XCTAssertEqual(TweetService.extractTweetID(from: "https://x.com/user/status/1234567890"), "1234567890")
        XCTAssertEqual(TweetService.extractTweetID(from: " https://twitter.com/u/statuses/42?s=20 "), "42")
        XCTAssertNil(TweetService.extractTweetID(from: "https://example.com/status/1"))
    }
}

/// Deterministic generator so performance tests use the same input every run.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt64() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func next(in range: ClosedRange<Double>) -> CGFloat {
        let unit = Double(nextUInt64() >> 11) / Double(1 << 53)
        return CGFloat(range.lowerBound + unit * (range.upperBound - range.lowerBound))
    }
}
