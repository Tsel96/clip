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
    var cornerRadius: CGFloat = 1     // cards are square (Figma 88:329)
    var isElevated: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .clipShape(shape)
            // Spatial-style chrome: just the clipped media + a clean hairline
            // edge so the card reads against a same-colored backdrop. The float
            // shadow lives on the native item's CALayer (`CardItemView`) so it
            // isn't clipped by the collection item — a SwiftUI `.shadow` here
            // would be cut off at the card's bounds.
            .overlay(
                // 0.5px inside hairline at 15% so the card edge reads against the
                // light canvas (matches the native media-card hairline).
                shape.strokeBorder(
                    Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.15),
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
            )
            // `isElevated` was a declared-but-unread parameter (every call site
            // threaded a live hover flag into it for nothing). Wherever
            // `DraggableNode` is the sole chrome provider (FolderGridView's grid,
            // the lightbox) this is the ONLY hover shadow those cards get; where
            // `DraggableNode` also wraps the card, its own hover shadow (see
            // `DraggableNode.swift`) stacks on top, per that view's doc comment.
            // `CardItemView`'s NSCollectionView path never sets `isElevated` and
            // draws its own CALayer shadow instead, so it's unaffected.
            .shadow(color: .black.opacity(isElevated ? 0.16 : 0),
                    radius: isElevated ? 14 : 0,
                    y: isElevated ? 8 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isElevated)
    }
}

extension View {
    func figmaCardStyle(cornerRadius: CGFloat = 1, isElevated: Bool = false) -> some View {
        modifier(FigmaCardStyle(cornerRadius: cornerRadius, isElevated: isElevated))
    }
}
