import AppKit

// The ONE hex helper. Two private per-file copies used to exist with
// DIFFERENT color spaces (calibratedRed vs srgbRed), so the same literal
// could render two slightly different swatches on a color-managed display.
// sRGB is the correct space — every design value in the app is authored
// as sRGB hex from Figma.
extension NSColor {
    /// Initialise from a 0xRRGGBB integer literal, sRGB colour space.
    static func fromHex(_ hex: UInt32) -> NSColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >>  8) & 0xFF) / 255
        let b = CGFloat( hex        & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// `#RRGGBB` (sRGB) — inverse of `fromHex`; used to persist tints.
    var hexRGB: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
