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
    // Accept first responder so a click on the canvas pulls focus away from any
    // lingering SwiftUI TextField field-editor (search / rename / hidden fields).
    // Without this the field-editor keeps focus forever and swallows Delete/⌫.
    override var acceptsFirstResponder: Bool { true }
    weak var coordinator: CollectionCanvas.Coordinator?

    private enum Mode { case idle, pendingMove, move, resize, pendingMarquee, marquee, draw, pendingConnect, connect, moveLabel, pan }
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
    private var connectSourceSide: ConnSide?        // side the drag started from (pinned)
    private var labelDragID: UUID?                  // connector whose label is being dragged
    private var labelDragStart: NSPoint = .zero     // content-space grab point
    private var labelDragStartOffset: CGPoint = .zero
    private var didBegin = false
    private var clickedSelectedNoShift: UUID?       // collapse-to-one on a no-drag click
    private var panStartContent: NSPoint = .zero    // hand-tool grab anchor (content coords)
    private var pannedCursorPushed = false          // closed-hand cursor pushed for the pan

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
                               options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                         .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        hoverTracking = t
    }

    /// Reliable cursor management (NSCursor.set() in mouseMoved gets reset by the
    /// cursor system). The hand tool shows the open-grab cursor at rest.
    override func cursorUpdate(with event: NSEvent) {
        guard let p = config, mode != .pan else { return }   // pan owns it (pushed grab cursor)
        if p.isHandMode() { NSCursor.openHand.set(); return }
        // Select mode: resize cursor over a selected node's grip, else the arrow
        // (this also resets the grab cursor when you switch off the Hand tool).
        let pt = convert(event.locationInWindow, from: nil)
        if let selID = p.selectedNodeID, let sel = p.nodes.first(where: { $0.id == selID }),
           isResizable(sel), let g = grip(at: pt, of: sel, p) {
            g.cursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    /// Resolve the topmost hoverable node under the cursor → coordinator. Only in
    /// select mode and when idle (a drag/resize/marquee owns the gesture instead).
    private func updateHover(_ event: NSEvent) {
        guard let p = config, mode == .idle else { setHovered(nil); hideConnectDot(); return }
        // Hand tool: no card hover (cursorUpdate shows the grab cursor).
        if p.isHandMode() { setHovered(nil); hideConnectDot(); return }
        let pt = convert(event.locationInWindow, from: nil)
        // Connector tool: show the green/yellow connect-port dot on the side of the
        // hovered card nearest the cursor (Figma 100-297) — "drag a connector here".
        if p.isConnectMode() {
            if let n = hitNode(at: pt, p), !n.isSection {
                let rect = contentFrame(n, p)
                let side = nearestSide(of: rect, to: pt)
                let c = ConnectorPathMath.sideCenter(of: rect, side)
                coordinator?.connectorController?.showHoverDot(at: c, mag: mag)
            } else {
                hideConnectDot()
            }
            setHovered(nil)
            return
        }
        hideConnectDot()
        guard p.isSelectMode() else { setHovered(nil); return }
        let n = hitNode(at: pt, p)
        // Sections aren't hoverable (they're background frames, like for selection).
        setHovered((n != nil && !n!.isSection) ? n!.id : nil)
    }

    private func hideConnectDot() { coordinator?.connectorController?.hideHoverDot() }

    /// The side of `r` whose edge is closest to `pt` (for the connect-hover port).
    private func nearestSide(of r: CGRect, to pt: CGPoint) -> ConnSide {
        let dl = abs(pt.x - r.minX), dr = abs(r.maxX - pt.x)
        let dt = abs(pt.y - r.minY), db = abs(r.maxY - pt.y)
        let m = min(dl, dr, dt, db)
        if m == dl { return .left }
        if m == dr { return .right }
        if m == dt { return .top }
        return .bottom
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
        case .image, .video, .tweet, .instagram, .youtube, .webclip, .folder: return true
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
        // Take focus from any text field so the canvas owns the keyboard (Delete,
        // etc.). Clicks INSIDE an editing text node never reach here (hitTest
        // passes them to the field), so this won't interrupt active text editing.
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let pt = convert(event.locationInWindow, from: nil)
        startPt = pt
        didBegin = false
        clickedSelectedNoShift = nil
        let shift = event.modifierFlags.contains(.shift)

        // Hand (pan) tool: grab the canvas and pan it 1:1 with the cursor
        // (Figma hand tool). Anchors the content point under the cursor.
        if p.isHandMode() {
            mode = .pan
            panStartContent = pt
            // Push (not set) the grab cursor so scroll ticks can't reset it mid-pan
            // (that reset↔set fight is the "blinking cursor").
            if !pannedCursorPushed { NSCursor.closedHand.push(); pannedCursorPushed = true }
            return
        }

        // Native draw (marker): collect content-space points; commit on mouse-up.
        if p.isDrawMode() {
            mode = .draw
            drawPoints = [pt]
            return
        }

        // Native drag-to-connect (connectors tool): drag from one card to another.
        if p.isConnectMode() {
            // Double-click a connector → edit its midpoint label.
            if event.clickCount == 2, p.useNativeConnectors,
               let cid = coordinator?.connectorController?.hitTest(pt, tolerance: 16 / mag) {
                coordinator?.beginEditingConnectorLabel(cid)
                mode = .idle
                return
            }
            // Single click ON a label → grab it to reposition (takes priority over
            // starting a connection, so a label sitting over a card is draggable).
            if p.useNativeConnectors,
               let cid = coordinator?.connectorController?.labelHitTest(pt) {
                mode = .moveLabel
                labelDragID = cid
                labelDragStart = pt
                labelDragStartOffset = coordinator?.connectorController?.storedLabelOffset(cid) ?? .zero
                return
            }
            if let n = hitNode(at: pt, p), !n.isSection {
                mode = .pendingConnect
                connectSourceID = n.id
                // Pin the source to the side nearest the grab so the origin doesn't
                // drift to an auto-picked side later.
                connectSourceSide = nearestSide(of: contentFrame(n, p), to: pt)
            } else if p.useNativeConnectors,
                      let cid = coordinator?.connectorController?.hitTest(pt, tolerance: 16 / mag) {
                // Click a connector line (not a card) → select it (so it's deletable).
                p.onSelectConnector(cid)
                coordinator?.refreshChrome()
                mode = .idle
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
            // Live target side = the hovered card's side nearest the cursor, so you
            // CHOOSE the side by moving over the card — the port + preview follow.
            let tside = target.map { nearestSide(of: tgtRect, to: pt) }
            coordinator?.connectorController?.setPreview(sourceRect: srcRect, targetRect: tgtRect,
                                                         sourceSide: connectSourceSide, targetSide: tside,
                                                         magnification: mag)
            if let tside {
                coordinator?.connectorController?.showHoverDot(
                    at: ConnectorPathMath.sideCenter(of: tgtRect, tside), mag: mag)
            } else {
                coordinator?.connectorController?.hideHoverDot()
            }
        case .moveLabel:
            guard let id = labelDragID else { break }
            let off = CGPoint(x: labelDragStartOffset.x + (pt.x - labelDragStart.x),
                              y: labelDragStartOffset.y + (pt.y - labelDragStart.y))
            coordinator?.connectorController?.setLiveLabelOffset(id: id, offset: off)
        case .pan:
            // Grab-pan (Figma hand tool): scroll the clip view by the slip of the
            // grabbed content point so it stays glued under the cursor 1:1.
            if let scroll = enclosingScrollView {
                let clip = scroll.contentView
                var o = clip.bounds.origin
                o.x += panStartContent.x - pt.x
                o.y += panStartContent.y - pt.y
                clip.scroll(to: o)
                scroll.reflectScrolledClipView(clip)
            }
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
                // Attach to the side of the target the user dragged onto; keep the
                // source pinned to where the drag began.
                let side = nearestSide(of: contentFrame(hovered, p), to: pt)
                p.onAddConnector(srcID, hovered.id, connectSourceSide, side)
            }
            coordinator?.connectorController?.clearPreview()
        case .moveLabel:
            let pt = convert(event.locationInWindow, from: nil)
            if let id = labelDragID {
                let off = CGPoint(x: labelDragStartOffset.x + (pt.x - labelDragStart.x),
                                  y: labelDragStartOffset.y + (pt.y - labelDragStart.y))
                let moved = abs(off.x - labelDragStartOffset.x) > 1 || abs(off.y - labelDragStartOffset.y) > 1
                if moved { p.onMoveConnectorLabel(id, off) } else { p.onSelectConnector(id) }
                coordinator?.connectorController?.clearLiveLabelOffset()
            }
        case .pendingConnect, .marquee, .idle, .pan:
            coordinator?.connectorController?.clearPreview()
        }
        connectSourceID = nil
        connectSourceSide = nil
        labelDragID = nil
        coordinator?.refreshChrome()
        reset()
        // Re-resolve hover from the drop point (no mouseMoved fires during a drag).
        updateHover(event)
    }

    private func reset() {
        if pannedCursorPushed { NSCursor.pop(); pannedCursorPushed = false }
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

    // Cursor management is handled entirely in `cursorUpdate(with:)` (hand /
    // resize-grip / arrow) — no cursor rects, so the two mechanisms can't fight.
}
