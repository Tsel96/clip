import SwiftUI

/// The live pan/zoom camera, isolated on its own `ObservableObject`.
///
/// A pan tick fires ~120×/s. If the camera lived on `CanvasState` (one
/// monolithic `ObservableObject`), every `@EnvironmentObject var state`
/// view — including every `DraggableNode` — would re-evaluate `body` on
/// every tick. Holding it here means a pan invalidates ONLY the views
/// that actually draw camera-transformed content: the node group's
/// transform, the dot grid, the alignment / spacing / connector overlays,
/// the minimap, and the zoom readout. Node views render *through* the
/// parent transform and never observe this object, so a pan costs them
/// nothing.
///
/// `CanvasState` owns one of these and exposes `state.camera` as a
/// pass-through (so existing call sites are unchanged); it also watches
/// this store and bumps `CanvasState.zoomEpoch` whenever the *zoom*
/// changes — the one camera property the node views' semantic-zoom gate
/// (`isLive`) depends on.
@MainActor
final class CameraStore: ObservableObject {
    @Published var camera: Camera = Camera()
}
