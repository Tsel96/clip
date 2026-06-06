import SwiftUI

/// Mode switcher at the top of the sidebar — a faithful take on Claude
/// Desktop's Chat / Cowork / Code control. Segments sit directly on the
/// sidebar surface (no enclosing track); the active segment is lifted
/// onto a white, slightly-elevated pill that slides between segments.
///
/// Layout is **responsive, exactly like Claude**: when the sidebar is
/// wide enough every segment shows its icon + label; when it's narrowed
/// the unselected segments collapse to icon-only and only the active
/// segment keeps its label. `ViewThatFits` picks the widest run that
/// still fits the available width.
///
///   • **Canvas** — the editor (you mutate the document here).
///   • **View modes** — Colorform / Archive — read-only views.
struct CanvasModeSwitcher: View {
    @EnvironmentObject var state: CanvasState
    @Namespace private var pill

    var body: some View {
        // Full-width segmented track: stretches edge-to-edge across the
        // sidebar with the segments sharing the width equally (like a
        // native segmented control), and the active white pill lifted
        // out of the enclosing track.
        ViewThatFits(in: .horizontal) {
            strip(allLabels: true)    // wide: every segment labelled
            strip(allLabels: false)   // narrow: only the active one
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.82),
                   value: state.canvasMode)
    }

    /// Every `CanvasMode` flagged as a view (i.e. not the editor), in
    /// declaration order.
    private var viewModes: [CanvasMode] {
        CanvasMode.allCases.filter(\.isViewMode)
    }

    /// One horizontal run of segments. `allLabels` is the wide variant
    /// (every segment shows its label); otherwise only the active
    /// segment is labelled and the rest are icon-only.
    private func strip(allLabels: Bool) -> some View {
        HStack(spacing: 2) {
            tab(for: .canvas, showLabel: allLabels)
            ForEach(viewModes) { mode in
                tab(for: mode, showLabel: allLabels)
            }
        }
    }

    @ViewBuilder
    private func tab(for mode: CanvasMode, showLabel: Bool) -> some View {
        let isActive = state.canvasMode == mode
        // Colorform's color extraction runs async on entry — show a
        // mini spinner in place of its icon while it's in flight.
        let showSpinner = (mode == .colorform && state.isComputingColorform)
        let labelled = isActive || showLabel
        Button {
            state.setMode(mode)
        } label: {
            HStack(spacing: 4) {
                Group {
                    if showSpinner {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 12, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .frame(width: 14, height: 14)

                if labelled {
                    Text(mode.label)
                        .font(.clip(10.5, isActive))      // Black cut when active
                        .textCase(.uppercase)
                        .tracking(1.1)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .padding(.vertical, 4.5)
            .padding(.horizontal, labelled ? 7 : 6)
            // Each segment shares the track width equally so the control
            // fills the sidebar end-to-end; the active pill fills its cell.
            .frame(maxWidth: .infinity)
            .background(activeThumb(isActive))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.hover)
        .help(helpText(for: mode))
        .accessibilityLabel(mode.label)
        // Stable identifier so AX-based annotation tools (e.g. Loupe)
        // name the exact segment instead of an anonymous AXGroup.
        .accessibilityIdentifier("mode.switcher.\(mode.rawValue)")
    }

    /// The active segment's white, slightly-elevated pill — the only
    /// chrome in the strip. Tagged with `matchedGeometryEffect` so it
    /// slides between segments as the active mode changes.
    @ViewBuilder
    private func activeThumb(_ isActive: Bool) -> some View {
        if isActive {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                )
                .matchedGeometryEffect(id: "pill", in: pill)
        }
    }

    private func helpText(for mode: CanvasMode) -> String {
        switch mode {
        case .canvas:    return "Edit on the infinite canvas (⌘1)"
        case .colorform: return "Group cards by dominant color (⌘2)"
        case .archive:   return "Browse by date — calendar, then drill in (⌘3)"
        }
    }
}
