import SwiftUI

/// Resizable minimap view. Shape & background are owned by whatever wraps it
/// (in-window: `LiquidGlassMinimap`; detached: `NSPanel` from `MinimapWindowController`).
///
///   • Renders every node as a small rectangle (selected = accent).
///   • Renders the current viewport as a dashed accent rectangle.
///   • Click / drag to move the camera to that location.
struct MinimapView: View {
    @EnvironmentObject var state: CanvasState
    /// Observed only so the viewport box re-renders on pan/zoom —
    /// `visibleWorldRect` derives from the camera.
    @EnvironmentObject var cameraStore: CameraStore

    /// Padding between the projected content and the view edge. The default
    /// suits a rectangular host; circular hosts (the glass lens) pass a
    /// larger value so nothing drowns in the curved rim.
    var inset: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            Canvas { context, _ in
                draw(in: context, canvasSize: geo.size)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in navigate(to: value.location, canvasSize: geo.size) }
            )
        }
        .help("Click to jump  ·  Drag to pan")
    }

    // MARK: - Drawing

    private func draw(in ctx: GraphicsContext, canvasSize: CGSize) {
        let projection = makeProjection(canvasSize: canvasSize)

        // Subtle dot grid.
        let gridSize: CGFloat = 60
        let bounds = projection.bounds
        var gx = (bounds.minX / gridSize).rounded(.down) * gridSize
        let dotColor = Color(nsColor: .quaternaryLabelColor)
        while gx < bounds.maxX {
            var gy = (bounds.minY / gridSize).rounded(.down) * gridSize
            while gy < bounds.maxY {
                let p = projection.project(CGPoint(x: gx, y: gy))
                let r = CGRect(x: p.x - 0.5, y: p.y - 0.5, width: 1, height: 1)
                ctx.fill(Path(ellipseIn: r), with: .color(dotColor))
                gy += gridSize
            }
            gx += gridSize
        }

        // Nodes — drawn in their own layer so the per-card soft shadow
        // (the "scattered cards" look) never leaks onto the grid or the
        // viewport box.
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(
                color: .black.opacity(0.15), radius: 3, x: 0, y: 1.5
            ))
            for node in state.nodes {
                let origin = projection.project(node.position)
                let w = max(2, node.width  * projection.scale)
                let h = max(2, (node.height ?? state.renderedHeight(of: node)) * projection.scale)
                let rect = CGRect(x: origin.x, y: origin.y, width: w, height: h)
                let isSel = state.selectedNodeIDs.contains(node.id)

                // Sections span large areas — a filled block would read as
                // a giant grey slab over the map. Hairline outline instead.
                if case .section(_, let color) = node.kind {
                    layer.stroke(
                        Path(roundedRect: rect, cornerSize: CGSize(width: 3, height: 3)),
                        with: .color(color.swiftUIColor.opacity(isSel ? 0.8 : 0.45)),
                        style: StrokeStyle(lineWidth: 1)
                    )
                    continue
                }

                let fill: Color
                switch node.kind {
                case .tweet:
                    fill = isSel ? .accentColor : Color(nsColor: .controlAccentColor).opacity(0.5)
                case .instagram:
                    // Instagram brand-ish pink/orange so it's visually distinct.
                    fill = isSel
                        ? Color(red: 0.91, green: 0.21, blue: 0.45)
                        : Color(red: 0.91, green: 0.21, blue: 0.45).opacity(0.55)
                case .text:
                    fill = isSel ? .accentColor : .secondary.opacity(0.7)
                case .drawing(let s):
                    fill = s.color.swiftUIColor.opacity(isSel ? 1 : 0.7)
                case .image:
                    fill = isSel ? .green : Color.green.opacity(0.55)
                case .video:
                    fill = isSel ? .orange : Color.orange.opacity(0.6)
                case .youtube:
                    // YouTube red so it reads as distinct from local video.
                    fill = isSel
                        ? Color(red: 1.0, green: 0.0, blue: 0.0)
                        : Color(red: 1.0, green: 0.0, blue: 0.0).opacity(0.6)
                case .section(_, let color):
                    fill = color.swiftUIColor.opacity(isSel ? 0.7 : 0.35)
                case .stickyNote(_, let color):
                    fill = color.swiftUIColor.opacity(isSel ? 1 : 0.85)
                }
                let r = min(4, w * 0.18, h * 0.18)
                layer.fill(
                    Path(roundedRect: rect, cornerSize: CGSize(width: r, height: r)),
                    with: .color(fill)
                )
            }
        }

        // Viewport rectangle.
        let vp = state.visibleWorldRect
        let topLeft = projection.project(CGPoint(x: vp.minX, y: vp.minY))
        let vw = vp.width  * projection.scale
        let vh = vp.height * projection.scale
        let vRect = CGRect(x: topLeft.x, y: topLeft.y, width: vw, height: vh)

        // Reference style: a thin neutral dashed outline, no fill.
        ctx.stroke(
            Path(roundedRect: vRect, cornerSize: CGSize(width: 2, height: 2)),
            with: .color(.gray.opacity(0.9)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )
    }

    // MARK: - Projection

    private struct Projection {
        let scale: CGFloat
        let offset: CGPoint
        let bounds: CGRect

        func project(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
        }

        func unproject(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
        }
    }

    private func makeProjection(canvasSize: CGSize) -> Projection {
        let bounds = computeBounds()
        let innerW = max(1, canvasSize.width  - inset * 2)
        let innerH = max(1, canvasSize.height - inset * 2)
        let s = max(0.0001, min(innerW / bounds.width, innerH / bounds.height))
        let offset = CGPoint(
            x: (canvasSize.width  - bounds.width  * s) / 2 - bounds.minX * s,
            y: (canvasSize.height - bounds.height * s) / 2 - bounds.minY * s
        )
        return Projection(scale: s, offset: offset, bounds: bounds)
    }

    private func computeBounds() -> CGRect {
        var minX: CGFloat = -500, minY: CGFloat = -500
        var maxX: CGFloat =  500, maxY: CGFloat =  500
        if let first = state.nodes.first {
            minX = first.position.x
            minY = first.position.y
            maxX = first.position.x + first.width
            maxY = first.position.y + (first.height ?? 200)
            for n in state.nodes.dropFirst() {
                minX = min(minX, n.position.x)
                minY = min(minY, n.position.y)
                maxX = max(maxX, n.position.x + n.width)
                maxY = max(maxY, n.position.y + (n.height ?? 200))
            }
        }
        let vp = state.visibleWorldRect
        minX = min(minX, vp.minX); minY = min(minY, vp.minY)
        maxX = max(maxX, vp.maxX); maxY = max(maxY, vp.maxY)

        // Generous padding so the dashed viewport box always floats with a
        // clear offset from the map's edge instead of hugging it.
        let pX = (maxX - minX) * 0.26
        let pY = (maxY - minY) * 0.26
        return CGRect(x: minX - pX, y: minY - pY,
                      width:  max(1, maxX - minX + pX * 2),
                      height: max(1, maxY - minY + pY * 2))
    }

    private func navigate(to point: CGPoint, canvasSize: CGSize) {
        let world = makeProjection(canvasSize: canvasSize).unproject(point)
        state.centerCamera(on: world)
    }
}
