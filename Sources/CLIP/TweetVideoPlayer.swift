import SwiftUI
import AVKit
import AVFoundation
import AppKit

/// AVPlayer-backed view that loops, autoplays, and starts muted —
/// matching browser autoplay policies the prototype was built around.
struct TweetVideoPlayer: NSViewRepresentable {
    let url: URL
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
        context.coordinator.install(in: view, url: url, timeRange: timeRange)
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
            context.coordinator.install(in: nsView, url: url, timeRange: timeRange)
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
        private var looper: AVPlayerLooper?

        func install(in host: PlayerHostView, url: URL, timeRange: CMTimeRange?) {
            tearDown()
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
        }

        func tearDown() {
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
        layerContentsRedrawPolicy = .duringViewResize
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
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
