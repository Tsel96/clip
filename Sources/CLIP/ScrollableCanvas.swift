import SwiftUI
import AppKit

/// Phase 1 — native canvas core.
///
/// Replaces the manual `.scaleEffect(zoom).offset(camera)` camera with a real
/// `NSScrollView`: zoom is native magnification, pan is native scrolling — so
/// we inherit AppKit's momentum, pinch-zoom, rubber-banding and GPU-smooth
/// transform instead of re-deriving them in SwiftUI (and we sidestep the
/// SwiftUI-`scaleEffect` layout bugs: the glass crash, height jitter, etc.).
///
/// **Coordinate model.** The `documentView` is a *flipped* `NSHostingView`
/// (top-left origin, matching SwiftUI) spanning `worldBounds`. The hosted
/// `content` is the world layer (nodes + overlays) shifted by `-worldBounds.origin`
/// so world point `(wx,wy)` lands at documentView `(wx − minX, wy − minY)`.
///
/// **Camera mapping** (matches `CanvasState`):
///   zoom            = magnification
///   visibleWorldRect.origin = documentVisibleRect.origin + worldBounds.origin
///   camera.x        = −visibleWorldOrigin.x · zoom   (and likewise y)
///
/// Sync is two-way: live scroll/magnify push the derived `Camera` out via
/// `onCameraChange`; programmatic moves (fit, zoom buttons, glide) come back in
/// through `camera` and are applied to the scroll view. A re-entrancy guard
/// keeps the two from chasing each other.
struct ScrollableCanvas<Content: View>: NSViewRepresentable {
    /// The scrollable world extent, in world coordinates (covers all content
    /// plus generous margin so you can pan past the edges).
    let worldBounds: CGRect
    /// Current camera (drives programmatic moves applied to the scroll view).
    let camera: Camera
    /// Visible viewport size in points (the scroll view's own bounds).
    let minZoom: CGFloat
    let maxZoom: CGFloat
    /// Pushed out whenever a live scroll/magnify changes the camera.
    let onCameraChange: (Camera) -> Void
    /// World layer (nodes + overlays), positioned in world coordinates.
    @ViewBuilder var content: Content

    func makeCoordinator() -> Coordinator { Coordinator(onCameraChange: onCameraChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = minZoom
        scroll.maxMagnification = maxZoom
        scroll.usesPredominantAxisScrolling = false
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .allowed

        let host = NSHostingView(rootView: shiftedContent)   // already top-left (flipped)
        host.frame = CGRect(origin: .zero, size: worldBounds.size)
        scroll.documentView = host

        context.coordinator.scroll = scroll
        context.coordinator.host = host
        context.coordinator.worldBounds = worldBounds

        // Live scroll → camera.
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main
        ) { [weak coordinator = context.coordinator] _ in coordinator?.pushCameraFromScroll() }
        // Live magnify → camera.
        context.coordinator.magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification,
            object: scroll, queue: .main
        ) { [weak coordinator = context.coordinator] _ in coordinator?.pushCameraFromScroll() }

        // Apply the initial camera once the scroll view has a real size.
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.applyCamera(self.camera, animated: false)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.worldBounds = worldBounds
        coord.onCameraChange = onCameraChange
        scroll.minMagnification = minZoom
        scroll.maxMagnification = maxZoom
        // Refresh hosted content (node/overlay changes).
        (scroll.documentView as? NSHostingView<AnyView>)?.rootView = shiftedContent
        if scroll.documentView?.frame.size != worldBounds.size {
            scroll.documentView?.setFrameSize(worldBounds.size)
        }
        // Apply an EXTERNALLY-driven camera change (glide / fit / zoom buttons),
        // skipping the echo from our own live-scroll push.
        coord.applyCameraIfChanged(camera)
    }

    /// World layer shifted so world-origin maps to documentView (0,0).
    private var shiftedContent: AnyView {
        AnyView(content.offset(x: -worldBounds.minX, y: -worldBounds.minY))
    }

    // MARK: - Coordinator (two-way sync, re-entrancy guard)

    final class Coordinator: NSObject {
        var onCameraChange: (Camera) -> Void
        weak var scroll: NSScrollView?
        weak var host: NSView?
        var worldBounds: CGRect = .zero
        var boundsObserver: NSObjectProtocol?
        var magnifyObserver: NSObjectProtocol?
        /// The camera we last applied/derived — so updateNSView only reacts to
        /// genuinely external changes, and our own pushes don't loop back.
        private var lastCamera: Camera?
        private var applyingProgrammatic = false

        init(onCameraChange: @escaping (Camera) -> Void) {
            self.onCameraChange = onCameraChange
        }

        deinit {
            if let o = boundsObserver { NotificationCenter.default.removeObserver(o) }
            if let o = magnifyObserver { NotificationCenter.default.removeObserver(o) }
        }

        /// Derive a `Camera` from the scroll view's current magnification + scroll
        /// position and push it out (unless we're mid programmatic apply).
        func pushCameraFromScroll() {
            guard !applyingProgrammatic, let scroll else { return }
            let zoom = scroll.magnification
            let visible = scroll.documentVisibleRect   // visible region in documentView coords
            let worldOriginX = visible.origin.x + worldBounds.minX
            let worldOriginY = visible.origin.y + worldBounds.minY
            let cam = Camera(x: -worldOriginX * zoom, y: -worldOriginY * zoom, zoom: zoom)
            lastCamera = cam
            onCameraChange(cam)
        }

        /// Apply an external camera if it differs from what we last saw.
        func applyCameraIfChanged(_ cam: Camera) {
            if let last = lastCamera, last == cam { return }
            applyCamera(cam, animated: false)
        }

        /// Set the scroll view's magnification + scroll position to realise `cam`.
        func applyCamera(_ cam: Camera, animated: Bool) {
            guard let scroll, let host, cam.zoom > 0 else { return }
            applyingProgrammatic = true
            defer { applyingProgrammatic = false; lastCamera = cam }
            scroll.magnification = cam.zoom
            // visibleWorldRect.origin = (-camera.x/zoom, -camera.y/zoom);
            // documentVisibleRect.origin = world - worldBounds.origin.
            let worldOriginX = -cam.x / cam.zoom
            let worldOriginY = -cam.y / cam.zoom
            let docPoint = CGPoint(x: worldOriginX - worldBounds.minX,
                                   y: worldOriginY - worldBounds.minY)
            // NSClipView.scroll(to:) sets the bounds origin directly in document
            // coords — more reliable under magnification than NSView.scroll(_:).
            scroll.contentView.scroll(to: docPoint)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}