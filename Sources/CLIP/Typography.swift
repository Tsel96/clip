import SwiftUI

/// App typography — the technical monospace look from the references, set in
/// **SF Mono** (Apple's system monospaced face, reached via SwiftUI's
/// `design: .monospaced`). Using the system mono means no font files to bundle
/// or register, and it tracks the user's Dynamic Type / weight settings.
enum ClipFont {
    /// Kept as a no-op so existing launch code (`ClipApp.init`) still compiles.
    /// SF Mono is a system face, so there is nothing to register.
    static func register() {}
}

extension Font {
    /// Smallest text size the UI chrome renders. 9–10.5 pt SF Mono captions
    /// were hard to read for low-vision users (macOS has no Dynamic Type for
    /// custom sizes), so every `.clip` size is floored here in one place.
    static let clipMinimumSize: CGFloat = 11

    /// SF Mono at `size` (never below `clipMinimumSize`). `heavy` selects a
    /// bold cut for emphasis (the references lean on uppercase + tracking
    /// more than a weight ramp).
    static func clip(_ size: CGFloat, _ heavy: Bool = false) -> Font {
        .system(size: max(size, clipMinimumSize), weight: heavy ? .bold : .regular, design: .monospaced)
    }
}

extension View {
    /// A technical UI label: SF Mono, UPPERCASE, tracked — used for section
    /// headers and control captions ("PAGES", "CANVAS", "64 %").
    func clipLabel(_ size: CGFloat = 11, heavy: Bool = false, tracking: CGFloat = 1.3) -> some View {
        self.font(.clip(size, heavy))
            .textCase(.uppercase)
            .tracking(tracking)
    }

    /// SF Mono without forcing case/tracking — for values, fields, body.
    func clipText(_ size: CGFloat = 13, heavy: Bool = false) -> some View {
        self.font(.clip(size, heavy))
    }
}
