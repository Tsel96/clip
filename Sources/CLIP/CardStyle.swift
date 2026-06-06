import SwiftUI

/// Shared card chrome — matches the user's Figma card spec
/// (node `1:2` / `1:6` in file `AtmCe01BA9SfMx1m0BlvcY`):
///   • 19.375pt continuous corner radius
///   • Thin border using the system label color
///   • Inset highlight at top, shadow at bottom (the embossed look)
///   • Hover-only multi-layer elevation shadow
///
/// All chromatic values use semantic colors (Color.primary, etc.) so the
/// card adapts to light and dark mode automatically.
struct FigmaCardStyle: ViewModifier {
    var cornerRadius: CGFloat = 19.375
    var isElevated: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .clipShape(shape)
            .overlay(
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.12 : 0.25),
                            Color.clear,
                            Color.clear,
                            Color.black.opacity(colorScheme == .dark ? 0.35 : 0.15)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            )
            .overlay(
                shape.strokeBorder(Color.primary.opacity(0.4), lineWidth: 0.5)
            )
            // Hover elevation — multi-layer drop shadow matching the
            // `Card_Hovered` Figma frame.
            .shadow(color: .black.opacity(isElevated ? 0.10 : 0), radius: 1.5, x: 0, y: 1)
            .shadow(color: .black.opacity(isElevated ? 0.09 : 0), radius: 3,   x: 0, y: 6)
            .shadow(color: .black.opacity(isElevated ? 0.05 : 0), radius: 4,   x: 0, y: 13)
            .shadow(color: .black.opacity(isElevated ? 0.01 : 0), radius: 4.5, x: 0, y: 23)
            .animation(.easeOut(duration: 0.15), value: isElevated)
    }
}

extension View {
    func figmaCardStyle(cornerRadius: CGFloat = 19.375, isElevated: Bool = false) -> some View {
        modifier(FigmaCardStyle(cornerRadius: cornerRadius, isElevated: isElevated))
    }
}
