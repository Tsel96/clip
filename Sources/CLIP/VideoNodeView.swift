import SwiftUI
import AppKit
import AVFoundation

/// Local video card. Reuses `TweetVideoPlayer` (an `AVPlayerLayer`-backed
/// view that loops + autoplays muted), and adds hover-revealed mute / play
/// controls.
///
/// **Semantic zoom.** When `isLive` is false (off-viewport or projected
/// below the breakpoint) the `TweetVideoPlayer` is unmounted entirely —
/// SwiftUI's tree diff calls `dismantleNSView`, which tears down the
/// `AVPlayer`, the `AVPlayerLooper`, the decoder threads, and the GPU
/// texture. A dozen video cards on a zoomed-out canvas don't keep a
/// dozen video decoders alive; only the cards the user is actually
/// looking at decode. When the user zooms back in, the player re-mounts
/// and resumes playback after a brief load. The resting state shows the
/// video's decoded first-frame poster (see `VideoPosterStore`).
struct VideoNodeView: View {
    let fileURL: URL
    let filename: String
    let isLive: Bool
    /// Non-destructive trim (seconds). When both are set the player loops
    /// only `[trimStart, trimEnd]`; otherwise the whole clip.
    var trimStart: Double? = nil
    var trimEnd: Double? = nil
    /// Tapped to open the inline trim editor. When `nil` the scissors
    /// control is hidden (e.g. in the lightbox, where trimming isn't
    /// offered). Lives in the hover cluster beside play/mute because a
    /// SwiftUI `.overlay` doesn't reliably composite above the card's
    /// `AVPlayerLayer`, but these sibling controls do.
    var onTrim: (() -> Void)? = nil
    /// When true the control cluster (scissors / play / mute) stays
    /// revealed even without hover — so selecting a video surfaces its
    /// actions, matching how cards are normally acted on.
    var isSelected: Bool = false

    /// The loop range to feed the player, or nil for the full clip.
    private var trimRange: CMTimeRange? {
        guard let s = trimStart, let e = trimEnd, e > s else { return nil }
        return CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                           end:   CMTime(seconds: e, preferredTimescale: 600))
    }

    /// User's explicit play/pause preference. Wins over `isLive` only as
    /// an off-switch (paused + zoomed-in stays paused). On-switch alone
    /// is not enough — must also be in viewport at adequate size. Videos
    /// autoplay at rest; `isLive` drops them to a poster during a pan/zoom
    /// (see CanvasState.isCameraInteracting), so no live AVPlayer is
    /// transformed while the camera moves.
    @State private var userPlaying = true
    @State private var isMuted = true
    @State private var hovering = false
    /// Decoded first-frame poster, shown by the resting placeholder.
    @State private var poster: NSImage? = nil

    /// Composited gate the player obeys when it's mounted.
    private var effectivePlaying: Bool { userPlaying && isLive }

    var body: some View {
        ZStack {
            if isLive {
                TweetVideoPlayer(
                    url: fileURL,
                    isMuted: $isMuted,
                    isPlaying: .constant(effectivePlaying),
                    cornerRadius: 19.375,
                    timeRange: trimRange
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

                // Mute / play / trim controls. Always faintly visible so
                // they're discoverable without cursor-sweeping (hiding
                // controls behind hover breaks spatial memory); hover or
                // selection brings them to full strength. Only mounted
                // while the card is live — the user has no reason (or
                // way) to interact with a paused-and-unmounted card.
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 6) {
                            if let onTrim {
                                Button(action: onTrim) {
                                    Image(systemName: "scissors")
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Trim video")
                            }

                            Button { userPlaying.toggle() } label: {
                                Image(systemName: userPlaying ? "pause.fill" : "play.fill")
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(userPlaying ? "Pause" : "Play")

                            Button { isMuted.toggle() } label: {
                                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(isMuted ? "Unmute" : "Mute")
                        }
                        .padding(8)
                    }
                }
                .opacity((hovering || isSelected) ? 1 : 0.45)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: isSelected)
            } else {
                // Resting state — no AVPlayer in the view tree.
                placeholder
            }
        }
        .figmaCardStyle(isElevated: hovering)
        .onHover { hovering = $0 }
        // Decode the first-frame poster once (cached process-wide) so the
        // resting placeholder — semantic-zoom or "previews only" mode —
        // shows real content instead of a black box.
        .task(id: fileURL) {
            poster = await VideoPosterStore.poster(for: fileURL)
        }
    }

    /// Resting state for a non-live video card: the decoded first-frame
    /// poster when ready, else a flat black surface with a film glyph.
    @ViewBuilder
    private var placeholder: some View {
        ZStack {
            Color.black
            if let poster {
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Process-wide first-frame poster cache for local video cards. A video's
/// opening frame is decoded once (off the main actor) and reused for every
/// resting-state render — the semantic-zoom poster and "previews only"
/// mode both pull from here, so a card never shows a black box once warm.
@MainActor
enum VideoPosterStore {
    private static var cache: [URL: NSImage] = [:]

    /// Cached poster for `url`, decoding + caching on first request.
    static func poster(for url: URL) async -> NSImage? {
        if let hit = cache[url] { return hit }
        let image = await decodeFirstFrame(url)
        if let image { cache[url] = image }
        return image
    }

    /// Synchronous cache hit — returns the cached poster if it's already
    /// been decoded by an earlier `poster(for:)` request, `nil` if not.
    /// Used by the card-stack ghost view so a warm cache renders the
    /// thumbnail in the same frame the ghost appears, with no flash of
    /// the placeholder fallback.
    static func cachedPoster(for url: URL) -> NSImage? {
        cache[url]
    }

    private static func decodeFirstFrame(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 640, height: 640)
            // A frame ~0.5 s in dodges fade-from-black intros — same
            // offset ColorExtraction.dominantColorForVideo uses.
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            let cg = (try? gen.copyCGImage(at: time, actualTime: nil))
                ?? (try? gen.copyCGImage(at: .zero, actualTime: nil))
            guard let cg else { return nil }
            return NSImage(cgImage: cg,
                           size: NSSize(width: cg.width, height: cg.height))
        }.value
    }
}
