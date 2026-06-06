import SwiftUI
import AppKit

/// Four square corner handles on the selected card — Stitch / Figma
/// style. Each handle resizes the node from its own corner, keeping the
/// diagonally-opposite corner pinned; holding Shift locks the aspect
/// ratio. The whole gesture collapses into one undo entry via
/// `activeResizeUndoSnapshot`.
struct ResizeHandles: View {
    @EnvironmentObject var state: CanvasState
    let node: CanvasNode
    /// Current rendered size in WORLD units (the parent applies a global
    /// `.scaleEffect(zoom)`, so handle sizes are divided back through the
    /// zoom to stay a constant size on screen).
    let renderedSize: CGSize

    /// Visible square edge, in SCREEN points.
    private let handleScreenSize: CGFloat = 8
    /// Grab-area edge, in SCREEN points — larger than the visible square
    /// so the small handles stay easy to hit.
    private let hitScreenSize: CGFloat = 22

    /// One of the four resizable corners.
    private enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading:     return .topLeading
            case .topTrailing:    return .topTrailing
            case .bottomLeading:  return .bottomLeading
            case .bottomTrailing: return .bottomTrailing
            }
        }
        /// Whether dragging this corner moves the node's left / top edge
        /// (the opposite edge stays pinned).
        var movesLeft: Bool { self == .topLeading || self == .bottomLeading }
        var movesTop:  Bool { self == .topLeading || self == .topTrailing }

        /// Shift a corner-aligned box outward so its centre — not its
        /// edge — sits exactly on the card corner.
        func centerOffset(half: CGFloat) -> CGSize {
            CGSize(width: movesLeft ? -half : half,
                   height: movesTop ? -half : half)
        }
    }

    /// Reciprocal of the active zoom — multiplies screen-space sizes into
    /// the world space this view renders in. Clamped so a zoom of 0 can't
    /// NaN anything.
    private var invZoom: CGFloat {
        let z = state.camera.zoom
        return z > 0.0001 ? 1 / z : 1
    }

    var body: some View {
        ZStack {
            handle(.topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            handle(.topTrailing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            handle(.bottomLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            handle(.bottomTrailing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(width: renderedSize.width, height: renderedSize.height)
    }

    // MARK: - Handle view

    private func handle(_ corner: Corner) -> some View {
        let visual = handleScreenSize * invZoom
        let hit = hitScreenSize * invZoom
        let radius = visual * 0.22
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: invZoom)
            )
            .shadow(color: .black.opacity(0.18), radius: invZoom, y: 0.5 * invZoom)
            .frame(width: visual, height: visual)
            // A larger transparent box around the square widens the grab
            // target without enlarging the visible handle.
            .frame(width: hit, height: hit)
            .contentShape(Rectangle())
            .offset(corner.centerOffset(half: hit / 2))
            .gesture(dragGesture(corner))
            .onHover { hovering in
                if hovering { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
    }

    // MARK: - Drag math

    private func dragGesture(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in applyResize(corner: corner, translation: value.translation) }
            .onEnded { _ in
                if let snap = state.activeResizeUndoSnapshot {
                    state.commitUndoable(from: snap)
                }
                state.activeResizeStart = nil
                state.activeResizeUndoSnapshot = nil
            }
    }

    /// Resize `node` so the dragged `corner` follows the cursor while the
    /// diagonally-opposite corner stays pinned.
    private func applyResize(corner: Corner, translation: CGSize) {
        if state.activeResizeStart == nil {
            state.activeResizeStart = CGRect(
                x: node.position.x,
                y: node.position.y,
                width: node.width,
                height: state.renderedHeight(of: node)
            )
            state.activeResizeUndoSnapshot = state.snapshotForUndo()
        }
        guard let start = state.activeResizeStart else { return }
        let zoom = state.camera.zoom
        let dx = translation.width / zoom
        let dy = translation.height / zoom

        // New size as the dragged corner moves.
        var w = start.width  + (corner.movesLeft ? -dx : dx)
        var h = start.height + (corner.movesTop  ? -dy : dy)

        // Shift = lock the aspect ratio.
        if NSEvent.modifierFlags.contains(.shift), start.height > 0 {
            let aspect = start.width / start.height
            if abs(dx) > abs(dy) { h = w / aspect } else { w = h * aspect }
        }

        // Clamp before re-anchoring so the pinned corner never drifts
        // when the node bottoms out at its minimum size.
        let minSize = node.kind.minSize
        w = max(minSize.width, w)
        h = max(minSize.height, h)

        // Re-anchor on the pinned (opposite) corner.
        let originX = corner.movesLeft ? (start.maxX - w) : start.minX
        let originY = corner.movesTop  ? (start.maxY - h) : start.minY

        state.resize(id: node.id,
                     frame: CGRect(x: originX, y: originY, width: w, height: h))
    }
}
