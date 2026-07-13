import SwiftUI
import AppKit

/// Shared green-outer / yellow-inner pill style for the sticky bars (Figma
/// 104:651 / 104:593) — the same toolbar family as the bottom tool palette.
// (StickyBarStyle / stickyActionBar modifier / StickyActionBar /
// StickyTextEditBar deleted: zero references — the contextual-toolbar
// experiment they served was removed from CanvasView long ago.
// StickyExportView below IS live: the sticky→PNG export renders it.)

private extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

/// Minimal sticky rendering used only for PNG export (Download).
struct StickyExportView: View {
    let content: String
    let color: StickyColor
    var body: some View {
        Text(content)
            .font(.system(size: 16, weight: .medium, design: .rounded))
            .foregroundStyle(.black.opacity(0.85))
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: color.nsColor))
    }
}
