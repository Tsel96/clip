import AppKit
import QuartzCore

/// TEMPORARY zoom/render profiler (remove once the high-zoom FPS cause is found).
///
/// Writes one summary line per zoom gesture to `/tmp/clip_diag.txt`:
///   • actual FPS over the gesture (CADisplayLink frame count / wall time)
///   • main-thread `refreshChrome` cost per magnify tick (avg / max)
///   • the magnification range + scene counts (visible cards, connectors)
///
/// Reading it: if FPS is low while `refreshChrome` is cheap (< ~3 ms) → the cost
/// is GPU compositing (the big blurred shadows scaled by magnification), so the
/// fix is fading/capping shadows at high zoom. If `refreshChrome` is expensive →
/// the cost is main-thread path rebuilds (cards/connectors per tick).
/// All access happens on the main thread (display-link is added to the main
/// run-loop; `noteZoom` is called from the magnify callback), so the shared
/// mutable state is safe despite not being actor-isolated.
final class ZoomProfiler: NSObject {
    nonisolated(unsafe) static let shared = ZoomProfiler()
    private let path = "/tmp/clip_diag.txt"

    private var link: AnyObject?            // CADisplayLink at runtime (macOS 14+)
    private var running = false
    private var frames = 0
    private var windowStart = CACurrentMediaTime()
    private var lastTick = CACurrentMediaTime()
    private var refreshSamples: [Double] = []
    private var minMag = CGFloat.greatestFiniteMagnitude
    private var maxMag: CGFloat = 0
    private var items = 0
    private var connectors = 0

    /// Attach a display link off any on-screen view (paused until a zoom starts).
    func attach(to view: NSView) {
        guard link == nil, #available(macOS 14.0, *) else { return }
        let l = view.displayLink(target: self, selector: #selector(onFrame))
        l.isPaused = true
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func setPaused(_ paused: Bool) {
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.isPaused = paused }
    }

    /// Call once per magnify tick with the just-measured refresh cost + scene.
    func noteZoom(refreshMs: Double, mag: CGFloat, items: Int, connectors: Int) {
        if !running { startWindow() }
        refreshSamples.append(refreshMs)
        minMag = min(minMag, mag); maxMag = max(maxMag, mag)
        self.items = items; self.connectors = connectors
        lastTick = CACurrentMediaTime()
    }

    private func startWindow() {
        running = true
        frames = 0
        windowStart = CACurrentMediaTime()
        lastTick = windowStart
        refreshSamples.removeAll(keepingCapacity: true)
        minMag = .greatestFiniteMagnitude; maxMag = 0
        setPaused(false)
    }

    @objc private func onFrame() {
        frames += 1
        if CACurrentMediaTime() - lastTick > 0.35 { flush() }   // gesture ended
    }

    private func flush() {
        running = false
        setPaused(true)
        let dur = CACurrentMediaTime() - windowStart
        guard dur > 0.1, !refreshSamples.isEmpty else { return }
        let fps = Double(frames) / dur
        let avg = refreshSamples.reduce(0, +) / Double(refreshSamples.count)
        let mx = refreshSamples.max() ?? 0
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
        let line = String(format:
            "[%@] ZOOM mag %.2f→%.2f  %.0f fps / %.1fs  refreshChrome avg %.1fms max %.1fms  cards %d  connectors %d  (%d ticks)\n",
            fmt.string(from: Date()), minMag, maxMag, fps, dur, avg, mx, items, connectors, refreshSamples.count)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
