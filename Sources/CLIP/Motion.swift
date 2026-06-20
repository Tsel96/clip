import SwiftUI

/// CLIP's motion language — one set of named physics instead of a zoo of
/// ad-hoc values. The principles ("fluid interface" school):
///
///   1. **Motion is physics, not clips.** Springs everywhere; durations
///      only for opacity-ish fades. Springs compose and retarget — a
///      half-finished move redirects instead of restarting.
///   2. **Everything is interruptible.** A gesture must always be able
///      to seize an animating value mid-flight (see `CanvasState`'s
///      camera glide: any pan/pinch cancels it and takes over).
///   3. **Velocity carries through.** Gesture release hands its speed to
///      the settle (drag throw); retargeting a glide keeps its velocity.
///   4. **Continuity of identity.** Things move/morph to their next
///      state; they don't vanish and reappear.
///
/// When adding motion, pick a token — only invent new physics for a
/// genuinely new class of motion.
enum Motion {
    /// Structural rearrangement: mode enter/exit, layout reflows,
    /// stack choreography. The app's load-bearing spring.
    static let structure = Animation.spring(response: 0.55, dampingFraction: 0.84)

    /// Decisive gesture settle: drag release, snap-to-guides landing.
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.76)

    /// Element entrance: creation pop, chips, toasts.
    static let pop = Animation.spring(response: 0.5, dampingFraction: 0.72)

    /// Inline popper / panel open-close — modelled on Spatial's toolbar springs:
    /// fast, snappy, smooth, almost no overshoot. Much quicker than `pop`.
    static let popper = Animation.spring(response: 0.28, dampingFraction: 0.84)

    /// Per-tick gesture tracking (cursor pursuit with a hint of lag).
    static let track = Animation.interactiveSpring(
        response: 0.12, dampingFraction: 0.86, blendDuration: 0.05)

    /// Hover / selection / pressed feedback — fast fades.
    static let feedback = Animation.easeOut(duration: 0.12)

    /// Quiet fades (toasts out, hints).
    static let fade = Animation.easeOut(duration: 0.2)

    // MARK: Camera-glide physics (value-level spring, see CanvasState)

    /// Response of the navigation glide spring (zoom buttons, fit,
    /// minimap jumps). Calm and slightly slower than UI springs — the
    /// whole world is moving.
    static let glideResponse: CGFloat = 0.38
    /// Near-critical damping: spatial navigation must not overshoot,
    /// or the user loses their bearings.
    static let glideDampingRatio: CGFloat = 0.95
}
