import SwiftUI
import AppKit

/// Apple-style "stacked cards" decoration drawn BEHIND a node's normal
/// content when it's the head of a `groupID` cluster. Each hidden member
/// renders as one ghost card at a progressively deeper offset + slight
/// alternating rotation; ghosts show the member's actual cover (decoded
/// image data, video first-frame poster, sticky / section color, etc.)
/// so the user can tell what's inside the deck without ungrouping.
///
/// For a 2-card stack there's exactly **one** ghost behind the head; for
/// 3+ cards we draw two ghosts and show a "·N" count badge in the
/// top-right corner. The hard cap of three rendered ghosts matches
/// Apple's Photos albums (more cards just bumps the badge).
struct StackVisualView: View {
    /// Every group member EXCEPT the head, ordered by uuid string (so
    /// the ordering is stable across re-renders). The first element in
    /// the array is drawn closest to the head; later elements are
    /// rendered with deeper offset.
    let hiddenMembers: [CanvasNode]
    /// World-space size of the head card. Every ghost matches this
    /// size so the deck reads as "N similar cards stacked."
    let cardSize: CGSize
    /// Corner radius matching the head card's chrome so the ghost
    /// silhouettes line up with the top card's rounded corners.
    let cornerRadius: CGFloat
    /// Auto-derived group label — "3 Photos", "2 Videos", "5 Items",
    /// etc. Rendered as a small material capsule below the head so
    /// the user can identify the deck at a glance.
    let groupLabel: String?

    /// Maximum ghosts ever rendered behind the head. More members just
    /// bump the count badge — matches Photos' album cover affordance.
    private static let maxGhosts: Int = 3

    private var visibleGhosts: [CanvasNode] {
        Array(hiddenMembers.prefix(Self.maxGhosts))
    }

    private var totalCount: Int { hiddenMembers.count + 1 }

    var body: some View {
        ZStack {
            // Render the farthest ghost first so closer ghosts paint
            // over it. `reversed()` on the enumerated sequence keeps
            // the index meaning consistent (index 0 = closest).
            ForEach(Array(visibleGhosts.enumerated()).reversed(), id: \.element.id) { depth, member in
                ghost(for: member, depth: depth)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .overlay(alignment: .topTrailing) {
            // Two-card stacks are visually self-explanatory (one card
            // peeking from behind). Three or more deserves a number.
            if totalCount >= 3 {
                countBadge
            }
        }
        .overlay(alignment: .bottom) {
            // Group label — auto-derived from member kinds. Floats just
            // below the head card so the deck always says what it is
            // (Photos / Videos / Items / etc.) without taking up grid
            // real estate.
            if let label = groupLabel {
                groupLabelChip(label)
                    .offset(y: 26)
            }
        }
        .allowsHitTesting(false)
    }

    /// Subtle material capsule rendered below the head card. Same
    /// `.regularMaterial` chrome family as the count pill so the two
    /// affordances feel related.
    @ViewBuilder
    private func groupLabelChip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5),
                                  lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }

    /// One ghost — sized to match the head, content drawn via
    /// `MemberCoverView`, offset + rotated by `depth`. Offset is a
    /// percentage of the head's size so larger cards expose more of
    /// each cover (a 36pt offset on a tiny 80×60 card looks the same as
    /// a 6pt sliver on a 600×400 card — bad). 9% diagonal × layer +
    /// ±5° per layer gives a clearly readable peek of every back card.
    @ViewBuilder
    private func ghost(for member: CanvasNode, depth: Int) -> some View {
        let step = CGFloat(depth + 1)
        let dxRatio: CGFloat = 0.09
        let dyRatio: CGFloat = 0.07
        let dx = (depth % 2 == 0 ? 1 : -1) * cardSize.width  * dxRatio * step
        let dy = cardSize.height * dyRatio * step
        let rotation: Double = (depth % 2 == 0 ? 1 : -1) * 5 * Double(step)
        let scale: CGFloat = 1.0 - CGFloat(depth) * 0.04
        let opacity = 1.0 - Double(depth) * 0.15

        MemberCoverView(member: member)
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            )
            .scaleEffect(scale, anchor: .center)
            .opacity(opacity)
            .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 6)
            .rotationEffect(.degrees(rotation), anchor: .center)
            .offset(x: dx, y: dy)
    }

    /// Floating count pill anchored to the head card's top-right corner.
    /// Subtle pink — same hue family as the Smart Selection chrome so
    /// the two grouping affordances feel related.
    @ViewBuilder
    private var countBadge: some View {
        Text("·\(totalCount)")
            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.pink.opacity(0.9), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .padding(6)
    }
}

