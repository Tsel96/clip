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

    /// Minimum on-screen height (in pt) below which a media-bearing card
    /// falls back to a static placeholder. Picked so a card that's
    /// clearly a peripheral thumbnail (~ icon-sized) stays cheap, but a
    /// card the user has zoomed in on renders fully without hesitation.
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
        // While the lightbox is open, force EVERY canvas card to its static
        // poster — no WKWebViews/players composite behind the hero spin, so
        // the animation stays buttery (and the dimmed grid is cheap to draw).
        if lightboxCardID != nil { return false }
        // The card being trimmed hands playback to the trim overlay's own
        // seekable player, so tear down its background loop player.
        if trimmingCardID == node.id { return false }
        switch node.kind {
        case .video, .tweet, .instagram, .image, .youtube, .webclip:
            break               // gated below
        default:
            return true
        }
        // NOTE: media is intentionally NOT suppressed during a pan. The
        // pan-crash culprit was the minimap's `.glassEffect` re-laying out
        // every tick (an AppKit constraint view), not the media cards — a
        // build with media fully suppressed during pan still crashed until
        // the glass was removed. SwiftUI `.scaleEffect`/`.offset` transform
        // the media layers without an AppKit constraint pass, so live
        // players during a pan are safe; suppressing them only made cards
        // blink (poster<->live) on every pan. `isCameraInteracting` now
        // gates only the minimap glass (see LiquidGlassMinimap).
        // "Show video previews only" — force every video-bearing kind to
        // its resting (poster) state regardless of zoom / viewport. Images
        // are left to the normal gate below: isLive controls an image's
        // actual pixels and an image has no playback to stop.
        if videosShowPreviewOnly {
            switch node.kind {
            case .video, .tweet, .instagram, .youtube: return false
            default: break
            }
        }
        let screenSide = min(node.width, renderedHeight(of: node)) * camera.zoom
        guard screenSide >= Self.livePlaybackMinScreenSide else { return false }
        let nodeRect = CGRect(
            x: node.position.x, y: node.position.y,
            width: node.width, height: renderedHeight(of: node)
        )
        return visibleWorldRect.intersects(nodeRect)
    }
}
