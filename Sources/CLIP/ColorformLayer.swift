import SwiftUI

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

/// Direct pan/zoom for Colorform — drives the shared `CameraStore` so the GPU
/// field + labels move. (The native scroll view doesn't drive the camera in this
/// read-only view mode, so we own navigation here.) Drag = pan, pinch = zoom
/// about the viewport centre, matching the canvas projection `screen = world·zoom + camOffset`.
struct ColorformPanZoom: View {
    @EnvironmentObject var cameraStore: CameraStore
    @State private var panBase: Camera?
    @State private var zoomBase: Camera?

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SimultaneousGesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                let base = panBase ?? cameraStore.camera
                                if panBase == nil { panBase = base }
                                cameraStore.camera = Camera(x: base.x + v.translation.width,
                                                            y: base.y + v.translation.height,
                                                            zoom: base.zoom)
                            }
                            .onEnded { _ in panBase = nil },
                        MagnificationGesture()
                            .onChanged { scale in
                                let base = zoomBase ?? cameraStore.camera
                                if zoomBase == nil { zoomBase = base }
                                let nz = min(max(base.zoom * scale, 0.05), 8)
                                let f = nz / max(base.zoom, 0.0001)
                                let cx = geo.size.width / 2, cy = geo.size.height / 2
                                cameraStore.camera = Camera(x: cx * (1 - f) + base.x * f,
                                                            y: cy * (1 - f) + base.y * f,
                                                            zoom: nz)
                            }
                            .onEnded { _ in zoomBase = nil }
                    )
                )
        }
    }
}
