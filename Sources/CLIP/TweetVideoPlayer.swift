import SwiftUI
import AVKit
import AVFoundation
import AppKit

/// AVPlayer-backed view that loops, autoplays, and starts muted —
/// matching browser autoplay policies the prototype was built around.
struct TweetVideoPlayer: NSViewRepresentable {
    let url: URL
    /// Canvas node id — when set + `FeatureFlags.useWebViewCache`, the player is
    /// cached/reused across remounts (kills the select-blink). nil = no cache
    /// (e.g. lightbox / trim contexts).
    var nodeID: UUID? = nil
    @Binding var isMuted: Bool
    @Binding var isPlaying: Bool
    /// When non-zero, clips the player layer to a rounded rect of this
    /// corner radius. SwiftUI's `.clipShape` can't clip `AVPlayerLayer`
    /// contents on macOS 13, so the layer itself has to do it.
    var cornerRadius: CGFloat = 0
    /// Non-destructive trim: when set, the looper cycles only this range
    /// instead of the whole clip. `nil` = full clip.
    var timeRange: CMTimeRange? = nil

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        context.coordinator.install(in: view, url: url, timeRange: timeRange,
                                    nodeID: nodeID, useCache: FeatureFlags.useWebViewCache)
        context.coordinator.player?.isMuted = isMuted
        if isPlaying { context.coordinator.player?.play() }
        view.playerLayer.cornerRadius = cornerRadius
        view.playerLayer.masksToBounds = cornerRadius > 0
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        // Reinstall when the clip OR the loop range changes.
        if context.coordinator.url != url
            || !TweetVideoPlayer.rangesEqual(context.coordinator.timeRange, timeRange) {
            context.coordinator.install(in: nsView, url: url, timeRange: timeRange,
                                        nodeID: nodeID, useCache: FeatureFlags.useWebViewCache)
        }
        context.coordinator.player?.isMuted = isMuted
        if isPlaying {
            context.coordinator.player?.play()
        } else {
            context.coordinator.player?.pause()
        }
        nsView.playerLayer.cornerRadius = cornerRadius
        nsView.playerLayer.masksToBounds = cornerRadius > 0
    }

    static func dismantleNSView(_ nsView: PlayerHostView, coordinator: Coordinator) {
        // Cache mode: park the (muted, looping) player for a deferred teardown so a
        // select-remount reuses it instead of re-buffering (the tweet-video blink).
        if let id = coordinator.cacheNodeID, let player = coordinator.player, let url = coordinator.url {
            PlayerCache.shared.park(id, player: player, looper: coordinator.looper,
                                    url: url, timeRange: coordinator.timeRange)
            return
        }
        coordinator.tearDown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// CMTimeRange isn't reliably `Equatable` across SDKs — compare the
    /// start/duration CMTimes (which are) so we only reinstall on real change.
    static func rangesEqual(_ a: CMTimeRange?, _ b: CMTimeRange?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.start == y.start && x.duration == y.duration
        default: return false
        }
    }

    final class Coordinator {
        fileprivate(set) var url: URL?
        fileprivate(set) var timeRange: CMTimeRange?
        fileprivate(set) var player: AVQueuePlayer?
        fileprivate var looper: AVPlayerLooper?
        /// Non-nil when this player participates in the reuse cache.
        fileprivate var cacheNodeID: UUID?
        /// Watches the looper for `.failed` — see the dead-media guard below.
        fileprivate var looperStatusObs: NSKeyValueObservation?

        func install(in host: PlayerHostView, url: URL, timeRange: CMTimeRange?,
                     nodeID: UUID? = nil, useCache: Bool = false) {
            cacheNodeID = useCache ? nodeID : nil
            // Reuse a parked player for this node (same url + range) — skips the
            // re-buffer that shows as the select-blink black flash.
            if let id = cacheNodeID,
               let parked = PlayerCache.shared.take(id, url: url, timeRange: timeRange) {
                self.url = url
                self.timeRange = timeRange
                self.player = parked.player
                self.looper = parked.looper
                host.attach(player: parked.player)
                return
            }
            tearDown()
            cacheNodeID = useCache ? nodeID : nil   // tearDown() doesn't clear this
            self.url = url
            self.timeRange = timeRange
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            // Loop only the trimmed range when one is set, else the whole clip.
            if let timeRange {
                self.looper = AVPlayerLooper(player: player, templateItem: item, timeRange: timeRange)
                player.seek(to: timeRange.start, toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                self.looper = AVPlayerLooper(player: player, templateItem: item)
            }
            self.player = player
            host.attach(player: player)
            // Dead-media guard: a template item that can't play (expired
            // tweet CDN URL, deleted file) drives the looper to `.failed` —
            // tear the player down to its poster then. Left alone, failed
            // loopers churn item-advance callbacks on the main thread
            // forever; ~15 of them pinned it at ~67% and froze all canvas
            // input (2026-07-13).
            looperStatusObs = self.looper?.observe(\.status, options: [.new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                DispatchQueue.main.async { self?.tearDown() }
            }
        }

        func tearDown() {
            looperStatusObs?.invalidate()
            looperStatusObs = nil
            player?.pause()
            looper = nil
            player = nil
            url = nil
            timeRange = nil
        }
    }
}

/// NSView that hosts an AVPlayerLayer as a sublayer. Using a dedicated
/// sublayer (rather than replacing the backing layer) lets us reliably
/// resize the player to the view's bounds — when AVPlayerLayer is the
/// backing layer of a layer-hosting NSView, AppKit doesn't always
/// propagate bounds changes, leaving the video letterboxed.
final class PlayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // NEVER re-rasterize the backing layer on bounds/scale change. The video
        // lives in the `playerLayer` SUBLAYER (kept sized by `syncPlayerFrame`),
        // so the backing layer has nothing to draw — and `.duringViewResize` (the
        // layer-backed default) made AppKit clear+redraw it every time the card's
        // bounds/scale changed, which flashed as the "video blinks when zoom
        // starts/stops". `.never` lets the layer just scale on the GPU.
        layerContentsRedrawPolicy = .never
        playerLayer.videoGravity = .resizeAspectFill
        // Clear (not black): during a zoom SwiftUI rasterizes the card and the
        // AVPlayerLayer's video frame isn't captured by that snapshot — a black
        // backing then shows as the "video goes black while zooming" flash.
        // Transparent lets the poster behind (VideoNodeView's `.background`)
        // show through instead. Video fills the layer (resizeAspectFill) in
        // normal playback, so the clear backing is only ever seen mid-zoom/load.
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        syncPlayerFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncPlayerFrame()
    }

    private func syncPlayerFrame() {
        // Keep CALayer geometry changes free of implicit animations
        // (otherwise the video would lerp during canvas resize).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func attach(player: AVPlayer) {
        playerLayer.player = player
    }
}

