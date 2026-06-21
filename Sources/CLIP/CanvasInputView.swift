import AppKit

/// Lightweight file log for runtime diagnosis (the user reads /tmp/clip_diag.txt
/// and reports back — we never puppeteer the app). Cheap append, best-effort.
func clipDiag(_ s: String) {
    let line = "[\(Date().timeIntervalSince1970)] \(s)\n"
    let url = URL(fileURLWithPath: "/tmp/clip_diag.txt")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.data(using: .utf8)?.write(to: url)
    }
}

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

    private enum Mode { case idle, pendingMove, move, resize, pendingMarquee, marquee, draw, pendingConnect, connect }
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
    private var connectSourceID: UUID?              // drag-to-connect origin node
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

    /// Live native draw-stroke preview (content space → scales with zoom).
    private lazy var drawLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = NSColor.clear.cgColor
        l.lineCap = .round
        l.lineJoin = .round
        l.isHidden = true
        return l
    }()
    private var drawPoints: [NSPoint] = []
    /// Tracks the cursor to drive object HOVER (the input view owns all pointer
    /// interaction, so hover is resolved here — not via per-item tracking areas,
    /// which fight this view's top-of-stack ownership).
    private var hoverTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(marqueeLayer)
        layer?.addSublayer(drawLayer)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverTracking { removeTrackingArea(t) }
        // `.inVisibleRect` keeps the area pinned to the visible portion of this
        // (world-sized) view as it scrolls/zooms, so we never track the whole
        // canvas. `.mouseMoved` resolves which card is under the cursor.
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseMoved, .mouseEnteredAndExited,
                                         .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        hoverTracking = t
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    /// Resolve the topmost hoverable node under the cursor → coordinator. Only in
    /// select mode and when idle (a drag/resize/marquee owns the gesture instead).
    private func updateHover(_ event: NSEvent) {
        guard let p = config, mode == .idle, p.isSelectMode() else { setHovered(nil); return }
        let pt = convert(event.locationInWindow, from: nil)
        let n = hitNode(at: pt, p)
        // Sections aren't hoverable (they're background frames, like for selection).
        setHovered((n != nil && !n!.isSection) ? n!.id : nil)
    }

    private func setHovered(_ id: UUID?) {
        guard coordinator?.hoveredNodeID != id else { return }
        coordinator?.hoveredNodeID = id
        coordinator?.refreshChrome()
    }

    private var config: CanvasConfig? { coordinator?.config }
    private var mag: CGFloat { max(enclosingScrollView?.magnification ?? 1, 0.0001) }

    private func contentFrame(_ n: CanvasNode, _ p: CanvasConfig) -> CGRect {
        CGRect(x: n.position.x - p.worldBounds.minX, y: n.position.y - p.worldBounds.minY,
               width: n.width, height: n.height ?? 120)
    }
    private func hitNode(at pt: NSPoint, _ p: CanvasConfig) -> CanvasNode? {
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
    private func grip(at pt: NSPoint, of n: CanvasNode, _ p: CanvasConfig) -> Grip? {
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

        // Native draw (marker): collect content-space points; commit on mouse-up.
        if p.isDrawMode() {
            mode = .draw
            drawPoints = [pt]
            return
        }

        // Native drag-to-connect (connectors tool): drag from one card to another.
        if p.isConnectMode() {
            if let n = hitNode(at: pt, p), !n.isSection {
                mode = .pendingConnect
                connectSourceID = n.id
            } else {
                mode = .idle
            }
            return
        }

        // Double-click → activate (text edit / stack focus / lightbox).
        if event.clickCount == 2, let n = hitNode(at: pt, p), !n.isSection {
            p.onActivate(n.id); mode = .idle; return
        }
        // Double-click on a connector → edit its midpoint label (Obsidian-style).
        if event.clickCount == 2, p.useNativeConnectors,
           let cid = coordinator?.connectorController?.hitTest(pt, tolerance: 16 / mag) {
            coordinator?.beginEditingConnectorLabel(cid)
            mode = .idle
            return
        }
        // Corner / edge resize on the single selected resizable node.
        if let selID = p.selectedNodeID, let sel = p.nodes.first(where: { $0.id == selID }),
           isResizable(sel), let g = grip(at: pt, of: sel, p) {
            mode = .resize; resizeGrip = g; resizeNodeID = selID
            resizeStartFrame = CGRect(x: sel.position.x, y: sel.position.y,
                                      width: sel.width, height: sel.height ?? 120)
            return
        }
        if let hit = hitNode(at: pt, p) {
            clipDiag("down kind=\(hit.kind) section=\(hit.isSection) size=\(Int(hit.width))x\(Int(hit.height ?? 0))")
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
            // Native connector click-select (before marquee): if the click lands
            // on a connector line, select it and stop.
            if p.useNativeConnectors,
               let cid = coordinator?.connectorController?.hitTest(pt, tolerance: 16 / mag) {
                p.onSelectConnector(cid)
                coordinator?.refreshChrome()
                mode = .idle
                return
            }
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
            // Figma-style alignment snapping — previously MISSING on the native
            // canvas (the engine was only wired into the SwiftUI DraggableNode
            // drag). Snap the PRIMARY node's prospective world frame to other
            // nodes' edges/centres, then apply the same delta to the whole group.
            // ⌘ frees it. Only the delta is adjusted — no `@Published` write — so
            // it can't trigger a card re-render mid-drag.
            var sdx = dx, sdy = dy
            if !event.modifierFlags.contains(.command),
               let pid = primaryMoveID, let sp = moveStartPos[pid],
               let pn = p.nodes.first(where: { $0.id == pid }) {
                let rect = CGRect(x: sp.x + dx, y: sp.y + dy,
                                  width: pn.width, height: pn.height ?? 120)
                let others = p.nodes.filter { moveStartPos[$0.id] == nil }.map {
                    CGRect(x: $0.position.x, y: $0.position.y,
                           width: $0.width, height: $0.height ?? 120)
                }
                let result = AlignmentEngine.snap(draggingRect: rect, otherRects: others,
                                                  zoom: mag, snapToGrid: false)
                // Equal-spacing pass — on the alignment-snapped rect, only on an
                // axis alignment left free (so the two never fight a coordinate).
                let claimedX = result.guides.contains { $0.axis == .vertical }
                let claimedY = result.guides.contains { $0.axis == .horizontal }
                let spacing = AlignmentEngine.equalSpacing(draggingRect: result.rect,
                    otherRects: others, zoom: mag, allowX: !claimedX, allowY: !claimedY)
                sdx = spacing.rect.minX - sp.x
                sdy = spacing.rect.minY - sp.y
                coordinator?.guideController?.update(result.guides, spacing: spacing.indicators,
                    worldMin: CGPoint(x: p.worldBounds.minX, y: p.worldBounds.minY),
                    magnification: mag)
            } else {
                coordinator?.guideController?.update([], worldMin: .zero, magnification: mag)
            }
            // Drive the move VISUALLY only (no per-tick model mutation). The model
            // is committed once on mouse-up.
            moveDelta = CGPoint(x: sdx, y: sdy)
            coordinator?.liveReposition(moveStartPos, dx: sdx, dy: sdy)   // live preview
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
        case .draw:
            drawPoints.append(pt)
            updateDrawPreview(p)
        case .pendingConnect, .connect:
            mode = .connect
            guard let srcID = connectSourceID,
                  let src = p.nodes.first(where: { $0.id == srcID }) else { break }
            let hovered = hitNode(at: pt, p)
            let target = (hovered != nil && hovered!.id != srcID && !hovered!.isSection) ? hovered : nil
            let srcRect = contentFrame(src, p)
            let tgtRect = target.map { contentFrame($0, p) } ?? CGRect(x: pt.x, y: pt.y, width: 0, height: 0)
            coordinator?.connectorController?.setPreview(sourceRect: srcRect, targetRect: tgtRect, magnification: mag)
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
            if didBegin {
                p.onInteractionEnded()
                p.onMoveCommitted(Set(moveStartPos.keys))   // drop-onto-folder check
            }
            coordinator?.endLiveReposition(moveStartPos, dx: moveDelta.x, dy: moveDelta.y)
        case .resize:
            if didBegin { p.onInteractionEnded() }
        case .draw:
            if drawPoints.count >= 2 {
                let wb = p.worldBounds
                p.onCommitStroke(drawPoints.map {
                    CGPoint(x: $0.x + wb.minX, y: $0.y + wb.minY)
                })
            }
        case .connect:
            let pt = convert(event.locationInWindow, from: nil)
            if let srcID = connectSourceID, let hovered = hitNode(at: pt, p),
               hovered.id != srcID, !hovered.isSection {
                p.onAddConnector(srcID, hovered.id)
            }
            coordinator?.connectorController?.clearPreview()
        case .pendingConnect, .marquee, .idle:
            coordinator?.connectorController?.clearPreview()
        }
        connectSourceID = nil
        coordinator?.refreshChrome()
        reset()
        // Re-resolve hover from the drop point (no mouseMoved fires during a drag).
        updateHover(event)
    }

    private func reset() {
        marqueeLayer.isHidden = true; marqueeLayer.path = nil
        drawLayer.isHidden = true; drawLayer.path = nil; drawPoints = []
        coordinator?.guideController?.update([], worldMin: .zero, magnification: mag)
        mode = .idle; resizeGrip = nil; resizeNodeID = nil
        moveStartPos = [:]; moveDelta = .zero; primaryMoveID = nil; didBegin = false; clickedSelectedNoShift = nil
    }

    private func beginIfNeeded(_ p: CanvasConfig, primary: UUID?) {
        guard !didBegin else { return }
        didBegin = true
        p.onInteractionBegan(primary)
    }

    /// Live polyline preview of the in-progress native stroke (content space).
    private func updateDrawPreview(_ p: CanvasConfig) {
        guard drawPoints.count >= 2 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Same smoothing the committed stroke uses (DrawingNodeView) so the live
        // preview matches the final result exactly.
        drawLayer.path = smoothCGPath(through: drawPoints)
        drawLayer.strokeColor = p.drawColor().cgColor
        drawLayer.lineWidth = p.drawWidth()   // content units → scales with zoom
        drawLayer.isHidden = false
        CATransaction.commit()
    }

    private func applyResize(dx: CGFloat, dy: CGFloat, event: NSEvent, p: CanvasConfig) {
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
