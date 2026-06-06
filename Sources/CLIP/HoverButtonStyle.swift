import SwiftUI
import AppKit

/// Drop-in replacement for `.plain` that adds a consistent hover state
/// across the whole app: the label brightens a touch on hover, dims +
/// scales down slightly on press, and the cursor becomes a pointing hand.
/// Carries no chrome of its own (just like `.plain`), so it's a safe swap
/// anywhere `.buttonStyle(.hover)` was used.
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
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { h in
                    hovering = h
                    if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                // Safety: if a hovered button is removed from the tree, pop
                // the pushed cursor so it never gets stuck on a pointing hand.
                .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
        }
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    /// `.buttonStyle(.hover)` — plain styling plus a hover highlight and
    /// pointing-hand cursor.
    static var hover: HoverButtonStyle { HoverButtonStyle() }
}
