import SwiftUI
import AppKit

/// Four Figma / Spatial-style corner handles drawn on the selected card.
///
/// This view is now **purely visual**. The resize *gesture* is handled
/// natively by the collection item (`CardItemView`) — SwiftUI gestures inside
/// an `NSCollectionView` item receive a frozen start coordinate (always ~(6,4)
/// regardless of where you click), so they can't tell which corner you grabbed.
/// AppKit mouse events in the item get correct coordinates, so resize lives
/// there; this layer just paints the handles.
struct ResizeHandles: View {
    @EnvironmentObject var state: CanvasState
    let node: CanvasNode
    /// Rendered size in WORLD units. Handle sizes are divided back through the
    /// zoom so they stay a constant size on screen.
    let renderedSize: CGSize
    /// On the native canvas the card lives in an item view clipped to its
    /// bounds, so handles sit fully inside the corners; on the legacy SwiftUI
    /// canvas they straddle the corner.
    var insetHandles: Bool = false

    /// Visible square edge, in SCREEN points (Figma's handles are ~9 pt).
    private let handleScreenSize: CGFloat = 9

    private var invZoom: CGFloat {
        let z = state.camera.zoom
        return z > 0.0001 ? 1 / z : 1
    }
    private var visualSize: CGFloat { handleScreenSize * invZoom }

    var body: some View {
        ZStack {
            square.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(insetHandles ? .zero : CGSize(width: -visualSize / 2, height: -visualSize / 2))
            square.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(insetHandles ? .zero : CGSize(width: visualSize / 2, height: -visualSize / 2))
            square.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .offset(insetHandles ? .zero : CGSize(width: -visualSize / 2, height: visualSize / 2))
            square.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(insetHandles ? .zero : CGSize(width: visualSize / 2, height: visualSize / 2))
        }
        .frame(width: renderedSize.width, height: renderedSize.height)
        // The native `CardItemView` owns resize hit-testing — never intercept.
        .allowsHitTesting(false)
    }

    /// One handle: a small white square with a 1 px accent border, slightly
    /// rounded, with a soft shadow so it reads on both light and dark media.
    private var square: some View {
        let radius = visualSize * 0.18
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white)
            // Neutral hairline edge (not accent-blue) so the square reads as a
            // clean white handle, matching the white selection glow.
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.18), lineWidth: invZoom)
            )
            .shadow(color: .black.opacity(0.28), radius: 1.5 * invZoom, y: 0.5 * invZoom)
            .frame(width: visualSize, height: visualSize)
    }
}
