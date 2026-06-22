import SwiftUI

/// Colorform's background visualisation. The soft color field is now rendered on
/// the GPU (`ColorformMetalView` — a gaussian-weighted blend of the bulb colours,
/// see that file); the labels stay SwiftUI on top (a handful of screen-space
/// `Text`s, cheap). This replaced a per-frame CPU Voronoi + three big SwiftUI
/// blurs that starved pan/zoom in Colorform mode.
struct ColorformLayer: View {
    @EnvironmentObject var state: CanvasState
    @EnvironmentObject var cameraStore: CameraStore
    /// Live cursor (screen-space, top-left) for the field's hover interaction —
    /// the same store that feeds the dot-grid spotlight. Read live by the GPU
    /// renderer; pointer moves never re-render this view.
    let pointer: CanvasPointerStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            // GPU color field — fills the layer; transparent at the edges so the
            // cream canvas + dot grid show through (the old organic blob mask).
            ColorformMetalView(state: state, cameraStore: cameraStore, pointer: pointer)

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
