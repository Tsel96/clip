import AppKit

/// Native (NSColor) palette extraction for the detail view — a coarse RGB-bucket
/// quantizer over a card's representative image. Pure AppKit/CoreGraphics, no
/// SwiftUI, so the native detail view never reaches for a SwiftUI `Color`.
enum NativePalette {

    /// Up to `count` distinct dominant colors of `node`'s representative image.
    static func colors(for node: CanvasNode, count: Int) async -> [NSColor] {
        guard let cg = await ColorExtraction.representativeCGImage(for: node) else { return [] }
        return quantize(cg, count: count)
    }

    static func quantize(_ cg: CGImage, count: Int) -> [NSColor] {
        let maxDim = 64
        let f = min(1.0, Double(maxDim) / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * f)), h = max(1, Int(Double(cg.height) * f))
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 4 bits per channel → 4096 buckets, summed then averaged.
        var sums: [Int: (r: Double, g: Double, b: Double, n: Int)] = [:]
        var i = 0
        while i < data.count {
            if data[i + 3] > 200 {                                  // opaque pixels only
                let r = data[i], g = data[i + 1], b = data[i + 2]
                let key = (Int(r >> 4) << 8) | (Int(g >> 4) << 4) | Int(b >> 4)
                var e = sums[key] ?? (0, 0, 0, 0)
                e.r += Double(r); e.g += Double(g); e.b += Double(b); e.n += 1
                sums[key] = e
            }
            i += 4
        }
        var result: [NSColor] = []
        for e in sums.values.sorted(by: { $0.n > $1.n }) {
            let c = NSColor(srgbRed: CGFloat(e.r / Double(e.n) / 255),
                            green: CGFloat(e.g / Double(e.n) / 255),
                            blue: CGFloat(e.b / Double(e.n) / 255), alpha: 1)
            if result.allSatisfy({ distance($0, c) > 0.12 }) { result.append(c) }
            if result.count >= count { break }
        }
        return result
    }

    static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return 1 }
        let dr = x.redComponent - y.redComponent
        let dg = x.greenComponent - y.greenComponent
        let db = x.blueComponent - y.blueComponent
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
