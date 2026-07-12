import SwiftUI

/// The shared open/close motion for any panel that springs out of a button in
/// the bottom tool palette — the link input today, and any future popper above
/// the toolbar. Modelled on Spatial's toolbar springs: snappy, fast, smooth.
///
/// WHY IT'S BUILT THIS WAY — the panel must be **always mounted** (never
/// `if`-inserted). A SwiftUI `.transition(.scale(anchor:))` anchors to the
/// view's *un-offset layout frame* (the overlay's centre, ~240pt left of the
/// "+"), so `if` + `.transition` grows "from the left" and slides over — no
/// amount of anchor/order tweaking fixes it. Instead we drive the scale
/// ourselves with `.scaleEffect(anchor: .bottom)` and let the caller position
/// the panel with its own `.offset` AFTER this modifier. Because the scale
/// pivot is the panel's bottom-centre and the offset is applied after, the
/// pivot travels onto the button — the panel scales up directly OUT of it.
///
/// Usage — apply this, THEN the panel's positioning offset:
/// ```
/// MyPanel()
///     .toolbarPanelTransition(isPresented: state.isFooOpen)
///     .offset(x: dxToButton, y: yAboveToolbar)   // base position, constant
/// ```
/// Pair with (see `LinkInputBar` / `CanvasView` for the reference impl):
///   • focus the field on open: `.onChange(of: isPresented) { if $0 { text = "";
///     DispatchQueue.main.async { focused = true } } else { focused = false } }`
///   • a full-canvas click-catcher overlay placed BELOW the palette overlay, so
///     an outside tap closes the panel while the button + field stay live.
///
/// Tunables that are deliberately fixed here (the approved feel):
///   • start scale 0.5, anchored `.bottom`  → grows out of the button
///   • opacity 0 → 1
///   • short ~12pt vertical rise as it opens (longer reads as a slide)
///   • spring `Motion.popper` (response 0.196, dampingFraction 0.84) — the
///     "snappy/fast/smooth, almost no overshoot" Spatial feel
struct ToolbarPanelTransition: ViewModifier {
    /// Whether the panel is open.
    let isPresented: Bool
    /// How far below its resting spot the panel starts — a short rise on open.
    var rise: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPresented ? 1 : 0.5, anchor: .bottom)
            .opacity(isPresented ? 1 : 0)
            .offset(y: isPresented ? 0 : rise)
            .allowsHitTesting(isPresented)
            .animation(Motion.popper, value: isPresented)
    }
}

extension View {
    /// Spring a bottom-toolbar panel open/closed so it grows out of its button.
    /// The view MUST be always mounted (not `if`-inserted). See
    /// `ToolbarPanelTransition` for the full rationale.
    func toolbarPanelTransition(isPresented: Bool, rise: CGFloat = 12) -> some View {
        modifier(ToolbarPanelTransition(isPresented: isPresented, rise: rise))
    }
}
