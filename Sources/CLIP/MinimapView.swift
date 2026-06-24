import SwiftUI
import AppKit
import ImageIO

/// Tiny downsampled previews for minimap cards, so the lens shows real
/// thumbnails like the reference artwork instead of colored blocks.
/// Images decode off the main thread once per node and cache; `version`
/// bumps so the hosting Canvas re-renders as thumbs land. Video posters
/// come from the existing process-wide `VideoPosterStore` (pre-warmed at
/// launch).
@MainActor
final class MinimapThumbs: ObservableObject {
    static let shared = MinimapThumbs()

    @Published private(set) var version = 0
    private var thumbs: [UUID: NSImage] = [:]
    private var inFlight: Set<UUID> = []

    func thumbnail(for node: CanvasNode) -> NSImage? {
        switch node.kind {
        case .image(let data, _):
            if let hit = thumbs[node.id] { return hit }
            decode(id: node.id, data: data)
            return nil
        case .video(let fileURL, _):
            return VideoPosterStore.cachedPoster(for: fileURL)
        case .tweet, .instagram, .youtube:
            // Web embeds: poster fetched once via the same pipeline the
            // Colorform palette extractor uses, then cached here.
            if let hit = thumbs[node.id] { return hit }
            fetchPoster(for: node)
            return nil
        default:
            return nil
        }
    }

    private func decode(id: UUID, data: Data) {
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        Task.detached(priority: .utility) {
            let thumb = Self.downsample(data, maxSide: 200)
            await MainActor.run {
                if let thumb { self.thumbs[id] = thumb }
                self.inFlight.remove(id)
                self.version &+= 1
            }
        }
    }

    /// Network poster for tweet / Instagram / YouTube cards. Failures stay
    /// in `inFlight` so a dead URL is only attempted once per session.
    private func fetchPoster(for node: CanvasNode) {
        guard !inFlight.contains(node.id) else { return }
        inFlight.insert(node.id)
        let snapshot = node
        Task { [weak self] in
            let cg = await ColorExtraction.representativeCGImage(for: snapshot)
            guard let self else { return }
            await MainActor.run {
                if let cg {
                    self.thumbs[snapshot.id] = Self.scaledImage(from: cg, maxSide: 240)
                    self.version &+= 1
                }
            }
        }
    }

