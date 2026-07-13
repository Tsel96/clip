import SwiftUI
import AppKit

/// Hooks `NSEvent.addLocalMonitorForEvents` so we receive scroll-wheel,
/// pinch (magnify) and pointer-move events anywhere over the canvas
/// window — including over the tweet cards, where a normal NSView
/// wouldn't get them because the card's NSHostingView swallows them
/// first.
struct CanvasEventMonitor: NSViewRepresentable {
    var onScroll: (_ dx: CGFloat, _ dy: CGFloat, _ modifiers: NSEvent.ModifierFlags, _ location: CGPoint) -> Void
    var onMagnify: (_ delta: CGFloat, _ location: CGPoint) -> Void
    var onBackgroundClick: () -> Void
    /// Cursor position in canvas-view coordinates while it's over the
    /// canvas (hover *and* drag); `nil` once it leaves. Drives the grid
    /// spotlight — never consumes the event.
    var onPointerMove: (_ location: CGPoint?) -> Void
    /// When false (native NSScrollView canvas), don't consume scroll/magnify —
    /// let the scroll view own pan/zoom. Pointer-move + background-click stay.
    var capturesScrollMagnify: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll, onMagnify: onMagnify,
                    onBackgroundClick: onBackgroundClick, onPointerMove: onPointerMove)
    }

    func makeNSView(context: Context) -> NSView {
        let view = BackgroundClickView()
        view.onClick = onBackgroundClick
        context.coordinator.attach(toWindowOf: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.onMagnify = onMagnify
        context.coordinator.onBackgroundClick = onBackgroundClick
        context.coordinator.onPointerMove = onPointerMove
        context.coordinator.capturesScrollMagnify = capturesScrollMagnify
        if let v = nsView as? BackgroundClickView { v.onClick = onBackgroundClick }
        // Re-attach in case the host view moved windows after creation.
        context.coordinator.attach(toWindowOf: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onScroll: (CGFloat, CGFloat, NSEvent.ModifierFlags, CGPoint) -> Void
        var onMagnify: (CGFloat, CGPoint) -> Void
        var onBackgroundClick: () -> Void
        var onPointerMove: (CGPoint?) -> Void
        var capturesScrollMagnify = true

        private weak var ownerWindow: NSWindow?
        private weak var ownerView: NSView?
        private var monitor: Any?

        init(onScroll: @escaping (CGFloat, CGFloat, NSEvent.ModifierFlags, CGPoint) -> Void,
             onMagnify: @escaping (CGFloat, CGPoint) -> Void,
             onBackgroundClick: @escaping () -> Void,
             onPointerMove: @escaping (CGPoint?) -> Void) {
            self.onScroll = onScroll
            self.onMagnify = onMagnify
            self.onBackgroundClick = onBackgroundClick
            self.onPointerMove = onPointerMove
        }

        func attach(toWindowOf view: NSView) {
            ownerView = view
            // Defer until the view is in a window.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let win = view?.window else { return }
                if self.monitor != nil && self.ownerWindow === win { return }
                self.detach()
                self.ownerWindow = win
                // `.mouseMoved` is only posted when the window opts in.
                win.acceptsMouseMovedEvents = true
                self.monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.scrollWheel, .magnify, .mouseMoved, .leftMouseDragged]
                ) { [weak self] event in
                    guard let self,
                          let target = self.ownerView,
                          event.window === self.ownerWindow else { return event }

                    // Convert the cursor to the canvas view's coordinate space.
                    let pointInView = target.convert(event.locationInWindow, from: nil)
                    let inside = target.bounds.contains(pointInView)

                    switch event.type {
                    case .mouseMoved, .leftMouseDragged:
                        // Report the cursor for the grid spotlight (hover
                        // and drag). NEVER consume — cards still need
                        // these events for their own hover / drag.
                        self.onPointerMove(inside ? pointInView : nil)
                        return event
                    case .scrollWheel:
                        Diag.log("MONITOR.scroll inside=\(inside) captures=\(self.capturesScrollMagnify) dy=\(event.scrollingDeltaY)")
                        guard inside, self.capturesScrollMagnify else { return event }
                        // AppKit returns scrolls with positive dy = scroll up. Our flipped
                        // canvas (top-left origin) wants positive y = move down. Pass the
                        // raw deltas through; the camera math handles the sign.
                        self.onScroll(
                            event.scrollingDeltaX,
                            event.scrollingDeltaY,
                            event.modifierFlags,
                            pointInView
                        )
                        return nil   // consume — we panned/zoomed
                    case .magnify:
                        guard inside, self.capturesScrollMagnify else { return event }
                        self.onMagnify(event.magnification, pointInView)
                        return nil
                    default:
                        return event
                    }
                }
            }
        }

        func detach() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
            ownerWindow = nil
        }
    }
}

/// Transparent NSView that forwards plain mouse-down to a SwiftUI callback.
/// Used to deselect when the user clicks empty canvas.
private final class BackgroundClickView: NSView {
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
