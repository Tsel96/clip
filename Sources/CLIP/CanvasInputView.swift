import AppKit

/// The SINGLE owner of all canvas pointer interaction (Spatial's
/// `CanvasContentView` model). A transparent, flipped NSView sized to the whole
/// world and layered above the cards, so NO other view competes for a click.
/// One state machine resolves ONE outcome per gesture — select / move / resize /
/// marquee / deselect / activate — which structurally eliminates the
/// select-vs-deselect race that plagued the old per-view handlers (a global
/// deselect monitor + the collection's marquee + the item's click recognizer +
/// the item's move/resize all fired on the same mouse-down).
///
/// Its own coordinate system IS content coords (flipped, sized to worldBounds,
/// at origin) — the same space node frames use (`world − worldBounds.origin`) —
/// so hit-testing the model needs no conversion gymnastics. It overrides only
/// the left mouse-button events; scroll/magnify pass through to the scroll view.
final class CanvasInputView: NSView {
    override var isFlipped: Bool { true }
    weak var coordinator: CollectionCanvas.Coordinator?

    private enum Mode { case idle, pendingMove, move, resize, pendingMarquee, marquee }
    /// Which edges a resize drag moves. A corner moves two (one H + one V); an
    /// edge moves one — matching Spatial's corner + edge resize handles.
    private struct Grip {
        var left = false, right = false, top = false, bottom = false
        var movesLeft: Bool { left }
        var movesTop:  Bool { top }
        var cursor: NSCursor {
            let diagonal = (left && top) || (right && bottom)
            let antiDiagonal = (right && top) || (left && bottom)
            if diagonal || antiDiagonal {
                let sel: Selector = diagonal
                    ? Selector("_windowResizeNorthWestSouthEastCursor")
                    : Selector("_windowResizeNorthEastSouthWestCursor")
                if NSCursor.responds(to: sel),
                   let c = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor { return c }
                return .crosshair
            }
            return (left || right) ? .resizeLeftRight : .resizeUpDown
        }
    }

    private var mode: Mode = .idle
    private var startPt: NSPoint = .zero            // content coords
    private var resizeGrip: Grip?
    private var resizeNodeID: UUID?
    private var resizeStartFrame: CGRect = .zero    // world coords
    private var moveStartPos: [UUID: CGPoint] = [:] // world coords
    private var moveDelta: CGPoint = .zero          // last drag delta (committed on mouse-up)
    private var primaryMoveID: UUID?
    private var didBegin = false
    private var clickedSelectedNoShift: UUID?       // collapse-to-one on a no-drag click

    private lazy var marqueeLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        // White selection rectangle (Spatial), not grey.
        l.fillColor = NSColor.white.withAlphaComponent(0.12).cgColor
        l.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        l.isHidden = true
        return l
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(marqueeLayer)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var config: CollectionCanvas? { coordinator?.config }
    private var mag: CGFloat { max(enclosingScrollView?.magnification ?? 1, 0.0001) }

    private func contentFrame(_ n: CanvasNode, _ p: CollectionCanvas) -> CGRect {
        CGRect(x: n.position.x - p.worldBounds.minX, y: n.position.y - p.worldBounds.minY,
               width: n.width, height: n.height ?? 120)
    }
    private func hitNode(at pt: NSPoint, _ p: CollectionCanvas) -> CanvasNode? {
        p.nodes.reversed().first { contentFrame($0, p).contains(pt) }   // topmost-first
    }
    private func isResizable(_ n: CanvasNode) -> Bool {
        if case .text = n.kind { return false }
        return true
    }
    private func locksAspect(_ n: CanvasNode) -> Bool {
        switch n.kind {
        case .image, .video, .tweet, .instagram, .youtube, .webclip: return true
        default: return false
        }
    }
    /// Resize grip on `n` near `pt` (content coords): the edges within grab range.
    /// Returns nil when the point isn't near any edge. Grab radius scales with
    /// zoom but is capped so the grips never cover the whole card.
    private func grip(at pt: NSPoint, of n: CanvasNode, _ p: CollectionCanvas) -> Grip? {
        let f = contentFrame(n, p)
        let r = min(26 / mag, min(f.width, f.height) * 0.25)
        var g = Grip()
        g.left   = pt.x <= f.minX + r
        g.right  = pt.x >= f.maxX - r
        g.top    = pt.y <= f.minY + r
        g.bottom = pt.y >= f.maxY - r
        // Must be within the frame (plus a hair) and touch at least one edge.
        guard f.insetBy(dx: -r, dy: -r).contains(pt),
              g.left || g.right || g.top || g.bottom else { return nil }
        return g
    }

