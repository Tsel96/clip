import SwiftUI
import AppKit

/// Colorform's background visualisation. The soft color field is now rendered on
/// the GPU (`ColorformMetalView` — a gaussian-weighted blend of the bulb colours,
/// see that file); the labels stay SwiftUI on top (a handful of screen-space
/// `Text`s, cheap). This replaced a per-frame CPU Voronoi + three big SwiftUI
/// blurs that starved pan/zoom in Colorform mode.
struct ColorformLayer: View {
    @EnvironmentObject var state: CanvasState
    @EnvironmentObject var cameraStore: CameraStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            // GPU color field — fills the layer; transparent at the edges so the
            // cream canvas + dot grid show through (the old organic blob mask).
            ColorformMetalView(state: state, cameraStore: cameraStore)

            // Labels — SCREEN coordinates so they stay a constant 22pt on-screen,
            // painted on top of the field and never blurred.
            GeometryReader { _ in
                let cam = cameraStore.camera
                ForEach(state.colorBulbs) { bulb in
                    Text(bulb.label)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.30), radius: 4, y: 1)
                        .shadow(color: bulb.color.swiftUIColor.opacity(0.6), radius: 8)
                        .position(x: bulb.center.x * cam.zoom + cam.x,
                                  y: bulb.center.y * cam.zoom + cam.y)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Colorform pan / zoom

/// Native scroll/magnify capture for Colorform — drives the shared `CameraStore`
/// so the GPU field + labels move. (The native scroll view doesn't drive the
/// camera in this read-only view mode, so we own navigation here.) Two-finger
/// scroll = pan, pinch = zoom about the cursor — matching `screen = world·zoom + camOffset`.
private final class ColorformPanZoomView: NSView {
    var onScroll: (@MainActor (CGFloat, CGFloat) -> Void)?
    var onMagnify: (@MainActor (CGFloat, CGPoint) -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { self }   // capture nav events
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        MainActor.assumeIsolated { onScroll?(dx, dy) }
    }
    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil), m = event.magnification
        MainActor.assumeIsolated { onMagnify?(1 + m, p) }
    }
}

struct ColorformPanZoom: NSViewRepresentable {
    @EnvironmentObject var cameraStore: CameraStore

    func makeNSView(context: Context) -> NSView {
        let v = ColorformPanZoomView()
        let cam = cameraStore
        v.onScroll = { dx, dy in
            let c = cam.camera
            cam.camera = Camera(x: c.x + dx, y: c.y + dy, zoom: c.zoom)
        }
        v.onMagnify = { f, anchor in
            let base = cam.camera
            let nz = min(max(base.zoom * f, 0.05), 8)
            let r = nz / max(base.zoom, 0.0001)
            cam.camera = Camera(x: anchor.x * (1 - r) + base.x * r,
                                y: anchor.y * (1 - r) + base.y * r,
                                zoom: nz)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
