import SwiftUI
import AppKit

/// Drop-in replacement for `.plain` that adds a consistent hover state
/// across the whole app: the label brightens a touch on hover, dims +
/// scales down slightly on press. NO cursor change — pushing a pointing-hand
/// cursor here fought the canvas's `cursorUpdate`, which read as a blinking
/// cursor (user report). Carries no chrome of its own (just like `.plain`).
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration)
    }

    private struct HoverLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .brightness(configuration.isPressed ? -0.05 : (hovering ? 0.07 : 0))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(Motion.feedback, value: hovering)
                .animation(Motion.feedback, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    /// `.buttonStyle(.hover)` — plain styling plus a hover/press highlight
    /// (no cursor change).
    static var hover: HoverButtonStyle { HoverButtonStyle() }
}
