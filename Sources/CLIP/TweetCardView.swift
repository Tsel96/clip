import SwiftUI
import AVFoundation
import ImageIO

/// A tweet card on the canvas. Per the Figma spec, the card is JUST the
/// media — video, photo, or a centered text excerpt for text-only tweets.
/// Metadata (author, body, likes, etc.) is intentionally not shown on the card.
///
/// **Semantic zoom.** Video tweets respect `isLive` — when false the
/// `TweetVideoPlayer` is unmounted entirely (tearing down the
/// `AVPlayer`) and we render the tweet's poster image as a static
/// thumbnail. Photo and text-only tweets are unaffected.
///
/// **Trim.** A video tweet plays the direct MP4 (`bestVideoURL`) through the
/// same `TweetVideoPlayer` local videos use, so it trims identically:
/// `trimStart`/`trimEnd` loop a sub-range, and the inline `VideoTrimOverlay`
/// (hosted here, since this view owns the resolved URL) edits that range.
struct TweetCardView: View {
    let url: String
    /// Canvas node id — forwarded to `TweetVideoPlayer` for the player reuse
    /// cache (the tweet-video blink fix). nil in non-canvas contexts.
    var nodeID: UUID? = nil
    /// Computed by `CanvasState.isLive` upstream — true when the card is
    /// in the viewport AND projected at a meaningful screen size. Photo
    /// / text tweets ignore this; only video tweets gate the AVPlayer.
    var isLive: Bool = true
    /// Non-destructive trim (seconds) for the embedded video. When both are
    /// set the player loops only `[trimStart, trimEnd]`.
    var trimStart: Double? = nil
    var trimEnd: Double? = nil
    /// Keep the controls (incl. scissors) revealed while the card is selected.
    var isSelected: Bool = false
    /// True while THIS card is in the inline trim editor.
    var isTrimming: Bool = false
    /// Enter trim mode (reveals the scissors). Nil hides the trim control.
    var onTrim: (() -> Void)? = nil
    /// Commit / reset / cancel callbacks for the inline trim editor.
    var onSaveTrim: ((Double, Double) -> Void)? = nil
    var onResetTrim: (() -> Void)? = nil
    var onCancelTrim: (() -> Void)? = nil
    /// Reports the resolved direct-MP4 URL once the tweet loads, so the top-level
    /// trim widget can open for this (social) video without re-resolving.
    var onResolveVideoURL: ((URL) -> Void)? = nil
    /// Called once the media aspect is known (loaded from the poster) so the
    /// node can size to it — kills the gray gap around the aspect-fit card.
    var onMediaAspect: ((CGFloat) -> Void)? = nil

    @State private var tweet: TweetData? = nil
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    /// width / height of the tweet's media, derived from the poster so the card
    /// sizes to the video/photo aspect (shows it fully instead of cropping it).
    @State private var mediaAspect: CGFloat? = nil
    @State private var isMuted = true
    @State private var userPlaying = true
    @State private var hovering = false

    private var tweetID: String? { TweetService.extractTweetID(from: url) }

    /// Composited gate for the video sub-view.
    private var effectivePlaying: Bool { userPlaying && isLive }

