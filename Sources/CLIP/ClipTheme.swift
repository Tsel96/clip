import AppKit
import SwiftUI

/// Which appearance the app paints in. `.system` follows macOS; `.light` /
/// `.dark` force it (the references want a hand-tuned near-black, not the OS
/// default gray, so we drive the palette ourselves rather than relying only
/// on semantic colors).
enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    /// SwiftUI override; `nil` means "follow the system".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }
}

/// Resolved color tokens for one appearance. Read via `@Environment(\.clipTheme)`.
/// The Arrival-style references are monochrome surfaces + a single accent, so
/// the token set is deliberately small: a few surface tiers, three text tiers,
/// a hairline, and the brand accent (the icon's yellow).
struct ClipTheme {
    var canvas: Color            // infinite-canvas backdrop
    var surface: Color           // panels / sidebar / chrome
    var surfaceElevated: Color   // pills, hovered controls
    var surfaceInset: Color      // input fields, segmented track
    var fill: Color              // filled portion of a slider-field / selected segment
    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color
    var border: Color            // hairline separators / strokes
    var accent: Color            // brand yellow (matches the app icon)
    var accentOnSurface: Color   // same hue, tuned for a glyph drawn directly on a surface
    var shadow: Color            // soft panel drop shadow
    var isDark: Bool

    /// The tool-palette's candy-yellow gradient stops (Figma 60:12983 — also
    /// hand-rolled independently in `CanvasTopSegmentedControlView`'s indicator
    /// pill). Shared here so `accentYellow` below samples the SAME hue instead
    /// of an independently-picked one (was ~12° apart).
    static let candyYellowRim    = Color(red: 1.00, green: 0.988, blue: 0.663)  // #FFFCA9
    static let candyYellowTop    = Color(red: 1.00, green: 0.961, blue: 0.231)  // #FFF53B
    static let candyYellowBottom = Color(red: 0.973, green: 0.871, blue: 0.278) // #F8DE47
    /// AppKit mirrors of the candy stops for the CALayer-gradient chrome
    /// (`CanvasToolPalette`) — same single source, explicit sRGB so the
    /// layer gradients match the SwiftUI side on color-managed displays.
    static let candyYellowRimNS    = NSColor(srgbRed: 1.00, green: 0.988, blue: 0.663, alpha: 1)
    static let candyYellowTopNS    = NSColor(srgbRed: 1.00, green: 0.961, blue: 0.231, alpha: 1)
    static let candyYellowBottomNS = NSColor(srgbRed: 0.973, green: 0.871, blue: 0.278, alpha: 1)

    /// Brand yellow — sampled from the candy palette's body-bottom stop so the
    /// icon accent and the toolbar's candy pill read as one brand yellow.
    static let accentYellow = candyYellowBottom
    /// Same hue as `accentYellow`, lightness lowered for icon glyphs painted
    /// DIRECTLY on a light surface (icon chips, buttons): `accentYellow` alone
    /// is only ~0.05 lighter than `surfaceInset`/`surfaceElevated` in light mode
    /// (~1.3:1, far under WCAG AA) so a plain `foregroundStyle(accent)` icon
    /// nearly vanishes there.
    static let accentDeep = Color(red: 0.44, green: 0.39, blue: 0.13)

    static let light = ClipTheme(
        canvas:          Color(white: 0.95),
        surface:         Color(white: 1.0),
        surfaceElevated: Color(white: 0.97),
        surfaceInset:    Color(white: 0.91),
        fill:            Color(white: 0.84),
        textPrimary:     Color(white: 0.07),
        textSecondary:   Color(white: 0.07).opacity(0.55),
        // WCAG: opacity 0.35 composited over `surface` (white) computed to
        // ~2.3:1, under the 3:1 floor even for large text. Raised toward the
        // 4.5:1 regular-text floor — still the most muted of the three tiers.
        textTertiary:    Color(white: 0.07).opacity(0.55),
        border:          Color.black.opacity(0.10),
        accent:          accentYellow,
        accentOnSurface: accentDeep,
        shadow:          Color.black.opacity(0.12),
        isDark:          false
    )

    static let dark = ClipTheme(
        canvas:          Color(white: 0.07),
        surface:         Color(white: 0.11),
        surfaceElevated: Color(white: 0.16),
        surfaceInset:    Color(white: 0.17),
        fill:            Color(white: 0.27),
        textPrimary:     Color(white: 0.95),
        textSecondary:   Color(white: 0.95).opacity(0.62),
        // Same AA-floor reasoning as `light` above (was 0.40 / ~3.5:1).
        textTertiary:    Color(white: 0.95).opacity(0.55),
        border:          Color.white.opacity(0.12),
        accent:          accentYellow,
        // A light accent already contrasts fine against the dark surfaces —
        // no separate darkened tone needed here.
        accentOnSurface: accentYellow,
        shadow:          Color.black.opacity(0.50),
        isDark:          true
    )

    static func resolve(_ scheme: ColorScheme) -> ClipTheme {
        scheme == .dark ? .dark : .light
    }
}

private struct ClipThemeKey: EnvironmentKey {
    static let defaultValue: ClipTheme = .dark
}

extension EnvironmentValues {
    var clipTheme: ClipTheme {
        get { self[ClipThemeKey.self] }
        set { self[ClipThemeKey.self] = newValue }
    }
}
