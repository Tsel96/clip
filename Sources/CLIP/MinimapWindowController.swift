import SwiftUI
import AppKit

/// Owns a borderless-ish floating `NSPanel` that hosts `MinimapView` whenever
/// the user "detaches" the in-canvas minimap. Closing the panel from the OS
/// (red traffic light) reattaches it.
@MainActor
final class MinimapWindowController {
    private var panel: NSPanel?
    /// Strongly retained — NSWindow.delegate is `weak`.
    private var delegate: WindowDelegate?

    func show(state: CanvasState) {
        if let p = panel {
            p.makeKeyAndOrderFront(nil)
            return
        }

        let p = NSPanel(
            contentRect: NSRect(x: 200, y: 400, width: 260, height: 240),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.title = "Minimap"
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false  // we manage the lifetime
        p.collectionBehavior.insert(.fullScreenAuxiliary)

        let host = NSHostingView(
            rootView: MinimapView()
                .environmentObject(state)
                .environmentObject(state.cameraStore)
                .frame(minWidth: 160, minHeight: 140)
        )
        p.contentView = host
        p.contentMinSize = NSSize(width: 180, height: 160)

        let d = WindowDelegate(state: state)
        self.delegate = d
        p.delegate = d

        self.panel = p
        p.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.close()
        panel = nil
        delegate = nil
    }
}

@MainActor
private final class WindowDelegate: NSObject, NSWindowDelegate {
    weak var state: CanvasState?
    init(state: CanvasState) { self.state = state }

    nonisolated func windowWillClose(_ notification: Notification) {
        // The delegate hop is on the main actor; capture self to reach state.
        Task { @MainActor [weak self] in
            // User closed the floating panel — flip back to in-window minimap.
            self?.state?.isMinimapDetached = false
        }
    }
}
