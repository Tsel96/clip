import AppKit

// MARK: - CLIP native animation system (mirrors Spatial's SpaceAnimator / Haptics)

/// Shared spring/curve helpers for the native UI, modelled on Spatial's
/// `SpaceAnimator` (CASpringAnimation with `allowsOverdamping`) and its
/// `ControlPoints` cubic-bézier easing. All work on CALayers so it composes
/// with the native canvas + detail view without SwiftUI.
///
/// Tuning constants are seeded from the values recovered from Spatial's binary
/// constant pool (press scales 0.94–0.96, hover-grow 1.05, durations
/// 0.06/0.12/0.18/0.24/0.32/0.48). See the `spatial-button-kit` memory.
enum CLIPSpring {

    /// A reusable spring preset. `response` is the approximate settle time;
    /// `damping` 1.0 = critically damped (no overshoot), < 1 = bouncy.
    struct Preset {
        var response: CGFloat
        var damping: CGFloat
        var allowsOverdamping: Bool = true

        /// Snappy control feedback (button press / hover). Tiny, quick.
        static let control = Preset(response: 0.24, damping: 0.78)
        /// A card / element settling into place — a touch bouncier.
        static let settle  = Preset(response: 0.42, damping: 0.72)
        /// Element entrance pop — mirrors SwiftUI `Motion.pop` (0.35/0.72)
        /// so the native side pops at the same speed as the SwiftUI side.
        static let pop     = Preset(response: 0.35, damping: 0.72)
        /// Decisive gesture settle — mirrors SwiftUI `Motion.settle`
        /// (0.294/0.76): native drag-release must land at the same speed
        /// as the SwiftUI drag path.
        static let gestureSettle = Preset(response: 0.294, damping: 0.76)
        /// A larger surface (panel / hero) easing in — minimal overshoot.
        static let surface = Preset(response: 0.5,  damping: 0.86)
        /// Canvas→detail hero morph: ~0.3s, near-critically damped so it
        /// decelerates cleanly into place with no bounce (matches Spatial).
        static let hero    = Preset(response: 0.42, damping: 0.9)

        /// CASpringAnimation maps response/damping → stiffness/damping via the
        /// standard mass-spring relations (mass = 1).
        var stiffness: CGFloat { let w = (2 * .pi) / max(0.001, response); return w * w }
        var caDamping: CGFloat { 2 * damping * ((2 * .pi) / max(0.001, response)) }
    }

    /// Spring a CALayer keyPath from its CURRENT presentation value to `to`.
    /// `key` coalesces: starting a new spring with the same key replaces the
    /// in-flight one (mirrors Spatial's `animationIdentifier`) so re-triggers
    /// never stack/jank.
    @discardableResult
    static func animate(_ layer: CALayer, _ keyPath: String, to value: CGFloat,
                        preset: Preset = .control, key: String? = nil) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.fromValue = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        a.toValue = value
        a.stiffness = preset.stiffness
        a.damping = preset.caDamping
        a.mass = 1
        if #available(macOS 14.0, *) { a.allowsOverdamping = preset.allowsOverdamping }
        a.duration = a.settlingDuration
        a.fillMode = .forwards
        layer.setValue(value, forKeyPath: keyPath)            // commit the model value
        layer.add(a, forKey: key ?? keyPath)
        return a
    }

    /// The pivot that makes a `T(-c)·S·T(c)` transform scale about the layer's
    /// geometric CENTER. `transform` pivots about the `anchorPoint`, so the fixed
    /// point must be the center expressed in anchor-origin space:
    /// `(W·(0.5-apx), H·(0.5-apy))`. For the usual layer-backed-NSView anchor
    /// (0.5,0.5) this is `(0,0)` → a plain centered scale; for (0,0) it's
    /// `(midX,midY)`. Hard-coding `(midX,midY)` scaled (0.5,0.5)-anchored views
    /// about a corner — the "grows from the left" bug.
    private static func centerPivot(_ layer: CALayer) -> CGPoint {
        let ap = layer.anchorPoint
        return CGPoint(x: layer.bounds.width  * (0.5 - ap.x),
                       y: layer.bounds.height * (0.5 - ap.y))
    }

    /// Spring a layer's uniform scale (about its center) to `scale`. Used by
    /// the button kit for hover-grow / press-shrink / release-bounce.
    static func scale(_ view: NSView, to scale: CGFloat, preset: Preset = .control,
                      key: String = "clipScale") {
        guard let layer = view.layer else { return }
        let c = centerPivot(layer)
        let from = layer.presentation()?.transform ?? layer.transform
        let to = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-c.x, -c.y, 0),
                                CATransform3DMakeScale(scale, scale, 1)),
            CATransform3DMakeTranslation(c.x, c.y, 0))
        let a = CASpringAnimation(keyPath: "transform")
        a.fromValue = from
        a.toValue = to
        a.stiffness = preset.stiffness
        a.damping = preset.caDamping
        a.mass = 1
        if #available(macOS 14.0, *) { a.allowsOverdamping = preset.allowsOverdamping }
        a.duration = a.settlingDuration
        a.fillMode = .forwards
        layer.transform = to
        layer.add(a, forKey: key)
    }

    /// Fast, NON-spring press-DOWN scale — mirrors Spatial's `BaseView` press
    /// visual: the button snaps down quickly (~0.06s ease-out), then the release
    /// uses `scale(... preset:.control)` for the springy overshoot settle (their
    /// `resetScaleWithStiffness:damping:` + `allowsOverdamping`). Using the spring
    /// for the down-stroke too is what makes a press feel mushy/unlike Spatial.
    /// Share the same `key` as the release so the spring retargets from mid-press.
    static func pressScale(_ view: NSView, to scale: CGFloat,
                           duration: CFTimeInterval = 0.07, key: String = "clipScale") {
        guard let layer = view.layer else { return }
        let c = centerPivot(layer)
        let from = layer.presentation()?.transform ?? layer.transform
        let to = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-c.x, -c.y, 0),
                                CATransform3DMakeScale(scale, scale, 1)),
            CATransform3DMakeTranslation(c.x, c.y, 0))
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = easeOutSoft
        a.fillMode = .forwards
        layer.transform = to
        layer.add(a, forKey: key)
    }

    /// Cubic-bézier timing function (mirrors Spatial's `ControlPoints`), for the
    /// non-spring fades. A subtle overshoot pair gives the "pop".
    static func curve(_ c1x: Float, _ c1y: Float, _ c2x: Float, _ c2y: Float) -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: c1x, c1y, c2x, c2y)
    }
    static let easeOutSoft = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    static let popOut      = CAMediaTimingFunction(controlPoints: 0.33, 1.08, 0.40, 1)

    /// Run a layer-property change as an animation group with a timing curve
    /// (for opacity/path/frame fades that don't need a spring).
    static func run(duration: CFTimeInterval, curve: CAMediaTimingFunction = easeOutSoft,
                    _ body: () -> Void, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = curve
            ctx.allowsImplicitAnimation = true
            body()
        }, completionHandler: completion)
    }
}

/// Haptics with Spatial's restraint: ONLY for snap/align and discrete
/// level-changes — never plain hover or button presses (firing on every click
/// is the #1 way to feel *unlike* Spatial). See `spatial-button-kit` memory.
@MainActor
enum CLIPHaptics {
    /// Soft alignment tick — drag-snap, resize-align, ring-mark.
    static func snap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    /// Firmer detent — discrete state change, drag-drop settle, group/ungroup.
    static func levelChange() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
