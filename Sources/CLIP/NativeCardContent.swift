import AppKit
import AVFoundation

/// Native (AppKit) card content — the start of replacing the SwiftUI-hosted
/// cards with native views per type, mirroring Spatial's `CanvasItemView` /
/// `Canvas*View` architecture. Each type renders directly into an NSView that
/// fills `CardItemView`; chrome (rounded corners, shadow, selection) lives on
/// the item layer.
///
/// Migration is incremental: `makeNativeCardContent` returns `nil` for kinds
/// not yet ported, and `CardItemView` falls back to hosting the SwiftUI card so
/// nothing breaks mid-migration.
@MainActor
func makeNativeCardContent(for node: CanvasNode) -> NSView? {
    switch node.kind {
    case .image(let data, _):
        return CardImageContentView(data: data)
    case .video(let fileURL, _):
        return CardVideoContentView(fileURL: fileURL,
                                    trimStart: node.trimStart, trimEnd: node.trimEnd)
    default:
        // tweet / instagram / youtube / webclip / text / drawing / sticky /
        // section — still SwiftUI for now (see task #17).
        return nil
    }
}

/// Native image card: a CALayer showing the decoded image, aspect-fill, clipped
/// to the card's rounded corners. (Spatial's `CanvasImageView`.)
final class CardImageContentView: NSView {
    override var isFlipped: Bool { true }
    private let imageLayer = CALayer()

    init(data: Data) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CardChrome.cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        if let img = NSImage(data: data),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            imageLayer.contents = cg
        }
        layer?.addSublayer(imageLayer)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // No implicit animation, or the image would lerp during a resize.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    // Native content is non-interactive — CardItemView owns select/move/resize.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Native local-video card: an `AVPlayerLayer` (loop, muted, autoplay) over a
/// decoded first-frame poster, clipped to the rounded corners. Mirrors Spatial's
/// `CanvasVideoItem` (AVPlayer / AVPlayerLayer / AVPlayerLooper). Always-live to
/// match the current decoupled cards; semantic-zoom unload is a later pass.
final class CardVideoContentView: NSView {
    override var isFlipped: Bool { true }
    private let host = PlayerHostView()
    private let posterLayer = CALayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?

    init(fileURL: URL, trimStart: Double?, trimEnd: Double?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CardChrome.cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        posterLayer.contentsGravity = .resizeAspectFill
        posterLayer.masksToBounds = true
        layer?.addSublayer(posterLayer)
        if let poster = VideoPosterStore.cachedPoster(for: fileURL) {
            posterLayer.contents = poster.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else {
            Task { @MainActor in
                if let p = await VideoPosterStore.poster(for: fileURL) {
                    posterLayer.contents = p.cgImage(forProposedRect: nil, context: nil, hints: nil)
                }
            }
        }

        host.translatesAutoresizingMaskIntoConstraints = false
        host.playerLayer.cornerRadius = CardChrome.cornerRadius
        host.playerLayer.masksToBounds = true
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let item = AVPlayerItem(url: fileURL)
        let player = AVQueuePlayer()
        if let s = trimStart, let e = trimEnd, e > s {
            let range = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                                    end: CMTime(seconds: e, preferredTimescale: 600))
            looper = AVPlayerLooper(player: player, templateItem: item, timeRange: range)
            player.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            looper = AVPlayerLooper(player: player, templateItem: item)
        }
        player.isMuted = true
        self.player = player
        host.attach(player: player)
        player.play()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        posterLayer.frame = bounds
        CATransaction.commit()
    }

    // Pass-through: the AVPlayerLayer host must NOT swallow clicks — the
    // CardItemView owns select/move/resize.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit { player?.pause() }
}

/// Shared card-chrome constants so native content + the item chrome agree.
enum CardChrome {
    static let cornerRadius: CGFloat = 19.375
}
