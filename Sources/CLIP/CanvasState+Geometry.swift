import SwiftUI
import AppKit
import AVFoundation
import Combine

// Split out of CanvasState.swift (god-object refactor): coordinate helpers + semantic-zoom render gate.
extension CanvasState {


    // MARK: - Coordinate helpers

    var viewportCentre: CGPoint {
        let size = viewportSize == .zero ? CGSize(width: 1000, height: 700) : viewportSize
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    func screenToWorld(point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - camera.x) / camera.zoom,
            y: (point.y - camera.y) / camera.zoom
        )
    }

    /// World-space rectangle currently visible on screen. Single source of
    /// truth for viewport-culling decisions — the minimap, the semantic-
    /// zoom playback gate, and any future "is this card on screen?" query
    /// all derive from here.
    var visibleWorldRect: CGRect {
        let size = viewportSize == .zero ? CGSize(width: 1000, height: 700) : viewportSize
        guard camera.zoom > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let z = camera.zoom
        return CGRect(
            x: -camera.x / z,
            y: -camera.y / z,
            width:  size.width  / z,
            height: size.height / z
        )
    }

    // MARK: - Semantic-zoom render gate
    //
    // From the thesis (ch. 5 — Významové přibližování / ch. 6 — Inteligentní
    // správa viditelného prostoru): heavy media is STATIC at low zoom and
    // comes alive only once a card crosses a defined breakpoint AND
    // remains inside the viewport. The resting state protects both the
    // user's cognitive centre of attention and machine performance — for
    // videos that means the AVPlayer is fully unmounted (no decoder
    // threads, no GPU texture, no looper); for images it means we skip
    // the full-resolution Image render and draw a lightweight placeholder.
    // Dozens of media cards can coexist because at most a handful are
    // actually decoding / compositing at any one moment.

    /// Minimum on-screen height (pt) below which a media card falls back to a
    /// static poster (level-of-detail) — keeps zoomed-out / peripheral cards
    /// cheap so a boardful of social/video cards still magnifies smoothly.
    static let livePlaybackMinScreenSide: CGFloat = 120

    /// IDs of the media nodes currently allowed to decode/play: media cards
    /// that intersect the (margin-expanded) viewport AND project at/above the
    /// size breakpoint, capped at `livePlaybackMaxConcurrent` nearest the
    /// viewport centre (the old uncapped product call froze the app on a
    /// 34-tweet board — see computeLiveMediaIDs).
    /// Memoised and keyed off `mediaGateEpoch` (which bumps only on camera
    /// SETTLE), so the set is frozen during a live pan/zoom — nothing flips
    /// live↔poster mid-gesture (no churn / no "videos stopped"); it re-evaluates
    /// once the camera stops.
    var liveMediaIDs: Set<UUID> {
        let key = (mediaGateEpoch, activePageIndex, nodes.count)
        if liveMediaCacheKey == key { return liveMediaCacheIDs }
        let ids = computeLiveMediaIDs()
        liveMediaCacheKey = key
        liveMediaCacheIDs = ids
        return ids
    }

    /// All media nodes that intersect the (margin-expanded) viewport and project
    /// at/above the size breakpoint. Cheap (≤ media-node count) — called only on
    /// a cache miss.
    /// Hard ceiling on simultaneously-live heavy-media cards. The previous
    /// product call was "no cap — any video even partly on screen plays";
    /// evidence killed it: a 34-tweet board put ~15 AVPlayerLoopers' item
    /// churn on the main thread (sampled at ~67% busy) and froze ALL canvas
    /// input. Nearest-to-viewport-center cards win the slots, so what the
    /// user is actually looking at still plays.
    static let livePlaybackMaxConcurrent = 8

    private func computeLiveMediaIDs() -> Set<UUID> {
        let vis = visibleWorldRect
        let liveRect = vis.insetBy(dx: -vis.width * 0.2, dy: -vis.height * 0.2)
        let center = CGPoint(x: vis.midX, y: vis.midY)
        var candidates: [(id: UUID, d2: CGFloat)] = []
        for node in nodes {
            switch node.kind {
            case .video, .tweet, .instagram, .youtube, .webclip: break
            default: continue
            }
            let h = renderedHeight(of: node)
            let r = CGRect(x: node.position.x, y: node.position.y, width: node.width, height: h)
            guard liveRect.intersects(r) else { continue }
            guard projectedScreenSide(of: node) >= Self.livePlaybackMinScreenSide else { continue }
            let dx = r.midX - center.x, dy = r.midY - center.y
            candidates.append((node.id, dx * dx + dy * dy))
        }
        if candidates.count > Self.livePlaybackMaxConcurrent {
            candidates.sort { $0.d2 < $1.d2 }
            candidates.removeLast(candidates.count - Self.livePlaybackMaxConcurrent)
        }
        return Set(candidates.map(\.id))
    }

    /// Below this projected on-screen size (pt), a card drops to its
    /// level-of-detail proxy (see `DraggableNode.isTiny`): content + position
    /// only, no per-card chrome/gestures. Keeps deep zoom-out cheap when the
    /// whole board is on screen and culling can't help.
    static let lodMinScreenSide: CGFloat = 14

    /// The card's smaller side projected through the current camera zoom.
    func projectedScreenSide(of node: CanvasNode) -> CGFloat {
        min(node.width, renderedHeight(of: node)) * camera.zoom
    }

    /// Whether the given node should render its heavy content. True iff
    /// (a) the node intersects the viewport and (b) its projected screen
    /// size meets the breakpoint. Non-media kinds always return true —
    /// there's nothing to gate (text, sticky, section, drawing all render
    /// cheaply at any size).
    func isLive(_ node: CanvasNode) -> Bool {
        // Lightbox open → every canvas card rests as a poster (nothing
        // composites behind the hero animation).
        if lightboxCardID != nil { return false }
        // The card being trimmed hands playback to the trim overlay's own
        // seekable player, so tear down its background loop player.
        if trimmingCardID == node.id { return false }
        // Only HEAVY media (video players / WKWebViews) is gated; text, sticky,
        // section, drawing, image render cheaply at any size → always live.
        switch node.kind {
        case .video, .tweet, .instagram, .youtube, .webclip:
            break
        default:
            return true
        }
        // "Show video previews only" — a user TOGGLE (not LOD) that forces
        // every video-bearing kind to its resting poster.
        if videosShowPreviewOnly {
            switch node.kind {
            case .video, .tweet, .instagram, .youtube: return false
            default: break
            }
        }
        // LEVEL OF DETAIL — the fix for the idle-heat root cause: a boardful of
        // tweet/video cards was decoding ALL of them at once (measured: ~13
        // AVPlayers, machine pinned + hot) because this method used to `return
        // true` unconditionally. Restore the gate so only a handful of media
        // cards are ever live:
        //
        // FROZEN during an active pan/zoom: liveness == the last-SETTLED live set
        // (`liveMediaIDs`, keyed off `mediaGateEpoch`). We do NOT re-evaluate the
        // viewport/size gates mid-gesture, so NO card mounts or unmounts while the
        // camera moves. That mount/unmount swap is exactly "videos blink while
        // zooming"; and the rapid per-tick churn over many zoom cycles is what
        // stranded AVPlayers in the reuse cache → "all videos stopped". Liveness
        // is recomputed the instant the camera settles (the `mediaGateEpoch` bump
        // in `setupMediaGate`), so cards resume playing on settle.
        if cameraMoving { return liveMediaIDs.contains(node.id) }

        // CAMERA SETTLED — full level-of-detail gate, then the concurrency cap:
        //  (a) OFF-SCREEN media never decodes (blink-safe: it's invisible). The
        //      live region is expanded by a 20% margin so a card is already warm
        //      before it pans into view.
        let nodeRect = CGRect(x: node.position.x, y: node.position.y,
                              width: node.width, height: renderedHeight(of: node))
        let liveRect = visibleWorldRect.insetBy(dx: -visibleWorldRect.width * 0.2,
                                                dy: -visibleWorldRect.height * 0.2)
        guard liveRect.intersects(nodeRect) else { return false }
        //  (b) Too small on screen (zoomed out) rests as a poster.
        guard projectedScreenSide(of: node) >= Self.livePlaybackMinScreenSide else { return false }
        //  (c) The SETTLED gate set — `liveMediaIDs` is memoised on
        //      `mediaGateEpoch` (bumps only at camera rest), so liveness is
        //      frozen during a gesture. NB: there is deliberately NO
        //      concurrency cap — per the product call, any media card even
        //      partly on screen at size plays.
        guard liveMediaIDs.contains(node.id) else { return false }
        return true
    }
}