// MARK: - Ghost thumbnail store
//
// A process-wide ObservableObject that the ghost-cover views observe.
// Owns its own `@Published` poster cache, so when a video's first-frame
// finishes decoding the views auto-re-render — no fragile reliance on
// per-view `@State` writes from inside a `.background()` modifier's
// async closure, which SwiftUI on macOS 13 doesn't propagate reliably.
//
// Internally delegates to `VideoPosterStore` so the actual decoding +
// caching logic stays in one place; this layer only adds the
// `ObservableObject` signal needed for ghost views.
@MainActor
final class GhostThumbnailStore: ObservableObject {
    static let shared = GhostThumbnailStore()

    @Published private(set) var posters: [URL: NSImage] = [:]
    /// Decoded image-data thumbnails, keyed by image node id (since the
    /// underlying `Data` isn't itself Hashable for dictionary keys).
    @Published private(set) var images: [UUID: NSImage] = [:]

    private init() {}

    /// Kick off an async poster decode if we don't already have it.
    /// Fast no-op if the poster is cached. Updates `posters` on success,
    /// which the observing views pick up via `@ObservedObject`.
    func loadVideoPoster(_ url: URL) {
        guard posters[url] == nil else { return }
        if let warm = VideoPosterStore.cachedPoster(for: url) {
            posters[url] = warm
            return
        }
        Task { [weak self] in
            let img = await VideoPosterStore.poster(for: url)
            guard let img else { return }
            self?.posters[url] = img
        }
    }

    /// Eager pre-warm entry point — used by `CanvasState` on launch to
    /// decode every video node's first-frame ahead of any UI that might
    /// need it (Smart Selection ghosts, semantic-zoom resting state).
    /// Awaitable so the caller can sequence multiple decodes if needed.
    func preload(videoAt url: URL) async {
        guard posters[url] == nil else { return }
        if let warm = VideoPosterStore.cachedPoster(for: url) {
            posters[url] = warm
            return
        }
        if let img = await VideoPosterStore.poster(for: url) {
            posters[url] = img
        }
    }

    /// Decode `Data` into an `NSImage` once and cache it. The image-data
    /// node already validated this data at insert-time so the decode
    /// almost always succeeds; we still guard against a nil result.
    func loadImage(id: UUID, data: Data) {
        guard images[id] == nil else { return }
        Task { [weak self] in
            let img = await Task.detached(priority: .userInitiated) {
                NSImage(data: data)
            }.value
            guard let img else { return }
            self?.images[id] = img
        }
    }
}

// MARK: - Member cover view

/// One ghost's cover content. Per-kind dispatch reads its decoded
/// thumbnail from the shared `GhostThumbnailStore`. The store's
/// `@Published` dictionaries drive re-renders when a poster lands,
/// so we don't have to keep our own per-view `@State` cache.
private struct MemberCoverView: View {
    let member: CanvasNode

    @ObservedObject private var thumbnails = GhostThumbnailStore.shared

    var body: some View {
        switch member.kind {
        case .image(let data, _):
            imageBody(data: data)
        case .video(let fileURL, _):
            videoBody(fileURL: fileURL)
        case .stickyNote(_, let color):
            color.swiftUIColor
        case .section(_, let color):
            color.swiftUIColor.opacity(0.55)
        case .text(let content, _):
            textBody(content: content)
        case .tweet(let url):
            TweetCoverView(tweetURL: url)
        case .instagram:
            instagramBody
        case .youtube:
            kindPlaceholder(systemName: "play.rectangle.fill")
        case .drawing:
            kindPlaceholder(systemName: "scribble")
        }
    }

