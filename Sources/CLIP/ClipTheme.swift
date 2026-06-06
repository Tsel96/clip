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
    var shadow: Color            // soft panel drop shadow
    var isDark: Bool

    /// Brand yellow, sampled from the icon glyph.
    static let accentYellow = Color(red: 0.96, green: 0.80, blue: 0.13)

    static let light = ClipTheme(
        canvas:          Color(white: 0.95),
        surface:         Color(white: 1.0),
        surfaceElevated: Color(white: 0.97),
        surfaceInset:    Color(white: 0.91),
        fill:            Color(white: 0.84),
        textPrimary:     Color(white: 0.07),
        textSecondary:   Color(white: 0.07).opacity(0.55),
        textTertiary:    Color(white: 0.07).opacity(0.35),
        border:          Color.black.opacity(0.10),
        accent:          accentYellow,
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
        textTertiary:    Color(white: 0.95).opacity(0.40),
        border:          Color.white.opacity(0.12),
        accent:          accentYellow,
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
