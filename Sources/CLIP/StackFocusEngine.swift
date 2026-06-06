import Foundation
import CoreGraphics

/// Layout engine for the card-stack focus mode (double-click a stack →
/// members fan out into a beautiful grid).
///
/// `StackFocusEngine` delegates the heavy cardinality-aware grid math to
/// the existing `ArchiveEngine.bentoLayout(…)` (which already produces
/// "1 = hero / 2 = side-by-side / 3 = hero+stack / 4 = 2×2 / 5+ = 3-col
/// masonry" arrangements). The only thing this layer adds is a
/// focus-mode-specific **natural-size policy** so that mixed-kind decks
/// land in the grid beautifully:
///
///   • Text + sticky notes capped at 320×240 — otherwise a multi-line
///     text frame can dominate the grid even when the user's intent is
///     to browse adjacent images.
///   • Sections cap the same way — they're container chrome, not
///     content, so they shouldn't claim hero status.
///   • Images, videos, tweets, Instagram, drawings keep their native
///     `(width, height)` so aspect ratios are preserved in the grid.
///
/// Returns the bento engine's `(positions, sizes)` tuple unchanged —
/// callers write it directly into `CanvasState.focusPositions` /
/// `focusSizes`.
@MainActor
enum StackFocusEngine {

    /// Maximum natural size for kinds that shouldn't dominate the grid
    /// (text frames, sticky notes, section containers). Picked so a
    /// 320×240 text card fits comfortably alongside a 480×270 video.
    private static let textCap = CGSize(width: 320, height: 240)

    /// Build a focus-mode grid layout for the supplied stack members.
    /// `@MainActor` because it reads `CanvasState` (also main-actor
    /// isolated) for per-node `renderedHeight` + `nodeByID` lookups.
    ///
    /// - Parameters:
    ///   - memberIDs: full member list of the stack, including the head.
    ///   - state: the canvas state — used to look up each member's
    ///     `CanvasNode` (for kind + natural width/height).
    ///   - viewportSize: current canvas-view size (already the world
    ///     space we render into, since focus mode resets the camera
    ///     to `(0, 0, 1.0)` before the layout is computed).
    /// - Returns: per-member target position + size for the focus grid.
    static func layout(
        memberIDs: [UUID],
        state: CanvasState,
        viewportSize: CGSize
    ) -> (positions: [UUID: CGPoint], sizes: [UUID: CGSize]) {
        // Build the natural-size map with the focus-mode policy.
        var naturalSizes: [UUID: CGSize] = [:]
        for id in memberIDs {
            guard let node = state.nodeByID[id] else { continue }
            naturalSizes[id] = naturalSize(for: node, state: state)
        }
        // Delegate to the existing bento engine — it does the heavy
        // arrangement math (cardinality-aware grid + shortest-column
        // packing for 5+).
        return ArchiveEngine.bentoLayout(
            cardIDs: memberIDs,
            naturalSizes: naturalSizes,
            viewportSize: viewportSize
        )
    }

    /// Focus-mode natural size for a single node. Text-like kinds are
    /// capped (so they don't dominate the grid); media kinds preserve
    /// their canvas aspect ratio so the bento engine can compose them
    /// without distortion.
    private static func naturalSize(for node: CanvasNode, state: CanvasState) -> CGSize {
        let rawHeight = state.renderedHeight(of: node)
        let raw = CGSize(width: node.width, height: rawHeight)
        switch node.kind {
        case .text, .stickyNote, .section:
            return CGSize(
                width:  min(raw.width,  textCap.width),
                height: min(raw.height, textCap.height)
            )
        case .image, .video, .tweet, .instagram, .youtube, .drawing:
            return raw
        }
    }
}