    nonisolated private static func scaledImage(from cg: CGImage, maxSide: CGFloat) -> NSImage {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let size = NSSize(width: max(1, w * scale), height: max(1, h * scale))
        return NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.cgContext.interpolationQuality = .medium
            NSGraphicsContext.current?.cgContext.draw(cg, in: rect)
            return true
        }
    }

    nonisolated private static func downsample(_ data: Data, maxSide: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Resizable minimap view. Shape & background are owned by whatever wraps it
/// (in-window: `LiquidGlassMinimap`; detached: `NSPanel` from `MinimapWindowController`).
///
///   • Renders every node as a small rectangle (selected = accent).
///   • Renders the current viewport as a dashed accent rectangle.
///   • Click / drag to move the camera to that location.
struct MinimapView: View {
    @EnvironmentObject var state: CanvasState
    /// Observed so the viewport box re-renders on pan/zoom — `visibleWorldRect`
    /// derives from the camera.
    @EnvironmentObject var cameraStore: CameraStore

    /// Padding between the projected content and the view edge. The default
    /// suits a rectangular host; circular hosts (the glass lens) pass a
    /// larger value so nothing drowns in the curved rim.
    var inset: CGFloat = 12
    /// When false (the glass lens), the dashed viewport box and the
    /// world-space dot grid are not drawn, the projection frames the
    /// content only — cards fill the map instead of shrinking to make
    /// room for a huge zoomed-out viewport — and image/video cards render
    /// real thumbnails like the reference artwork.
    var showsViewport: Bool = true

    /// Re-renders the Canvas as image thumbnails finish decoding.
    @ObservedObject private var thumbs = MinimapThumbs.shared

    var body: some View {
        GeometryReader { geo in
            // The Canvas redraws every node (image/video thumbnails included) —
            // it was ~50% of the main thread because it ran on EVERY display
            // frame: a playing video keeps the window's display cycle (and this
            // hosting view's layout) ticking continuously, and the Canvas
            // re-rasterized all thumbnails each tick. That per-frame work is what
            // starved the zoom/pan display-link (→ ~1fps) and ran the machine hot.
            // Gate it: `Redrawn` is an Equatable wrapper keyed by everything the
            // drawing depends on (node geometry/kind/selection, thumbnail version,
            // host size, and — only when the camera is settled — the viewport
            // rect). With an unchanged key SwiftUI reuses the last render and
            // never re-runs `draw`, so an idle/auto-playing board costs nothing
            // and a live pan/zoom doesn't thrash the minimap (the box snaps to
            // place the instant the gesture ends).
            Redrawn(key: redrawKey(geo.size)) {
                Canvas { context, _ in
                    draw(in: context, canvasSize: geo.size)
                }
            }
            .equatable()
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in navigate(to: value.location, canvasSize: geo.size) }
            )
        }
        .help("Click to jump  ·  Drag to pan")
    }

    /// Cheap content signature for `Redrawn` — changes exactly when the minimap's
    /// drawing would change, so the expensive Canvas only re-runs then. Hashes
    /// only cheap fields (never image `Data` / stroke points): per-node id,
    /// frame, selection, and a kind+colour token; plus the thumbnail version and
    /// host size. The live viewport rect is included ONLY when the camera is
    /// settled — during a pan/zoom it's omitted so the minimap freezes instead of
    /// re-rasterizing every frame (it refreshes the instant the gesture ends).
    private func redrawKey(_ canvasSize: CGSize) -> Int {
        var h = Hasher()
        for n in state.nodes {
            h.combine(n.id)
            h.combine(n.position.x); h.combine(n.position.y)
            h.combine(n.width); h.combine(n.height ?? -1)
            h.combine(state.selectedNodeIDs.contains(n.id))
            minimapKindToken(n.kind, into: &h)
        }
        h.combine(thumbs.version)
        h.combine(canvasSize.width.rounded()); h.combine(canvasSize.height.rounded())
        if !state.cameraMoving {
            let vp = state.visibleWorldRect
            h.combine(vp.minX.rounded()); h.combine(vp.minY.rounded())
            h.combine(vp.width.rounded()); h.combine(vp.height.rounded())
        }
        return h.finalize()
    }

    // MARK: - Drawing

    private func draw(in ctx: GraphicsContext, canvasSize: CGSize) {
        let projection = makeProjection(canvasSize: canvasSize)

        // Subtle dot grid — rectangular hosts only (the lens draws one
        // uniform grid across its whole disc instead). Scale-aware: at
        // deep zoom-out the projected spacing collapses below a pixel and
        // tens of thousands of dots merge into a solid grey slab over the
        // map (and cost a fortune to draw). Grow the world step so dots
        // stay ≥ 7pt apart.
        if showsViewport {
            let worldStep: CGFloat = 60
            let projected = worldStep * projection.scale
            let gridSize = worldStep * max(1, (7 / max(projected, 0.0001)).rounded(.up))
            let bounds = projection.bounds
            let dotColor = Color(nsColor: .quaternaryLabelColor)
            // Accumulate every dot into ONE Path and fill once, instead of an
            // `ctx.fill` call per dot (was up to thousands of fills per redraw).
            var dots = Path()
            var gx = (bounds.minX / gridSize).rounded(.down) * gridSize
            while gx < bounds.maxX {
                var gy = (bounds.minY / gridSize).rounded(.down) * gridSize
                while gy < bounds.maxY {
                    let p = projection.project(CGPoint(x: gx, y: gy))
                    dots.addEllipse(in: CGRect(x: p.x - 0.5, y: p.y - 0.5, width: 1, height: 1))
                    gy += gridSize
                }
                gx += gridSize
            }
            ctx.fill(dots, with: .color(dotColor))
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

                // Sections — and any node so large its projection covers a
                // big share of the map (a giant text/drawing block) — draw
                // as hairline outlines. A filled block that size reads as
                // a grey slab swallowing the other cards.
                let coversMap = (w * h) > canvasSize.width * canvasSize.height * 0.28
                if case .section(_, let color) = node.kind {
                    layer.stroke(
                        Path(roundedRect: rect, cornerSize: CGSize(width: 3, height: 3)),
                        with: .color(color.swiftUIColor.opacity(isSel ? 0.8 : 0.45)),
                        style: StrokeStyle(lineWidth: 1)
                    )
                    continue
                }

                // Lens mode: image/video cards draw their real thumbnail,
                // aspect-filled and clipped to the rounded card — the
                // reference's "photos under glass" look.
                if !showsViewport, !coversMap, let thumb = thumbs.thumbnail(for: node) {
                    let cr = min(8, w * 0.22, h * 0.22)
                    let cardPath = Path(roundedRect: rect, cornerSize: CGSize(width: cr, height: cr))
                    // White base takes the soft shadow from the layer filter.
                    layer.fill(cardPath, with: .color(.white))
                    layer.drawLayer { card in
                        card.clip(to: cardPath)
                        let ts = thumb.size
                        if ts.width > 0, ts.height > 0 {
                            let s = max(rect.width / ts.width, rect.height / ts.height)
                            let dw = ts.width * s, dh = ts.height * s
                            card.draw(
                                Image(nsImage: thumb),
                                in: CGRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2,
                                           width: dw, height: dh)
                            )
                        }
                    }
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
                case .webclip:
                    fill = isSel ? .blue : Color.blue.opacity(0.5)
                case .section(_, let color):
                    fill = color.swiftUIColor.opacity(isSel ? 0.7 : 0.35)
                case .stickyNote(_, let color):
                    fill = color.swiftUIColor.opacity(isSel ? 1 : 0.85)
                case .folder:
                    fill = isSel ? .secondary : .secondary.opacity(0.5)
                }
                let r = min(4, w * 0.18, h * 0.18)
                let path = Path(roundedRect: rect, cornerSize: CGSize(width: r, height: r))
                if coversMap {
                    layer.stroke(
                        path, with: .color(fill.opacity(0.7)),
                        style: StrokeStyle(lineWidth: 1)
                    )
                } else {
                    layer.fill(path, with: .color(fill))
                }
            }
        }

        // Current viewport. Rectangular hosts get the classic dashed box;
        // the lens gets a soft rounded indication in the map's own style —
        // quiet fill, hairline edge, continuous corners.
        let vp = state.visibleWorldRect
        let vpTopLeft = projection.project(CGPoint(x: vp.minX, y: vp.minY))
        let vRect = CGRect(
            x: vpTopLeft.x, y: vpTopLeft.y,
            width: vp.width * projection.scale,
            height: vp.height * projection.scale
        )
        if showsViewport {
            ctx.stroke(
                Path(roundedRect: vRect, cornerSize: CGSize(width: 2, height: 2)),
                with: .color(.gray.opacity(0.9)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
        } else {
            let vPath = Path(
                roundedRect: vRect,
                cornerSize: CGSize(width: 6, height: 6),
                style: .continuous
            )
            ctx.fill(vPath, with: .color(.gray.opacity(0.07)))
            ctx.stroke(vPath, with: .color(.gray.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 1.2))
        }
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
        if showsViewport {
            // The viewport box must fit inside the map, so it joins the
            // projected bounds.
            let vp = state.visibleWorldRect
            minX = min(minX, vp.minX); minY = min(minY, vp.minY)
            maxX = max(maxX, vp.maxX); maxY = max(maxY, vp.maxY)
        }

        // Lens mode frames the content tightly so cards read large;
        // viewport mode pads more so the dashed box keeps clear air.
        let pad: CGFloat = showsViewport ? 0.18 : 0.02
        let pX = (maxX - minX) * pad
        let pY = (maxY - minY) * pad
        return CGRect(x: minX - pX, y: minY - pY,
                      width:  max(1, maxX - minX + pX * 2),
                      height: max(1, maxY - minY + pY * 2))
    }

    private func navigate(to point: CGPoint, canvasSize: CGSize) {
        let world = makeProjection(canvasSize: canvasSize).unproject(point)
        state.centerCamera(on: world)
    }
}