    /// The input view shields the cards from clicks (it owns interaction). The
    /// one exception: while a text node is being edited, clicks INSIDE its frame
    /// fall through to the TextField below so the caret/keys work — everything
    /// else returns self.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let p = config, let editID = p.editingTextNodeID,
           let n = p.nodes.first(where: { $0.id == editID }) {
            let local = convert(point, from: superview)
            if contentFrame(n, p).contains(local) { return nil }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let p = config else { return }
        let pt = convert(event.locationInWindow, from: nil)
        startPt = pt
        didBegin = false
        clickedSelectedNoShift = nil
        let shift = event.modifierFlags.contains(.shift)

        // Double-click → activate (text edit / stack focus / lightbox).
        if event.clickCount == 2, let n = hitNode(at: pt, p), !n.isSection {
            p.onActivate(n.id); mode = .idle; return
        }
        // Corner / edge resize on the single selected resizable node.
        if let selID = p.selectedNodeID, let sel = p.nodes.first(where: { $0.id == selID }),
           isResizable(sel), let g = grip(at: pt, of: sel, p) {
            mode = .resize; resizeGrip = g; resizeNodeID = selID
            resizeStartFrame = CGRect(x: sel.position.x, y: sel.position.y,
                                      width: sel.width, height: sel.height ?? 120)
            return
        }
        if let n = hitNode(at: pt, p), !n.isSection {
            // Selection on mouse-DOWN (so a drag moves what you grabbed).
            let live = p.liveSelection()
            if shift {
                p.onSelect(n.id, true)                       // toggle
            } else if !live.contains(n.id) {
                p.onSelect(n.id, false)                      // replace
            } else {
                clickedSelectedNoShift = n.id                // collapse on up if no drag
            }
            coordinator?.refreshChrome()
            // Prepare a (group) move of the whole current selection.
            mode = .pendingMove
            primaryMoveID = n.id
            let ids = live.contains(n.id) ? live.union([n.id]) : [n.id]
            moveStartPos = [:]
            for m in p.nodes where ids.contains(m.id) { moveStartPos[m.id] = m.position }
        } else {
            // Empty canvas OR a section body → marquee, or deselect if no drag.
            mode = .pendingMarquee
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p = config else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let dx = pt.x - startPt.x, dy = pt.y - startPt.y
        switch mode {
        case .resize:
            beginIfNeeded(p, primary: nil)
            applyResize(dx: dx, dy: dy, event: event, p: p)
        case .pendingMove, .move:
            if mode == .pendingMove {
                if abs(dx) < 1 && abs(dy) < 1 { return }     // not a real drag yet
                mode = .move
                beginIfNeeded(p, primary: primaryMoveID)
            }
            // Drive the move VISUALLY only (no per-tick model mutation). Mutating
            // the model each tick kicks a SwiftUI re-render + `apply`, which races
            // the direct item repositioning and clobbers it with stale frames — the
            // "nothing moves" bug. The model is committed once on mouse-up.
            moveDelta = CGPoint(x: dx, y: dy)
            coordinator?.liveReposition(moveStartPos, dx: dx, dy: dy)   // live preview (renders at ≥~1× zoom)
        case .pendingMarquee, .marquee:
            if mode == .pendingMarquee {
                // Don't start a marquee on trackpad click-jitter — a sub-threshold
                // drag stays a "click" so mouseUp can deselect (Fix A).
                if abs(dx) < 4 / mag && abs(dy) < 4 / mag { return }
                mode = .marquee
            }
            let rect = CGRect(x: min(startPt.x, pt.x), y: min(startPt.y, pt.y),
                              width: abs(dx), height: abs(dy))
            marqueeLayer.lineWidth = 1.5 / mag
            marqueeLayer.path = CGPath(rect: rect, transform: nil)
            marqueeLayer.isHidden = false
            p.onMarquee(rect, event.modifierFlags.contains(.shift))
            coordinator?.refreshChrome()
        case .idle: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let p = config else { reset(); return }
        switch mode {
        case .pendingMarquee:
            p.onBackgroundClick()                            // empty/section click → deselect
        case .pendingMove:
            if let id = clickedSelectedNoShift { p.onSelect(id, false) }   // collapse to one
        case .move:
            // Commit the model FIRST so `state.nodes` is already moved before any
            // render fires — otherwise a render kicked during the repaint runs
            // `apply` with the OLD nodes and overwrites `itemFrames` back to the
            // start (the "reloads but doesn't move" bug). THEN repaint the items.
            for (id, sp) in moveStartPos {
                p.onMove(id, CGPoint(x: sp.x + moveDelta.x, y: sp.y + moveDelta.y))
            }
            if didBegin { p.onInteractionEnded() }
            coordinator?.endLiveReposition(moveStartPos, dx: moveDelta.x, dy: moveDelta.y)
        case .resize:
            if didBegin { p.onInteractionEnded() }
        case .marquee, .idle:
            break
        }
        coordinator?.refreshChrome()
        reset()
    }

    private func reset() {
        marqueeLayer.isHidden = true; marqueeLayer.path = nil
        mode = .idle; resizeGrip = nil; resizeNodeID = nil
        moveStartPos = [:]; moveDelta = .zero; primaryMoveID = nil; didBegin = false; clickedSelectedNoShift = nil
    }

    private func beginIfNeeded(_ p: CollectionCanvas, primary: UUID?) {
        guard !didBegin else { return }
        didBegin = true
        p.onInteractionBegan(primary)
    }

    private func applyResize(dx: CGFloat, dy: CGFloat, event: NSEvent, p: CollectionCanvas) {
        guard let g = resizeGrip, let id = resizeNodeID,
              let n = p.nodes.first(where: { $0.id == id }) else { return }
        let start = resizeStartFrame
        // Each axis only changes if the grip touches an edge on that axis (an
        // edge grip leaves the other axis fixed).
        var w = start.width  + (g.left ? -dx : (g.right ? dx : 0))
        var h = start.height + (g.top  ? -dy : (g.bottom ? dy : 0))
        // Media keeps aspect by default; Shift OR ⌘ frees it (Figma-style).
        let freeAspect = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        let locks = locksAspect(n) != freeAspect
        if locks, start.height > 0 {
            let aspect = start.width / start.height
            if abs(w - start.width) >= abs(h - start.height) { h = w / aspect } else { w = h * aspect }
        }
        let minS = n.kind.minSize
        w = max(minS.width, w); h = max(minS.height, h)
        let ox = g.left ? (start.maxX - w) : start.minX
        let oy = g.top  ? (start.maxY - h) : start.minY
        p.onResize(id, CGRect(x: ox, y: oy, width: w, height: h))
    }

    override func resetCursorRects() {
        guard let p = config, let selID = p.selectedNodeID,
              let sel = p.nodes.first(where: { $0.id == selID }), isResizable(sel) else { return }
        let f = contentFrame(sel, p)
        let r = min(26 / mag, min(f.width, f.height) * 0.25)
        // Corner + edge cursor rects.
        let specs: [(CGRect, Grip)] = [
            (CGRect(x: f.minX, y: f.minY, width: r, height: r), Grip(left: true, top: true)),
            (CGRect(x: f.maxX - r, y: f.minY, width: r, height: r), Grip(right: true, top: true)),
            (CGRect(x: f.minX, y: f.maxY - r, width: r, height: r), Grip(left: true, bottom: true)),
            (CGRect(x: f.maxX - r, y: f.maxY - r, width: r, height: r), Grip(right: true, bottom: true)),
            (CGRect(x: f.minX + r, y: f.minY, width: f.width - 2*r, height: r), Grip(top: true)),
            (CGRect(x: f.minX + r, y: f.maxY - r, width: f.width - 2*r, height: r), Grip(bottom: true)),
            (CGRect(x: f.minX, y: f.minY + r, width: r, height: f.height - 2*r), Grip(left: true)),
            (CGRect(x: f.maxX - r, y: f.minY + r, width: r, height: f.height - 2*r), Grip(right: true)),
        ]
        for (rect, g) in specs where rect.width > 0 && rect.height > 0 {
            addCursorRect(rect, cursor: g.cursor)
        }
    }
}