// MARK: - Player reuse cache

/// The AVPlayer-side counterpart to `WebViewCache`: parks `AVQueuePlayer`s by
/// node id so a select-remount reattaches a warm, still-looping player instead
/// of allocating + re-buffering a new one (the tweet-video "blink"). Gated by
/// `FeatureFlags.useWebViewCache`. Tweet players are muted, so a briefly parked
/// (not-yet-torn-down) player stays silent.
final class PlayerCache {
    static let shared = PlayerCache()
    private init() {}

    private struct Parked {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper?
        let url: URL
        let timeRange: CMTimeRange?
    }

    private var parked: [UUID: Parked] = [:]
    private var teardowns: [UUID: Timer] = [:]

    /// Hold a player for reuse; if not reclaimed within ~1.2 s, pause + drop it.
    func park(_ id: UUID, player: AVQueuePlayer, looper: AVPlayerLooper?,
              url: URL, timeRange: CMTimeRange?) {
        teardowns[id]?.invalidate()
        parked[id] = Parked(player: player, looper: looper, url: url, timeRange: timeRange)
        teardowns[id] = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.parked[id]?.player.pause()
            self.parked[id] = nil
            self.teardowns[id] = nil
        }
    }

    /// Reclaim a parked player iff it matches the requested url + loop range.
    /// Cancels the pending teardown (the node came back).
    func take(_ id: UUID, url: URL, timeRange: CMTimeRange?)
        -> (player: AVQueuePlayer, looper: AVPlayerLooper?)? {
        guard let p = parked[id], p.url == url,
              TweetVideoPlayer.rangesEqual(p.timeRange, timeRange) else { return nil }
        teardowns[id]?.invalidate()
        teardowns[id] = nil
        parked[id] = nil
        return (p.player, p.looper)
    }

    /// Force-evict (e.g. on node deletion) — tears down immediately.
    func evict(_ id: UUID) {
        teardowns[id]?.invalidate(); teardowns[id] = nil
        parked[id]?.player.pause()
        parked[id] = nil
    }
}