/// Hash token for a node's kind + colour, used by the minimap's redraw key.
/// Deliberately avoids hashing heavy associated values (image `Data`, stroke
/// point arrays, URLs) — only the discriminator and any tint affect the
/// minimap's tiny rendering, so this stays cheap to recompute every frame.
private func minimapKindToken(_ kind: CanvasNode.Kind, into h: inout Hasher) {
    switch kind {
    case .tweet:                 h.combine(0)
    case .instagram:             h.combine(1)
    case .youtube:               h.combine(2)
    case .webclip:               h.combine(3)
    case .text:                  h.combine(4)
    case .drawing(let s):        h.combine(5); h.combine(s.color)
    case .image:                 h.combine(6)
    case .video:                 h.combine(7)
    case .section(_, let c):     h.combine(8); h.combine(c)
    case .stickyNote(_, let c):  h.combine(9); h.combine(c)
    case .folder:                h.combine(10)
    }
}

/// Equatable gate: re-renders `content` only when `key` changes. Lets an
/// expensive child (the minimap Canvas) skip the per-display-frame re-render its
/// layer-backed host would otherwise force while a video plays. `content` is
/// rebuilt each time the parent evaluates (cheap — just a Canvas value), but
/// with an unchanged key SwiftUI reuses the prior render and never invokes its
/// draw closure.
private struct Redrawn<Content: View>: View, Equatable {
    let key: Int
    @ViewBuilder var content: Content
    static func == (l: Redrawn, r: Redrawn) -> Bool { l.key == r.key }
    var body: some View { content }
}
