import AppKit
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
    // All durations / spring responses below are 30% faster than the original
    // tuning (×0.7) per the product call — damping fractions are unchanged so the
    // overshoot/feel is preserved, just snappier.

    /// Structural rearrangement: mode enter/exit, layout reflows,
    /// stack choreography. The app's load-bearing spring.
    static let structure = Animation.spring(
        response: structureResponse, dampingFraction: structureDamping)
    /// Scalar mirrors of `structure` for code that derives durations
    /// from the response (stagger totals etc.) — keeps those sums in
    /// lockstep with the token instead of a drifting copy.
    static let structureResponse: Double = 0.385
    static let structureDamping: Double = 0.84

    /// Decisive gesture settle: drag release, snap-to-guides landing.
    static let settle = Animation.spring(response: 0.294, dampingFraction: 0.76)

    /// Element entrance: creation pop, chips, toasts.
    static let pop = Animation.spring(response: 0.35, dampingFraction: 0.72)

    /// Inline popper / panel open-close — modelled on Spatial's toolbar springs:
    /// fast, snappy, smooth, almost no overshoot. Much quicker than `pop`.
    static let popper = Animation.spring(response: 0.196, dampingFraction: 0.84)

    /// Per-tick gesture tracking (cursor pursuit with a hint of lag).
    static let track = Animation.interactiveSpring(
        response: 0.084, dampingFraction: 0.86, blendDuration: 0.035)

    /// Hover / selection / pressed feedback — fast fades.
    static let feedback = Animation.easeOut(duration: 0.084)

    /// Quiet fades (toasts out, hints).
    static let fade = Animation.easeOut(duration: 0.14)

    // MARK: Camera-glide physics (value-level spring, see CanvasState)

    /// Response of the navigation glide spring (zoom buttons, fit,
    /// minimap jumps). Calm and slightly slower than UI springs — the
    /// whole world is moving.
    static let glideResponse: CGFloat = 0.266
    /// Near-critical damping: spatial navigation must not overshoot,
    /// or the user loses their bearings.
    static let glideDampingRatio: CGFloat = 0.95

    // MARK: Reduced motion

    /// System "Reduce Motion". Large, vestibular movements (whole-canvas
    /// reflows, camera flights, cross-viewport ghosts) must respect it.
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    /// `structure` with a reduced-motion fallback: a brief non-spatial
    /// ease instead of a whole-layout spring flight.
    static var structureAccessible: Animation {
        reduced ? .easeOut(duration: 0.16) : structure
    }
}
