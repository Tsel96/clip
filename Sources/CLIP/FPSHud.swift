import SwiftUI
import AppKit
import QuartzCore

/// Lightweight FPS meter. Drives off a `CADisplayLink` on the MAIN runloop, so a
/// busy main thread (jank) delays the callbacks and the measured rate drops —
/// i.e. it reflects the app's real, perceived frame rate, not just the display
/// refresh. Shown as a tiny HUD so performance is measurable at a glance.
final class FPSMonitor: ObservableObject {
    @Published var fps: Int = 0
    @Published var lowest: Int = 0          // worst FPS seen in the last few seconds
    private var frames = 0
    private var windowStart: CFTimeInterval = 0
    private var lowestPending = Int.max
    private var lowestStart: CFTimeInterval = 0

    func tick(now: CFTimeInterval) {
        if windowStart == 0 { windowStart = now; lowestStart = now }
        frames += 1
        let dt = now - windowStart
        if dt >= 0.5 {
            let value = Int((Double(frames) / dt).rounded())
            fps = value
            lowestPending = min(lowestPending, value)
            frames = 0
            windowStart = now
        }
        // Reset the "lowest" window every 3s so a one-off stall doesn't stick.
        if now - lowestStart >= 3 {
            lowest = lowestPending == .max ? fps : lowestPending
            lowestPending = .max
            lowestStart = now
        }
    }
}

/// Hidden probe view that owns the display link (it needs a view in a window).
private struct FPSProbe: NSViewRepresentable {
    let monitor: FPSMonitor
    func makeNSView(context: Context) -> NSView { ProbeView(monitor: monitor) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ProbeView: NSView {
        let monitor: FPSMonitor
        private var link: AnyObject?      // CADisplayLink (macOS 14+) stored type-erased
        init(monitor: FPSMonitor) { self.monitor = monitor; super.init(frame: .zero) }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.invalidate() }
            link = nil
            guard window != nil else { return }
            if #available(macOS 14.0, *) {
                let l = displayLink(target: self, selector: #selector(step))
                l.add(to: .main, forMode: .common)
                link = l
            }
        }
        @objc private func step() { monitor.tick(now: CACurrentMediaTime()) }
    }
}

/// The on-screen meter: current FPS + the lowest in the recent window, tinted
/// red when it dips. A discreet capsule.
struct FPSHud: View {
    @StateObject private var monitor = FPSMonitor()
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(monitor.fps) fps")
                .monospacedDigit()
            Text("· min \(monitor.lowest)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .background(FPSProbe(monitor: monitor).frame(width: 0, height: 0))
        .allowsHitTesting(false)
    }
    private var color: Color {
        let f = monitor.fps
        return f >= 55 ? .green : (f >= 30 ? .yellow : .red)
    }
}
