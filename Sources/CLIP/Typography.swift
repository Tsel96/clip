import SwiftUI
import CoreText

/// App typography — the technical monospace look from the references, set in
/// **ONY Semimono Beta** (installed in ~/Library/Fonts). The family ships only
/// two weights (Regular + Black), so emphasis is carried by the Black cut plus
/// uppercase + letter-tracking rather than a weight ramp.
enum ClipFont {
    static let regular = "ONYSemimonoBeta-Regular"
    static let black   = "ONYSemimonoBeta-Black"

    /// Register the font files into the process so `Font.custom` resolves them.
    /// SwiftUI does NOT reliably pick up user-installed (~/Library/Fonts) fonts
    /// by name otherwise — it silently falls back to the system font. Call once
    /// at launch. Bundled copies (in `AppIcon/Fonts`) are preferred; the
    /// ~/Library/Fonts originals are the fallback.
    static func register() {
        let fm = FileManager.default
        var urls: [URL] = []
        // Prefer fonts bundled next to the executable (portable).
        if let resDir = Bundle.main.resourceURL {
            for f in ["ONYSemimonoBeta-Regular.otf", "ONYSemimonoBeta-Black.otf"] {
                let u = resDir.appendingPathComponent("Fonts/\(f)")
                if fm.fileExists(atPath: u.path) { urls.append(u) }
            }
        }
        // Fallback: the user's installed copies.
        if urls.isEmpty {
            let home = fm.homeDirectoryForCurrentUser
            for f in ["ONYSemimonoBeta-Regular.otf", "ONYSemimonoBeta-Black.otf"] {
                let u = home.appendingPathComponent("Library/Fonts/\(f)")
                if fm.fileExists(atPath: u.path) { urls.append(u) }
            }
        }
        for u in urls {
            CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
        }
    }
}

extension Font {
    /// ONY Semimono at `size`. `heavy` selects the Black cut.
    static func clip(_ size: CGFloat, _ heavy: Bool = false) -> Font {
        .custom(heavy ? ClipFont.black : ClipFont.regular, size: size, relativeTo: .body)
    }
}

extension View {
    /// A technical UI label: ONY Semimono, UPPERCASE, tracked — used for
    /// section headers and control captions ("PAGES", "CANVAS", "64 %").
    func clipLabel(_ size: CGFloat = 11, heavy: Bool = false, tracking: CGFloat = 1.3) -> some View {
        self.font(.clip(size, heavy))
            .textCase(.uppercase)
            .tracking(tracking)
    }

    /// ONY Semimono without forcing case/tracking — for values, fields, body.
    func clipText(_ size: CGFloat = 13, heavy: Bool = false) -> some View {
        self.font(.clip(size, heavy))
    }
}