    /// Loop range fed to the player, or nil for the whole clip.
    private var trimRange: CMTimeRange? {
        guard let s = trimStart, let e = trimEnd, e > s else { return nil }
        return CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                           end:   CMTime(seconds: e, preferredTimescale: 600))
    }

    var body: some View {
        content
            // Size the card to the media's aspect ratio so the whole video /
            // photo shows. `nil` (text tweet, or not-yet-loaded) → natural size.
            .aspectRatio(mediaAspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .figmaCardStyle(isElevated: hovering)
            .overlay(alignment: .bottomTrailing) { videoControls }
            // Trim editor is no longer in-card: it's a TOP-LEVEL widget mounted
            // in CanvasView, BELOW the card (above the input layer so it's
            // clickable). `onResolveVideoURL` feeds it this tweet's MP4 URL.
            .onHover { hovering = $0 }
            .task(id: url) { await load() }
            .task(id: tweet?.posterURL) { await loadMediaAspect() }
    }

    /// Read just the pixel dimensions of the poster (cheap header read) to learn
    /// the media's aspect ratio, off the main thread.
    private func loadMediaAspect() async {
        guard let posterURL = tweet?.posterURL else { return }
        let aspect = await Task.detached(priority: .utility) { () -> CGFloat? in
            guard let src = CGImageSourceCreateWithURL(posterURL as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
                  let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
                  w > 0, h > 0 else { return nil }
            return w / h
        }.value
        if let aspect { mediaAspect = aspect; onMediaAspect?(aspect) }
    }

    // MARK: - Card body

    @ViewBuilder
    private var content: some View {
        if tweetID == nil {
            placeholder(symbol: "link.badge.plus", text: "Invalid Twitter / X URL")
        } else if let tweet, let videoURL = tweet.bestVideoURL {
            ZStack {
                // PERSISTENT poster behind the player. When the AVPlayer is torn
                // down (rested for perf / zoomed out), this identical decoded
                // frame is ALREADY on screen — so the stop is seamless: no black
                // flash, no reload blink. It also backs the player while it loads
                // its first frame (the AVPlayerLayer is clear), and stays warm
                // while the player is live so it's instant the moment it's needed.
                videoPlaceholder(posterURL: tweet.posterURL)
                if isLive {
                    TweetVideoPlayer(
                        url: videoURL,
                        nodeID: nodeID,
                        isMuted: $isMuted,
                        isPlaying: .constant(effectivePlaying),
                        cornerRadius: 1,
                        timeRange: trimRange
                    )
                }
            }
        } else if let tweet, tweet.hasPhoto, let posterURL = tweet.posterURL {
            AsyncImage(url: posterURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                case .empty, .failure:
                    Color(nsColor: .windowBackgroundColor)
                @unknown default:
                    Color(nsColor: .windowBackgroundColor)
                }
            }
            .clipped()
        } else if let tweet {
            // Text-only tweet — show a centered excerpt so the card isn't empty.
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let text = tweet.text, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 16))
                        .multilineTextAlignment(.center)
                        .lineLimit(6)
                        .padding(24)
                        .foregroundStyle(.primary)
                }
            }
        } else if let msg = errorMessage {
            // Network / decode failures are transient — offer a retry
            // instead of leaving the card permanently stuck on the error.
            placeholder(symbol: "exclamationmark.bubble", text: msg) {
                Task { await load() }
            }
        } else {
            placeholder(symbol: nil, text: isLoading ? "Loading…" : "")
        }
    }

    @ViewBuilder
    private func placeholder(
        symbol: String?, text: String, retry: (() -> Void)? = nil
    ) -> some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                if !text.isEmpty {
                    Text(text).font(.callout).foregroundStyle(.secondary)
                }
                if let retry {
                    Button("Retry", action: retry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    /// Resting state for a video tweet below the live breakpoint. Uses
    /// the tweet's poster image when available (cheap static CALayer)
    /// and falls back to a flat black surface with a film glyph.
    @ViewBuilder
    private func videoPlaceholder(posterURL: URL?) -> some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let posterURL {
                AsyncImage(url: posterURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    case .empty, .failure:
                        Image(systemName: "film")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(.secondary)
                    @unknown default:
                        Color.clear
                    }
                }
                .clipped()
            } else {
                Image(systemName: "film")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Hover-revealed video controls

    @ViewBuilder
    private var videoControls: some View {
        // Always faintly visible (discoverability — no hide-on-hover);
        // hover or selection brings them to full strength.
        let revealed = hovering || isSelected
        if let tweet, tweet.bestVideoURL != nil, isLive, !isTrimming {
            // Figma 88-360/367/373: 60%-white circular buttons, shown only on
            // hover/selection (hidden otherwise).
            HStack(spacing: 6) {
                if let onTrim {
                    VideoCircleButton(systemName: "scissors", help: "Trim video", action: onTrim)
                }
                VideoCircleButton(systemName: userPlaying ? "pause.fill" : "play.fill",
                                  help: userPlaying ? "Pause" : "Play") { userPlaying.toggle() }
                VideoCircleButton(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                  help: isMuted ? "Unmute" : "Mute") { isMuted.toggle() }
            }
            .padding(8)
            .opacity(revealed ? 1 : 0)
            .animation(.easeOut(duration: 0.14), value: hovering)
            .animation(.easeOut(duration: 0.14), value: isSelected)
        }
    }

    /// Inline trim editor over the card while active. Uses the tweet's
    /// resolved direct-MP4 `bestVideoURL` (a remote URL — `AVPlayer` and the
    /// filmstrip generator both stream it fine).
    @ViewBuilder
    private var trimEditor: some View {
        if isTrimming, let videoURL = tweet?.bestVideoURL,
           let onSaveTrim, let onResetTrim, let onCancelTrim {
            VideoTrimOverlay(
                fileURL: videoURL,
                initialStart: trimStart,
                initialEnd: trimEnd,
                cornerRadius: 1,
                onSave: onSaveTrim,
                onReset: onResetTrim,
                onCancel: onCancelTrim
            )
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let id = tweetID else {
            errorMessage = "Invalid Twitter / X URL"
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            tweet = try await TweetService.fetch(tweetID: id)
            if let v = tweet?.bestVideoURL { onResolveVideoURL?(v) }   // feed the top-level trim widget
        } catch let err as TweetServiceError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
