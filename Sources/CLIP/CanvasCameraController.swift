import AppKit

/// A3 seam — the scroll ⇄ `Camera` two-way sync, split out of
/// `CollectionCanvas.Coordinator` so the camera concern lives apart from the
/// data-source + apply logic. Identical code, separate file (behaviour
/// unchanged); reads/writes the coordinator's `applyingProgrammatic` /
/// `lastCamera` echo-suppression state (now internal for this reason).
extension CollectionCanvas.Coordinator {

    /// Derive a `Camera` from the scroll view's magnification + scroll
    /// position and push it out (skipped mid programmatic apply).
    func pushCameraFromScroll() {
        guard !applyingProgrammatic, let scroll else { return }
        let zoom = scroll.magnification
        let visible = scroll.documentVisibleRect
        let worldOriginX = visible.origin.x + config.worldBounds.minX
        let worldOriginY = visible.origin.y + config.worldBounds.minY
        let cam = Camera(x: -worldOriginX * zoom, y: -worldOriginY * zoom, zoom: zoom)
        lastCamera = cam
        config.onCameraChange(cam)
    }

    /// Apply an external camera ONLY if it genuinely differs from the scroll
    /// view's *current* state. Live scrolling pushes a camera out and SwiftUI
    /// feeds it straight back here; comparing against the scroll's live state
    /// (not a stored `lastCamera`, which races across render cycles) makes
    /// those echoes no-ops while real programmatic moves (zoom buttons, fit,
    /// glide) still apply. This is what stops the drift/zoom-anchor fight.
    func applyCameraIfChanged(_ cam: Camera) {
        guard let scroll else { return }
        let zoom = scroll.magnification
        let visible = scroll.documentVisibleRect
        let curX = -(visible.origin.x + config.worldBounds.minX) * zoom
        let curY = -(visible.origin.y + config.worldBounds.minY) * zoom
        // Echo of our own live scroll → skip. (Generous epsilons: anything
        // this close is the round-trip, not a deliberate camera move.)
        if abs(cam.zoom - zoom) < 0.0005,
           abs(cam.x - curX) < 0.5,
           abs(cam.y - curY) < 0.5 {
            return
        }
        applyCamera(cam)
    }

    func applyCamera(_ cam: Camera) {
        guard let scroll, cam.zoom > 0 else { return }
        applyingProgrammatic = true
        defer { applyingProgrammatic = false; lastCamera = cam }
        scroll.magnification = cam.zoom
        let worldOriginX = -cam.x / cam.zoom
        let worldOriginY = -cam.y / cam.zoom
        scroll.contentView.scroll(to: CGPoint(x: worldOriginX - config.worldBounds.minX,
                                              y: worldOriginY - config.worldBounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        // Connector stroke width is ÷ magnification (constant on screen) — it must
        // be recomputed on EVERY zoom step, including animated glide ticks, or it
        // drifts as the canvas scales. Also keep the inline label editor matched.
        refreshConnectors()
        if let cid = editingConnectorID { positionEditor(at: cid) }
    }
}
