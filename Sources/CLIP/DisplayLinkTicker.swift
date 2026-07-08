import AppKit
import QuartzCore

/// Reusable self-pausing CADisplayLink wrapper (the `canvasRefreshLink`
/// pattern, extracted): created lazily from a view (the link needs a view in a
/// window), paused whenever idle so it costs nothing at rest. Ticks deliver a
/// clamped `dt` so spring integrations can't explode after a stalled frame.
/// macOS 14+ only — callers fall back to a direct jump where unavailable.
final class DisplayLinkTicker: NSObject {
    private var link: AnyObject?          // CADisplayLink, type-erased for pre-14
    private weak var view: NSView?
    private let onTick: (CFTimeInterval) -> Void
    private var lastTime: CFTimeInterval = 0
    private(set) var isRunning = false

    init(view: NSView, onTick: @escaping (CFTimeInterval) -> Void) {
        self.view = view
        self.onTick = onTick
    }

    func start() {
        guard #available(macOS 14.0, *) else { return }
        if link == nil, let v = view {
            let l = v.displayLink(target: self, selector: #selector(tick))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        }
        lastTime = CACurrentMediaTime()
        isRunning = true
        (link as? CADisplayLink)?.isPaused = false
    }

    func stop() {
        isRunning = false
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.isPaused = true }
    }

    func invalidate() {
        isRunning = false
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
        link = nil
    }

    @objc private func tick() {
        guard isRunning else { stop(); return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastTime, 1.0 / 30.0)
        lastTime = now
        onTick(dt)
    }
}
