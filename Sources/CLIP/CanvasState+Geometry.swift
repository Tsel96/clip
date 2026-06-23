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
        // The card being trimmed hands playback to the trim overlay's own
        // seekable player, so tear down its background loop player.
        if trimmingCardID == node.id { return false }
        // "Show video previews only" — a user TOGGLE (not LOD) that forces
        // every video-bearing kind to its resting poster.
        if videosShowPreviewOnly {
            switch node.kind {
            case .video, .tweet, .instagram, .youtube: return false
            default: break
            }
        }
        switch node.kind {
        case .youtube, .instagram, .webclip:
            // WKWebView-backed: re-rasterizing a live web view every frame while
            // the canvas magnifies is the ~1 fps killer, so drop these to a cached
            // poster for the ZOOM's duration only (live again at rest + on pan).
            return !isZoomInteracting
        default:
            // Local video, tweet video, images, etc. are AVPlayer / bitmap-backed —
            // the GPU scales them cheaply during a magnify, so they stay LIVE
            // always and never blink (the user's "videos blinking on zoom" fix).
            return true
        }
    }
}
