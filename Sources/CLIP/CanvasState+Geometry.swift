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
        //  (a) OFF-SCREEN media never decodes. This is blink-safe: the card is
        //      invisible, so there's nothing to "blink".
        let nodeRect = CGRect(x: node.position.x, y: node.position.y,
                              width: node.width, height: renderedHeight(of: node))
        // Expand the live region by a HALF-VIEWPORT margin on every side, so a
        // card is already playing BEFORE it pans into view — it scrolls in warm,
        // no blink. (Liveness is also frozen during a live pan/zoom — see
        // `cameraMoving` — so nothing flips mid-gesture; the margin covers the
        // settle.) The size gate below still rests cards that are too small when
        // zoomed out, even inside this margin.
        let liveRect = visibleWorldRect.insetBy(dx: -visibleWorldRect.width * 0.2,
                                                dy: -visibleWorldRect.height * 0.2)
        guard liveRect.intersects(nodeRect) else { return false }
        //  (b) A card too small on screen (zoomed out) rests as a poster — BUT
        //      we must NOT flip a *visible* card across the breakpoint mid-zoom
        //      (that live↔poster swap, and the WKWebView/player remount it
        //      implies, is the "videos blink while zooming" the user flagged).
        //      So apply the size gate only once the camera has SETTLED; during a
        //      live pan/zoom a visible card stays live and rides the transform.
        if !cameraMoving && projectedScreenSide(of: node) < Self.livePlaybackMinScreenSide {
            return false
        }
        return true
    }
}
