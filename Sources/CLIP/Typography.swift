import SwiftUI

/// App typography — the technical monospace look from the references, set in
/// **SF Mono** (Apple's system monospaced face, reached via SwiftUI's
/// `design: .monospaced`). Using the system mono means no font files to bundle
/// or register, and it tracks the user's Dynamic Type / weight settings.
///
/// In practice the app reads as three type voices, not strictly one, and none
/// of the other two route through this file:
///   1. **SF Mono** (`Font.clip` / `.clipLabel` / `.clipText`, here) — the
///      house voice: chrome, technical labels, section headers, captions.
///   2. **SF Pro Rounded** (`design: .rounded`, hand-rolled per call site,
///      e.g. `SectionNodeView`, `StackVisualView`) — card/badge metadata chrome.
///   3. **Plain SF Pro** (default `design`, e.g. `ArchiveListView`) — list/body text.
/// This isn't a documented, deliberate 3-voice system (each call site picked
/// its own ad hoc size/weight/design) — it's recorded here so a future pass
/// either formalizes 2–3 named voices as cases in this file, or folds the
/// rounded/plain call sites into the mono scale. Not reflowed app-wide here;
/// this file only fixes the *documentation* gap, not the ~75 call sites.
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
