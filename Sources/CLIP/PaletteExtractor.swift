import SwiftUI
import AppKit

/// Extracted from the deleted CardLightboxLayer.swift (dead legacy lightbox —
/// the live one is NativeDetailHost/CardDetailView): the palette quantizer is
/// still used by CanvasState's auto-tag / prompt generation.
enum PaletteExtractor {
    /// Distinct dominant colors via coarse RGB-bucket quantization (top
    /// buckets, near-duplicates merged). Empty for non-image kinds.
    /// Sync palette — local image cards only. Used by auto-tag / prompt
    /// (must not block on the network).
    static func colors(for node: CanvasNode, count: Int) -> [Color] {
        guard case .image(let data, _) = node.kind,
              let cg = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return [] }
        return quantize(cg, count: count)
    }

    /// Async palette for ANY card that has a representative image — local
    /// image, tweet poster, Instagram og:image, YouTube thumbnail, or a
    /// video frame (fetched via `ColorExtraction`). Empty for text/sticky/
    /// drawing/section.
    static func colorsAsync(for node: CanvasNode, count: Int) async -> [Color] {
        guard let cg = await ColorExtraction.representativeCGImage(for: node) else { return [] }
        return quantize(cg, count: count)
    }

    /// `#RRGGBB` for a swatch (click-to-copy).
    static func hex(_ color: Color) -> String {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }

    /// Coarse RGB-bucket quantizer → up to `count` distinct dominant colors.
    static func quantize(_ cg: CGImage, count: Int) -> [Color] {
        let dim = 32
        var px = [UInt8](repeating: 0, count: dim * dim * 4)
        guard let ctx = CGContext(
            data: &px, width: dim, height: dim, bitsPerComponent: 8,
            bytesPerRow: dim * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: dim, height: dim))

        var buckets: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
        for i in stride(from: 0, to: dim * dim * 4, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            var e = buckets[key] ?? (0, 0, 0, 0)
            e.n += 1; e.r += r; e.g += g; e.b += b
            buckets[key] = e
        }
        let ranked: [(n: Int, c: (Double, Double, Double))] = buckets.values
            .map { e in
                let nd = Double(e.n)
                let avg = (Double(e.r) / nd / 255.0,
                           Double(e.g) / nd / 255.0,
                           Double(e.b) / nd / 255.0)
                return (n: e.n, c: avg)
            }
            .sorted { $0.n > $1.n }

        var picked: [(Double, Double, Double)] = []
        for s in ranked where picked.allSatisfy({ dist($0, s.c) > 0.012 }) {
            picked.append(s.c)
            if picked.count >= count { break }
        }
        return picked.map { Color(.sRGB, red: $0.0, green: $0.1, blue: $0.2) }
    }

    private static func dist(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
        return dr * dr + dg * dg + db * db
    }

    /// Nearest named color — used for auto-tags and prompt synthesis.
    static func colorName(_ color: Color) -> String {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return "neutral" }
        let r = Double(ns.redComponent), g = Double(ns.greenComponent), b = Double(ns.blueComponent)
        let named: [(String, (Double, Double, Double))] = [
            ("black", (0, 0, 0)), ("white", (1, 1, 1)), ("gray", (0.5, 0.5, 0.5)),
            ("red", (0.85, 0.15, 0.15)), ("orange", (0.95, 0.55, 0.15)), ("yellow", (0.95, 0.85, 0.25)),
            ("green", (0.2, 0.65, 0.3)), ("teal", (0.2, 0.6, 0.6)), ("blue", (0.2, 0.4, 0.85)),
            ("purple", (0.5, 0.3, 0.7)), ("pink", (0.9, 0.5, 0.7)), ("brown", (0.5, 0.35, 0.2)),
            ("cream", (0.93, 0.9, 0.82)),
        ]
        var best = "neutral"; var bestD = Double.greatestFiniteMagnitude
        for (name, c) in named {
            let d = (r - c.0) * (r - c.0) + (g - c.1) * (g - c.1) + (b - c.2) * (b - c.2)
            if d < bestD { bestD = d; best = name }
        }
        return best
    }

    /// Color-scheme variations derived from the palette's dominant color.
    static func scheme(_ index: Int, base: [Color]) -> (name: String, colors: [Color]) {
        guard let first = base.first else { return ("Extracted", base) }
        let hsb = hsbOf(first)
        func wrap(_ x: Double) -> Double { let m = x.truncatingRemainder(dividingBy: 1); return m < 0 ? m + 1 : m }
        func hues(_ offs: [Double]) -> [Color] {
            offs.map { Color(hue: wrap(hsb.h + $0), saturation: hsb.s, brightness: hsb.b) }
        }
        switch index % 5 {
        case 0: return ("Extracted", base)
        case 1: return ("Analogous", hues([-0.08, -0.04, 0, 0.04, 0.08]))
        case 2: return ("Complementary", hues([0, 0.04, 0.5, 0.54, 0.46]))
        case 3: return ("Triadic", hues([0, 0.333, 0.667, 0.166, 0.833]))
        default:
            return ("Shades", (0..<6).map {
                Color(hue: hsb.h, saturation: hsb.s,
                      brightness: max(0.15, min(0.95, hsb.b - 0.35 + Double($0) * 0.14)))
            })
        }
    }

    private static func hsbOf(_ color: Color) -> (h: Double, s: Double, b: Double) {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return (0, 0.5, 0.5) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }
}

// MARK: - Cursor rect

/// Applies a custom `NSCursor` to exactly the bounds of this view via an
/// AppKit cursor rect. Unlike `NSCursor.push()` on a SwiftUI hover (which
/// AppKit resets on every mouse-move so it never visually sticks), a cursor
/// rect is managed by the window: the cursor changes on enter and reverts on
/// exit, and is strictly confined to the rect — so it can't leak onto the
/// surrounding toolbar / inspector buttons.
private struct CursorRect: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorRectNSView {
        let v = CursorRectNSView()
        v.cursor = cursor
        return v
    }

    func updateNSView(_ nsView: CursorRectNSView, context: Context) {
        nsView.cursor = cursor
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    final class CursorRectNSView: NSView {
        var cursor: NSCursor = .arrow

        // Transparent to mouse events so the SwiftUI tap-to-copy gesture
        // underneath still fires; cursor rects work regardless of hit-testing.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: cursor)
        }
    }
}
