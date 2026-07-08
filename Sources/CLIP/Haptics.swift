import AppKit

/// Centralised wrapper around `NSHapticFeedbackManager.defaultPerformer`.
/// macOS exposes exactly three feedback patterns; we expose them under
/// semantic names so call sites read clearly:
///
///   • `tap()`       — *something landed correctly*. Drag-end settle,
///                     Tidy Up complete, ring marked, reorder swap,
///                     gutter snap, focus mode engaged.
///                     (Maps to `.alignment`.)
///   • `threshold()` — *a binary state was crossed*. Group created,
///                     group dissolved, connector landed on target.
///                     (Maps to `.levelChange`.)
///   • `generic()`   — fallback for events that don't fit the above.
///                     (Maps to `.generic`.)
///
/// On hardware without a Force Touch trackpad (mice, older trackpads,
/// external displays) every call is a silent no-op — exactly the API
/// contract Apple specifies, so this is safe to fire anywhere without
/// gating on hardware capability.
@MainActor
enum Haptics {

    /// Single light tap — for events that read as "things snapped /
    /// landed where they belong." Fired on the FRONT of a spring
    /// animation so the feel coincides with the gesture commitment,
    /// not the tail end of the spring's settle.
    static func tap() {
        perform(.alignment)
    }

    /// Two-stage "you crossed a threshold" feedback. Used for binary
    /// state changes the user *intended* to flip — group/ungroup,
    /// connector landing on a target, focus mode on/off.
    static func threshold() {
        perform(.levelChange)
    }

    /// Generic feedback. Reserved — currently no call site uses this,
    /// but the wrapper exposes it so future code has a third tier of
    /// feedback without reaching for `defaultPerformer` directly.
    static func generic() {
        perform(.generic)
    }

    /// Single funnel so we can later add throttling, debug logging, or
    /// a user-pref gate in one place without touching every call site.
    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(
            pattern,
            // Synced to the next frame commit so the tap lands WITH the visual
            // (snap/settle), not a beat before it. (R17)
            performanceTime: .drawCompleted
        )
    }
}