    // MARK: Image

    @ViewBuilder
    private func imageBody(data: Data) -> some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let img = thumbnails.images[member.id] {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            thumbnails.loadImage(id: member.id, data: data)
        }
    }

    // MARK: Video

    @ViewBuilder
    private func videoBody(fileURL: URL) -> some View {
        // Use a dedicated `VideoCoverView` that owns its own @State
        // poster + `.task` — the exact pattern `VideoNodeView` uses
        // for its resting-state poster. Now that StackVisualView is a
        // ZStack peer of nodeContent (no longer passed through
        // `.background()`), this view participates in the normal
        // SwiftUI lifecycle and its `.task` fires reliably.
        VideoCoverView(fileURL: fileURL)
    }

    // MARK: Text

    @ViewBuilder
    private func textBody(content: String) -> some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            Text(content.isEmpty ? "Aa" : content)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .padding(8)
        }
    }

    // MARK: Instagram

    @ViewBuilder
    private var instagramBody: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.99, green: 0.79, blue: 0.30),
                    Color(red: 0.91, green: 0.21, blue: 0.45),
                    Color(red: 0.59, green: 0.18, blue: 0.74),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(0.55)
            Image(systemName: "camera.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    // MARK: Generic kind placeholder

    @ViewBuilder
    private func kindPlaceholder(systemName: String) -> some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            Image(systemName: systemName)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Video cover view

/// Tweet ghost cover. Tweets don't have a local poster file — they
/// have a URL whose metadata (including a remote `posterURL`) we have
/// to fetch via `TweetService.fetch`. The ghost mirrors what
/// `TweetCardView` paints in its resting state: an `AsyncImage` of the
/// embedded media's poster, or a fallback X-themed dark card with the
/// X logo if there's no media (text-only tweet) or the fetch fails.
private struct TweetCoverView: View {
    let tweetURL: String
    @State private var tweet: TweetData? = nil

    var body: some View {
        ZStack {
            // X.com dark-themed surface — matches the visual identity
            // of the live tweet card so the deck reads as "more tweets."
            Color.black
            if let url = tweet?.posterURL {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        tweetFallback
                    }
                }
            } else {
                tweetFallback
            }
        }
        .task(id: tweetURL) {
            // TweetService caches at the network layer (URLSession's
            // default disk cache) — repeated fetches of the same id are
            // ~5ms. First fetch typically 200–400ms.
            guard let id = TweetService.extractTweetID(from: tweetURL) else { return }
            tweet = try? await TweetService.fetch(tweetID: id)
        }
    }

    /// Static X-styled placeholder. Shown while the tweet metadata is
    /// fetching, or when the tweet has no media (text-only) and there
    /// is no `posterURL` to render.
    @ViewBuilder
    private var tweetFallback: some View {
        Image(systemName: "bird.fill")
            .font(.system(size: 28, weight: .regular))
            .foregroundStyle(.white.opacity(0.75))
    }
}

// MARK: - Video cover view

/// Mirror of `VideoNodeView`'s resting-state poster loader, isolated to
/// just the bits we need for a stack ghost. Owns its own `@State` poster
/// + `.task(id: fileURL)` — the same pattern that paints posters on the
/// canvas's live video cards. Now that StackVisualView is a ZStack peer
/// (instead of `.background(stackGhosts)`), this view's `.task` fires
/// reliably and the assignment to `@State poster` propagates through the
/// normal SwiftUI re-render path.
private struct VideoCoverView: View {
    let fileURL: URL
    @State private var poster: NSImage? = nil

    var body: some View {
        ZStack {
            // Black floor under everything — even if the poster has a
            // transparent fringe, the card always reads as solid.
            Color.black
            if let poster {
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // Film glyph only while the poster is genuinely still
                // decoding. The Image above covers this once available.
                Image(systemName: "film")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .task(id: fileURL) {
            // Sync cache hit returns instantly (microseconds); cold
            // cache awaits the AVAssetImageGenerator decode on a
            // detached task — typically 50–150 ms for a local file.
            poster = await VideoPosterStore.poster(for: fileURL)
        }
    }
}
