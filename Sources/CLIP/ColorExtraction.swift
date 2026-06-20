import Foundation
import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - RGB

/// Lightweight color value used by the Colorform pipeline. Components are
/// 0…1 in the sRGB color space — same convention as `StrokeColor`.
struct RGB: Hashable, Codable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r.clamped(); self.g = g.clamped(); self.b = b.clamped()
    }

    /// Make an RGB from a hue in [0,1] at fixed saturation+value. Used as a
    /// fallback for nodes with no extractable visual color so they still
    /// participate in clustering instead of all dumping into one bucket.
    static func fromHue(_ hue: Double, saturation: Double = 0.7, value: Double = 0.85) -> RGB {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        let i = Int(floor(h * 6))
        let f = h * 6 - Double(i)
        let p = value * (1 - saturation)
        let q = value * (1 - f * saturation)
        let t = value * (1 - (1 - f) * saturation)
        switch i % 6 {
        case 0: return RGB(r: value, g: t,     b: p)
        case 1: return RGB(r: q,     g: value, b: p)
        case 2: return RGB(r: p,     g: value, b: t)
        case 3: return RGB(r: p,     g: q,     b: value)
        case 4: return RGB(r: t,     g: p,     b: value)
        default: return RGB(r: value, g: p,    b: q)
        }
    }

    /// HSV breakdown. Hue is in [0,1] (wraps), saturation and value in [0,1].
    var hsv: (h: Double, s: Double, v: Double) {
        let mx = max(r, max(g, b))
        let mn = min(r, min(g, b))
        let d = mx - mn
        let v = mx
        let s = mx == 0 ? 0 : d / mx
        var h: Double = 0
        if d != 0 {
            if mx == r       { h = (g - b) / d + (g < b ? 6 : 0) }
            else if mx == g  { h = (b - r) / d + 2 }
            else             { h = (r - g) / d + 4 }
            h /= 6
        }
        return (h, s, v)
    }

    /// SwiftUI Color shim, since `Color` is non-Codable.
    var swiftUIColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}

private extension Double {
    func clamped(_ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, self)) }
}

// MARK: - ColorExtraction

/// Per-node dominant-color extraction. Each branch is async because tweets
/// and Instagram embeds require a network fetch; everything falls back to
/// `RGB.fromHue` derived from a stable hash of the node so failures still
/// produce a usable color (rather than 0,0,0 dumping into "Black").
enum ColorExtraction {

    /// Best-effort dominant color for a single node. Never throws; falls
    /// back to a content-derived hue when extraction can't complete.
    static func extract(for node: CanvasNode) async -> RGB {
        switch node.kind {
        case .image(let data, _):
            if let img = NSImage(data: data),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let rgb = dominantColor(from: cg) {
                return rgb
            }
            return fallback(for: node)

        case .video(let fileURL, _):
            return await dominantColorForVideo(at: fileURL) ?? fallback(for: node)

        case .drawing(let stroke):
            return RGB(r: stroke.color.red, g: stroke.color.green, b: stroke.color.blue)

        case .tweet(let url):
            return await dominantColorForTweet(url: url) ?? fallback(for: node)

        case .instagram(let url):
            return await dominantColorForInstagram(url: url) ?? fallback(for: node)

        case .youtube:
            // No cheap local pixels for an embed; seed a stable hue.
            return fallback(for: node)

        case .webclip:
            // No cheap local pixels for arbitrary websites; seed a stable hue.
            return fallback(for: node)

        case .text(let content, _):
            return fallback(seed: content.isEmpty ? node.id.uuidString : content)

        case .section(_, let color):
            let c = color.swiftUIColor
            return rgb(from: c, seed: node.id.uuidString)

        case .stickyNote(_, let color):
            let c = color.swiftUIColor
            return rgb(from: c, seed: node.id.uuidString)
        case .folder:
            return fallback(for: node)
        }
    }

    /// Convert a `SwiftUI.Color` to an `RGB`. Uses `NSColor` round-trip
    /// in sRGB so the values are stable across appearances; falls back
    /// to the seed-derived hue if conversion fails.
    private static func rgb(from color: Color, seed: String) -> RGB {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        guard let c = ns else { return fallback(seed: seed) }
        return RGB(r: Double(c.redComponent),
                   g: Double(c.greenComponent),
                   b: Double(c.blueComponent))
    }

