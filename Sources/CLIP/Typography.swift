import SwiftUI

/// App typography — the technical monospace look from the references, set in
/// **SF Mono** (Apple's system monospaced face, reached via SwiftUI's
/// `design: .monospaced`). Using the system mono means no font files to bundle
/// or register, and it tracks the user's Dynamic Type / weight settings.
extension Font {
    /// SF Mono at `size`. `heavy` selects a bold cut for emphasis (the
    /// references lean on uppercase + tracking more than a weight ramp).
    static func clip(_ size: CGFloat, _ heavy: Bool = false) -> Font {
        .system(size: size, weight: heavy ? .bold : .regular, design: .monospaced)
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
