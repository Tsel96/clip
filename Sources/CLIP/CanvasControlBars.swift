import SwiftUI
import AppKit

/// The two floating control bars from Figma:
///   • `CanvasControlsBar` (74:25918) — connectors / grid / play-preview toggles.
///   • `SidebarToggleButton` (74:25877 open / 74:13420 closed) — show/hide sidebar.
/// Both use the same candy chrome: a white-60% `Capsule` (rounded-999), 4pt
/// padding, a faint layered shadow, and 24pt SVG icons pulled from Figma.

// MARK: - SVG icon loader (Bundle.module, cached)

private enum CanvasBarIcon {
    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let c = cache[name] { return c }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }
}

private struct SVGIcon: View {
    let name: String
    var size: CGFloat = 24
    var body: some View {
        Group {
            if let img = CanvasBarIcon.image(name) {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Shared Figma pill chrome

/// White-60% rounded-999 pill with 4pt padding + the Figma layered drop shadow.
private struct FigmaPill<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 4) { content }
            .padding(4)
            .background(Color.white.opacity(0.6), in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(Color.black.opacity(0.04), lineWidth: 0.5))
            // Figma 74:25918 drop shadow (the visible levels of the 5-stop stack).
            .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.02), radius: 2, y: 2)
            .shadow(color: .black.opacity(0.01), radius: 2.5, y: 4.5)
    }
}

/// One 24pt-icon control inside a pill: 28pt-min slot, dims when "off", soft
/// hover wash. Press feedback via the standard plain button.
private struct PillIconButton: View {
    let icon: String
    var isOn: Bool = true
    let action: () -> Void
    var help: String = ""
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            SVGIcon(name: icon, size: 24)
                .opacity(isOn ? 1.0 : 0.45)               // toggle state via opacity
                .frame(height: 28)
                .frame(minWidth: 28)
                .padding(.horizontal, 4)
                .background(hover ? Color.black.opacity(0.06) : .clear,
                            in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Canvas controls bar (Figma 74:25918)

struct CanvasControlsBar: View {
    @EnvironmentObject var state: CanvasState

    var body: some View {
        FigmaPill {
            PillIconButton(icon: "ctrl-connectors", isOn: state.showConnectors,
                           action: { state.showConnectors.toggle() },
                           help: state.showConnectors ? "Hide connectors" : "Show connectors")
            PillIconButton(icon: "ctrl-grid", isOn: state.showGrid,
                           action: { state.showGrid.toggle() },
                           help: state.showGrid ? "Hide grid" : "Show grid")
            PillIconButton(icon: "ctrl-play", isOn: !state.videosShowPreviewOnly,
                           action: { state.videosShowPreviewOnly.toggle() },
                           help: state.videosShowPreviewOnly ? "Resume video playback"
                                                             : "Show video previews only")
        }
        .accessibilityIdentifier("canvas.controlsBar")
    }
}

// MARK: - Sidebar toggle (Figma 74:25877 open / 74:13420 closed)

struct SidebarToggleButton: View {
    @EnvironmentObject var state: CanvasState
    @State private var hover = false

    var body: some View {
        Button {
            withAnimation(Motion.popper) { state.showSidebar.toggle() }
        } label: {
            SVGIcon(name: state.showSidebar ? "sidebar-open" : "sidebar-closed", size: 24)
                .frame(height: 28)
                .frame(minWidth: 28)
                .padding(.horizontal, 4)
                .background(hover ? Color.black.opacity(0.06) : .clear,
                            in: Capsule(style: .continuous))
                .padding(4)
                .background(Color.white.opacity(0.6), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(Color.black.opacity(0.04), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.02), radius: 2.5, y: 4)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(state.showSidebar ? "Hide sidebar" : "Show sidebar")
        .accessibilityIdentifier("canvas.sidebarToggle")
    }
}