    // MARK: - Video frame → average

    private static func dominantColorForVideo(at fileURL: URL) async -> RGB? {
        let asset = AVURLAsset(url: fileURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 256, height: 256)

        // Take a frame ~0.5s in (avoids fade-from-black intros).
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        return await Task.detached(priority: .utility) {
            do {
                let cg = try gen.copyCGImage(at: time, actualTime: nil)
                return dominantColor(from: cg)
            } catch {
                if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                    return dominantColor(from: cg)
                }
                return nil
            }
        }.value
    }

    // MARK: - Tweet poster → average

    private static func dominantColorForTweet(url: String) async -> RGB? {
        guard let id = TweetService.extractTweetID(from: url),
              let data = try? await TweetService.fetch(tweetID: id),
              let posterURL = data.posterURL else { return nil }
        return await averageColor(at: posterURL)
    }

    // MARK: - Instagram og:image → average

    /// Cap network waits so a flaky connection degrades to the hue-seed
    /// fallback in seconds, not URLSession's 60 s default per card.
    private static let requestTimeout: TimeInterval = 10

    private static func dominantColorForInstagram(url: String) async -> RGB? {
        guard let pageURL = URL(string: url) else { return nil }
        var req = URLRequest(url: pageURL, timeoutInterval: requestTimeout)
        // Instagram serves a leaner OG-tagged page to crawler User-Agents.
        req.setValue(
            "Mozilla/5.0 (compatible; facebookexternalhit/1.1; +http://www.facebook.com/externalhit_uatext.php)",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8),
              let og = ogImageURL(from: html) else { return nil }
        return await averageColor(at: og)
    }

    /// Compiled once — `ogImageURL` runs per node when warming Colorform.
    private static let ogImageRegexes: [NSRegularExpression] = [
        #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
        #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Parse `<meta property="og:image" content="...">` out of raw HTML.
    private static func ogImageURL(from html: String) -> URL? {
        for rx in ogImageRegexes {
            if let m = rx.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: html) {
                let raw = String(html[r])
                    .replacingOccurrences(of: "&amp;", with: "&")
                if let url = URL(string: raw) { return url }
            }
        }
        return nil
    }

    /// Fetch the image at `url`, decode it, and return its dominant color.
    private static func averageColor(at url: URL) async -> RGB? {
        guard let cg = await cgImage(at: url) else { return nil }
        return dominantColor(from: cg)
    }

    // MARK: - Representative image (for full palette extraction)

    /// The source image that best represents a node — local image data,
    /// tweet poster, Instagram og:image, YouTube thumbnail, or a video
    /// frame. Used by the lightbox palette extractor. `nil` for kinds with
    /// no image (text/sticky/drawing/section).
    static func representativeCGImage(for node: CanvasNode) async -> CGImage? {
        switch node.kind {
        case .image(let data, _):
            return NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        case .tweet(let url):
            guard let id = TweetService.extractTweetID(from: url),
                  let data = try? await TweetService.fetch(tweetID: id),
                  let posterURL = data.posterURL else { return nil }
            return await cgImage(at: posterURL)
        case .instagram(let url):
            guard let og = await instagramOGImageURL(url) else { return nil }
            return await cgImage(at: og)
        case .youtube(let url):
            guard let p = YouTubeService.posterURL(from: url) else { return nil }
            return await cgImage(at: p)
        case .video(let fileURL, _):
            return await videoFirstFrame(at: fileURL)
        default:
            return nil
        }
    }

    private static func cgImage(at url: URL) async -> CGImage? {
        let req = URLRequest(url: url, timeoutInterval: requestTimeout)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let img = NSImage(data: data) else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func instagramOGImageURL(_ url: String) async -> URL? {
        guard let pageURL = URL(string: url) else { return nil }
        var req = URLRequest(url: pageURL, timeoutInterval: requestTimeout)
        req.setValue(
            "Mozilla/5.0 (compatible; facebookexternalhit/1.1; +http://www.facebook.com/externalhit_uatext.php)",
            forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return ogImageURL(from: html)
    }

    private static func videoFirstFrame(at fileURL: URL) async -> CGImage? {
        let asset = AVURLAsset(url: fileURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 512, height: 512)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        return await Task.detached(priority: .utility) {
            (try? gen.copyCGImage(at: time, actualTime: nil))
                ?? (try? gen.copyCGImage(at: .zero, actualTime: nil))
        }.value
    }

    // MARK: - Dominant color (histogram-based)

    /// Saturation-weighted hue histogram. Much better than a plain
    /// `CIAreaAverage` for the typical "ink on white paper" or "logo on
    /// pastel background" case, where the average is dominated by the
    /// background and washes out to slate. Strategy:
    ///   1. Downsample to a 64×64 RGBA bitmap.
    ///   2. For every pixel:
    ///      - convert to HSV;
    ///      - skip near-grays (s<0.18), near-blacks (v<0.10) and
    ///        near-whites (v>0.95) — these are usually background;
    ///      - bin by hue (24 buckets), weight = s·v.
    ///   3. Return the weighted mean RGB of the heaviest bin.
    ///   4. If too few saturated pixels exist, fall back to the gray
    ///      pixels' mean — so a fully grayscale image still gets a sane
    ///      slate color and lands in the neutrals cluster.
    static func dominantColor(from cgImage: CGImage) -> RGB? {
        let side = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: side, height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let raw = ctx.data else { return nil }
        let pixels = raw.bindMemory(to: UInt8.self, capacity: side * side * 4)

        let bins = 24
        var binWeight = [Double](repeating: 0, count: bins)
        var binSumR = [Double](repeating: 0, count: bins)
        var binSumG = [Double](repeating: 0, count: bins)
        var binSumB = [Double](repeating: 0, count: bins)

        var usable = 0
        var grayR = 0.0, grayG = 0.0, grayB = 0.0, grayCount = 0

        for i in 0..<(side * side) {
            let off = i * 4
            let r = Double(pixels[off + 0]) / 255
            let g = Double(pixels[off + 1]) / 255
            let b = Double(pixels[off + 2]) / 255
            let (h, s, v) = RGB(r: r, g: g, b: b).hsv

            // Skip background-ish pixels for the hue histogram:
            //   • s < 0.18                    — gray / neutral
            //   • v < 0.10                    — near-black
            //   • s < 0.25 and v > 0.95       — near-white (desaturated bright)
            // Crucially we DO keep high-value vivid pixels — pure red,
            // green, blue all have v=1 and must not be filtered out.
            if s < 0.18 || v < 0.10 || (s < 0.25 && v > 0.95) {
                grayR += r; grayG += g; grayB += b; grayCount += 1
                continue
            }
            let bin = min(bins - 1, Int(h * Double(bins)))
            let w = s * v       // brighter & more saturated pixels dominate
            binWeight[bin] += w
            binSumR[bin]   += r * w
            binSumG[bin]   += g * w
            binSumB[bin]   += b * w
            usable += 1
        }

        // Enough vivid pixels? Return the heaviest bin's weighted mean.
        if usable >= 16 {
            var best = 0
            for j in 1..<bins where binWeight[j] > binWeight[best] { best = j }
            let w = binWeight[best]
            if w > 0 {
                return RGB(
                    r: binSumR[best] / w,
                    g: binSumG[best] / w,
                    b: binSumB[best] / w
                )
            }
        }
        // Pure gray image → return the gray average so it still clusters.
        if grayCount > 0 {
            let n = Double(grayCount)
            return RGB(r: grayR / n, g: grayG / n, b: grayB / n)
        }
        return nil
    }

    // MARK: - Fallback (stable hue from a seed)

    /// Hash any string into a stable hue and return a saturated RGB. Used
    /// for text nodes (no visual color) and for any extraction that fails
    /// (offline tweets, dead Instagram embeds, unreadable images).
    private static func fallback(for node: CanvasNode) -> RGB {
        switch node.kind {
        case .text(let content, _): return fallback(seed: content.isEmpty ? node.id.uuidString : content)
        case .tweet(let url):       return fallback(seed: url)
        case .instagram(let url):   return fallback(seed: url)
        default:                    return fallback(seed: node.id.uuidString)
        }
    }

    /// Pure FNV-1a-style hash → hue in [0,1]. Deterministic and seedless.
    static func fallback(seed: String) -> RGB {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let hue = Double(hash % 10_000) / 10_000
        return RGB.fromHue(hue)
    }
}
