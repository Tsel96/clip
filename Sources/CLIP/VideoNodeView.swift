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
    /// While true (camera panning/zooming), cover the live player with its
    /// poster. The `AVPlayerLayer` renders BLACK under SwiftUI's `.scaleEffect`
    /// (the canvas zoom transform), so during a camera move we show the decoded
    /// frame instead — sharp, scales smoothly, and the player stays mounted so
    /// there's no teardown/reload thrash when the camera settles.
    var suppressLive: Bool = false
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

    /// Best poster available *right now*: the loaded one, else a synchronous
    /// process-wide cache hit. The cache fallback is what kills the black flash
    /// during zoom — when a card remounts (its `@State poster` reset to nil) or
    /// the live player is still loading its first frame, the decoded frame is
    /// already warm in `VideoPosterStore`, so we show it instead of black.
    private var posterImage: NSImage? {
        poster ?? VideoPosterStore.cachedPoster(for: fileURL)
    }

    /// Poster (or black) shown *behind* the live player while it (re)loads its
    /// first frame, and as the resting backdrop — never a bare black box.
    @ViewBuilder private var posterBackdrop: some View {
        if let img = posterImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Neutral, never black: a cold card reads as a light placeholder
            // tile instead of a black hole while its frame decodes.
            Color(nsColor: .windowBackgroundColor)
        }
    }

    var body: some View {
        ZStack {
            // Keep the player live through camera moves so video keeps playing
            // while you zoom. The clear AVPlayerLayer background means that if
            // SwiftUI rasterizes the card mid-zoom, the poster behind shows
            // through instead of black — never a black tile.
            if isLive {
                TweetVideoPlayer(
                    url: fileURL,
                    isMuted: $isMuted,
                    isPlaying: .constant(effectivePlaying),
                    cornerRadius: 1,
                    timeRange: trimRange
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(posterBackdrop)

                // Mute / play / trim controls — Figma 88-360/367/373: 60%-white
                // circular buttons. Shown ONLY on hover or selection (hidden
                // otherwise, per the design), springing in.
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
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
                    }
                }
                .opacity((hovering || isSelected) ? 1 : 0)
                .animation(.easeOut(duration: 0.14), value: hovering)
                .animation(.easeOut(duration: 0.14), value: isSelected)
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
            Color(nsColor: .windowBackgroundColor)
            if let img = posterImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Figma 88-360 / 88-367 / 88-373: a 60%-white circular control button shown on
/// video cards (mute / pause / trim). Black glyph, faint drop shadow; the parent
/// reveals the cluster only on hover or selection. Shared by `VideoNodeView`
/// (local video) and `TweetCardView` (tweet video) so they match.
struct VideoCircleButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black.opacity(0.82))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.85 : 0.6)))
                .shadow(color: .black.opacity(0.06), radius: 2.5, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
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

    /// Proactively decode posters for any of `urls` not already cached. Called
    /// as nodes load so a clip's first frame is ready *before* a zoom needs it:
    /// the camera-move poster cover (`VideoNodeView`) falls back to black on a
    /// cold cache, which is the "videos go black while zooming" symptom.
    static func warm(_ urls: [URL]) {
        for url in urls where cache[url] == nil {
            Task { _ = await poster(for: url) }
        }
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
