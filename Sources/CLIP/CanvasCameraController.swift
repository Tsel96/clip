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
        // During a live pinch the scroll view owns the camera; re-applying the
        // model camera (which lags the gesture) fights it and makes the viewport
        // visibly jump/drift. Skip — `pushCameraFromScroll` keeps the model in sync,
        // and the next settled `updateNSView` reconciles any residual difference.
        if (scroll as? CenterZoomScrollView)?.isMagnifying == true { return }
        // ⌘-wheel zoom has no gesture phases, so `isMagnifying` misses it —
        // `zoomMoving` (set by zoomDidTick on EVERY setMagnification, with a
        // 0.18 s settle) covers both; without this a stale camera echo snaps
        // the viewport back one tick during continuous wheel-zoom.
        if zoomMoving { return }
        // Same story mid-glide: the animator owns the camera until it settles
        // (its settle does the final apply + publish); re-applying the model
        // value here would snap the view to the glide TARGET mid-flight.
        if glideTicker?.isRunning == true { return }
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

    // MARK: - Navigation glide (R2 — spring animator driving the scroll directly)
    //
    // Per-frame writes go STRAIGHT to the scroll view (`applyCamera` inside a
    // disabled-actions transaction) — never through a `@Published` (the old
    // Timer glide's per-tick publish tripped AppKit's depth-16 layout recursion
    // on macOS 26). The coalesced bounds-notification refresh publishes the
    // intermediate camera exactly like a user pan, so the minimap / zoom
    // readout track the glide live; the settle does one final apply + push.

    /// Spring-glide the viewport to `target`. Retargeting mid-flight keeps the
    /// current velocity, so chained ⌘+ presses read as one accelerating move.
    /// Pre–macOS 14 (no `NSView.displayLink`) falls back to the old snap.
    func animateCamera(to target: Camera) {
        guard let scroll, target.zoom > 0 else { return }
        // Reduce Motion: the glide flies the ENTIRE viewport — the most
        // vestibular motion in the app. Land instantly instead.
        guard !Motion.reduced else {
            applyCamera(target); pushCameraFromScroll(); return
        }
        guard #available(macOS 14.0, *) else {
            applyCamera(target); pushCameraFromScroll(); return
        }
        if glideTicker == nil {
            glideTicker = DisplayLinkTicker(view: scroll) { [weak self] dt in
                self?.glideTick(dt)
            }
        }
        if glideTicker?.isRunning != true {
            // Fresh glide: start from the scroll view's LIVE state, at rest.
            glideCurrent = liveCamera()
            glideVelocity = (0, 0, 0)
        }
        glideTarget = target
        glideTicker?.start()
    }

    /// Direct input (pinch tick, scroll wheel) seizes the camera mid-glide.
    func cancelCameraGlide() {
        guard glideTarget != nil || glideTicker?.isRunning == true else { return }
        glideTarget = nil
        glideTicker?.stop()
    }

    /// The camera implied by the scroll view's CURRENT state (same derivation
    /// as `pushCameraFromScroll`, without the publish).
    private func liveCamera() -> Camera {
        guard let scroll else { return glideCurrent }
        let zoom = scroll.magnification
        let visible = scroll.documentVisibleRect
        return Camera(x: -(visible.origin.x + config.worldBounds.minX) * zoom,
                      y: -(visible.origin.y + config.worldBounds.minY) * zoom,
                      zoom: zoom)
    }

    private func glideTick(_ dt: CFTimeInterval) {
        guard let target = glideTarget else { glideTicker?.stop(); return }
        let omega = 2 * CGFloat.pi / Motion.glideResponse
        let zeta = Motion.glideDampingRatio
        let step = CGFloat(dt)
        func integrate(_ x: inout CGFloat, _ v: inout CGFloat, to t: CGFloat) {
            v += step * (-(omega * omega) * (x - t) - 2 * zeta * omega * v)
            x += step * v
        }
        integrate(&glideCurrent.x, &glideVelocity.x, to: target.x)
        integrate(&glideCurrent.y, &glideVelocity.y, to: target.y)
        integrate(&glideCurrent.zoom, &glideVelocity.zoom, to: target.zoom)
        let settled = abs(glideCurrent.x - target.x) < 0.5, restX = abs(glideVelocity.x) < 0.5
        let settledY = abs(glideCurrent.y - target.y) < 0.5, restY = abs(glideVelocity.y) < 0.5
        let settledZ = abs(glideCurrent.zoom - target.zoom) < 0.0005,
            restZ = abs(glideVelocity.zoom) < 0.005
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if settled, restX, settledY, restY, settledZ, restZ {
            glideTarget = nil
            glideTicker?.stop()
            applyCamera(target)
            CATransaction.commit()
            pushCameraFromScroll()   // one settled publish — media gate keys off this
        } else {
            applyCamera(glideCurrent)
            CATransaction.commit()
        }
    }
}
