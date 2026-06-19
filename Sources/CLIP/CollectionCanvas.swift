import SwiftUI
import AppKit

/// Phase 1 (the real one) — Spatial-style canvas core.
///
/// Spatial's binary shows its canvas is pure AppKit: an `NSScrollView`
/// (native magnification = zoom, native scroll = pan, momentum + rubber-banding
/// for free) whose document view is an `NSCollectionView` driven by a *custom*
/// `NSCollectionViewLayout` that places each item at its world rect. Because
/// every card lives **inside** the scroll view's content space, native
/// magnification/scrolling transforms them all together — no external camera
/// sync, so no offset and no lag (the bugs the half-in/half-out attempt hit).
///
/// **MILESTONE 1 (this file):** prove the skeleton — the custom layout places
/// items at their world rects, native pan/zoom works, the flip/content-size are
/// right — using lightweight placeholder item views. Hosting the real cards
/// (which needs `DraggableNode` split into content vs. self-positioning),
/// moving the overlays into the content layer, and drag/selection come next.
///
/// **Coordinate model.** Content coords = world shifted by `-worldBounds.origin`
/// (so the scrollable area starts at (0,0) and spans `worldBounds.size`). A node
/// at world `(x,y)` gets item frame `(x − minX, y − minY, w, h)`.
/// Scroll view that zooms toward the cursor. The default pinch handling on our
/// huge document anchored magnification at a fixed point (content flew off as
/// you zoomed); overriding `magnify(with:)` to call `setMagnification(_:centeredAt:)`
/// at the gesture location keeps the point under your fingers fixed — the
/// expected canvas-zoom feel.
final class CenterZoomScrollView: NSScrollView {
    /// Reports the live pinch phase. Our magnify is programmatic, so the system
    /// `…LiveMagnify…` notifications don't fire — the coordinator uses this to
    /// freeze the camera sync (and thus SwiftUI card re-renders) mid-gesture.
    var onMagnifyPhase: ((NSEvent.Phase) -> Void)?

    override func magnify(with event: NSEvent) {
        onMagnifyPhase?(event.phase)
        let target = max(minMagnification,
                         min(maxMagnification, magnification * (1 + event.magnification)))
        let point = documentView?.convert(event.locationInWindow, from: nil)
            ?? convert(event.locationInWindow, from: nil)
        setMagnification(target, centeredAt: point)
    }
}

/// `NSCollectionView` grows in its scroll axis (height, for our layout) but
/// pins the cross axis (width) to the clip view — which collapses the document
/// width to the visible width and kills horizontal panning/zooming on a 2D
/// canvas. Enforce the full content width so the document stays wide enough to
/// scroll in X.
final class WideCollectionView: NSCollectionView {
    var contentWidth: CGFloat = 0 {
        didSet {
            if frame.width < contentWidth {
                setFrameSize(NSSize(width: contentWidth, height: frame.height))
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: max(newSize.width, contentWidth),
                                  height: newSize.height))
    }

    // Purely visual: all pointer interaction is owned by CanvasInputView, which
    // sits above this collection — so the collection never sees mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Flipped (top-left origin) document container so its subviews — the
/// collection of cards and the world-space overlay — share the cards'
/// coordinate convention.
final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

/// Hosting view that is completely transparent to the mouse — it sits *above*
/// the cards to draw connectors, so it must never swallow clicks/drags meant
/// for the cards (tap-select, ⇧-select, corner resize, empty-click deselect).
final class PassthroughHostingView: NSHostingView<AnyView> {
    required init(rootView: AnyView) { super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

    private var parent: CollectionCanvas? { coordinator?.parent }
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
        if let p = parent, let editID = p.editingTextNodeID,
           let n = p.nodes.first(where: { $0.id == editID }) {
            let local = convert(point, from: superview)
            if contentFrame(n, p).contains(local) { return nil }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let p = parent else { return }
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
        guard let p = parent else { return }
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
        guard let p = parent else { reset(); return }
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
        guard let p = parent, let selID = p.selectedNodeID,
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

struct CollectionCanvas: NSViewRepresentable {
    /// Scrollable world extent (all content + generous margin).
    let worldBounds: CGRect
    /// Ordered nodes → one collection-view item each.
    let nodes: [CanvasNode]
    /// Camera in (drives programmatic moves: fit / zoom buttons / glide).
    let camera: Camera
    let minZoom: CGFloat
    let maxZoom: CGFloat
    /// Pushed out on every live scroll / magnify (read-only: minimap + zoom readout).
    let onCameraChange: (Camera) -> Void
    /// Builds the SwiftUI view hosted by a node's item.
    let content: (CanvasNode) -> AnyView
    /// World-space overlay (connectors / selection / guides) drawn above the
    /// cards inside the scrolled content, so it pans/zooms with them. Built
    /// with `state` injected but NOT a camera — this view supplies a
    /// content-coordinate `CameraStore` so the overlay maps world → content.
    let overlay: AnyView
    /// Empty-canvas click → deselect (cards handle their own selection taps).
    let onBackgroundClick: () -> Void
    /// The lone selected node (drives native corner-resize hit-testing in the
    /// item). `nil` when zero or multiple nodes are selected.
    let selectedNodeID: UUID?
    /// Full selection set (drives the native selection ring on every selected
    /// card, including multi-select).
    let selectedNodeIDs: Set<UUID>
    /// Text node currently in inline edit. CanvasInputView passes clicks INSIDE
    /// this node's frame through to its TextField (so editing works) and owns
    /// everything else.
    let editingTextNodeID: UUID?
    /// Reads the LIVE selection (state.selectedNodeIDs) — used by the native
    /// chrome so it reflects selection changes immediately, instead of the stale
    /// `selectedNodeIDs` snapshot baked into this struct (which only refreshes on
    /// the next SwiftUI re-render, lagging the ring by one event).
    let liveSelection: () -> Set<UUID>
    /// Interaction lifecycle (CanvasInputView): snapshot undo on begin (and, for
    /// a move, `beginDrag` of the primary id for the connector tug); commit on end.
    let onInteractionBegan: (UUID?) -> Void
    let onInteractionEnded: () -> Void
    /// Move a node to a new WORLD position (per drag tick). Uses the move API
    /// (`updatePosition`) so connectors stay attached — NOT `resize`.
    let onMove: (UUID, CGPoint) -> Void
    /// Resize a node to a new WORLD frame (per drag tick).
    let onResize: (UUID, CGRect) -> Void
    /// Double-click a node → activate (text edit / stack focus / lightbox).
    let onActivate: (UUID) -> Void
    /// Marquee box-select: rect in CONTENT coords; Bool = additive (Shift held).
    let onMarquee: (CGRect, Bool) -> Void
    /// Native click-select: (node id, shift held).
    let onSelect: (UUID, Bool) -> Void
    /// Recolor a node from the radial picker (CanvasView maps the NSColor to the
    /// node's color model, e.g. nearest SectionColor).
    let onRecolorNode: (UUID, NSColor) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = CanvasWorldLayout()

        let collection = WideCollectionView()
        collection.contentWidth = worldBounds.size.width
        collection.collectionViewLayout = layout
        collection.isSelectable = false
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.register(HostingCollectionItem.self,
                            forItemWithIdentifier: Coordinator.itemID)
        collection.dataSource = context.coordinator
        // ALL pointer interaction is owned by a single CanvasInputView (added
        // below) — the collection + its items are now purely visual.

        let scroll = CenterZoomScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = minZoom
        scroll.maxMagnification = maxZoom
        scroll.usesPredominantAxisScrolling = false
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .allowed

        // The document is a flipped container holding the collection (cards)
        // plus a world-space overlay (connectors/selection) on top. Both live in
        // content coordinates, so the scroll view's magnification scales them
        // together — connectors pan/zoom with the cards.
        let container = FlippedContainer()
        container.frame = CGRect(origin: .zero, size: worldBounds.size)
        collection.frame = container.bounds
        collection.autoresizingMask = [.width, .height]
        container.addSubview(collection)

        let coord = context.coordinator
        // The overlay already carries its content-coordinate camera (injected by
        // the caller, which knows worldBounds on the main actor).
        let overlayHost = PassthroughHostingView(
            rootView: AnyView(overlay.allowsHitTesting(false)))
        overlayHost.frame = container.bounds
        overlayHost.autoresizingMask = [.width, .height]
        container.addSubview(overlayHost, positioned: .above, relativeTo: collection)

        // The single input owner, layered ABOVE everything in the document so no
        // other view competes for clicks (Spatial's CanvasContentView model).
        let input = CanvasInputView(frame: container.bounds)
        input.autoresizingMask = [.width, .height]
        input.coordinator = coord
        container.addSubview(input, positioned: .above, relativeTo: overlayHost)
        coord.inputView = input

        scroll.documentView = container
        coord.container = container
        coord.overlayHost = overlayHost
        coord.scroll = scroll
        coord.collection = collection
        coord.layout = layout
        coord.apply(self)

        scroll.contentView.postsBoundsChangedNotifications = true
        coord.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main
        ) { [weak coord] _ in
            // Sync the camera in real time so the minimap / zoom readout track
            // live. The native cards are decoupled from the camera (frozen card
            // camera + suppressZoomEpoch), so this never re-renders them — the
            // reason it's safe to sync mid-gesture now without the blink.
            coord?.pushCameraFromScroll()
            // Keep native chrome (section outline + selection ring) a constant
            // on-screen width while zooming — cheap CALayer updates, no re-render.
            coord?.refreshChrome()
        }

        // Escape deselects (keyboard path, always available — no race).
        coord.escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coord] event in
            if event.keyCode == 53 {            // Escape
                coord?.parent.onBackgroundClick()
                return nil
            }
            return event
        }
        // "C" with a single section selected → radial color picker at the cursor.
        coord.colorKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coord] event in
            // Plain 'c' only — never with ⌘/⌥/⌃ (so ⌘C copy etc. still work).
            guard let coord, event.keyCode == 8,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  coord.parent.editingTextNodeID == nil,          // not typing
                  coord.colorPicker == nil else { return event }
            let sel = coord.parent.liveSelection()
            guard sel.count == 1, let id = sel.first,
                  let node = coord.parent.nodes.first(where: { $0.id == id }),
                  node.isSection else { return event }
            coord.presentColorPicker(for: id)
            return nil
        }

        // Start centered on the actual content (not the empty world margin) so
        // pinch-zoom has the cards under the cursor.
        DispatchQueue.main.async { [weak coord] in coord?.fitContent() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        scroll.minMagnification = minZoom
        scroll.maxMagnification = maxZoom
        coord.apply(self)
        // DIAGNOSTIC: scroll view fully autonomous — do NOT push the camera
        // back in. If native pinch now anchors correctly, the round-trip was
        // the culprit; programmatic moves will route through the scroll view's
        // own API instead. (Zoom buttons won't work during this test.)
        // coord.applyCameraIfChanged(camera)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator (data source + two-way camera sync)

    final class Coordinator: NSObject, NSCollectionViewDataSource {
        static let itemID = NSUserInterfaceItemIdentifier("CanvasItem")
        var parent: CollectionCanvas
        weak var scroll: NSScrollView?
        weak var collection: NSCollectionView?
        weak var container: FlippedContainer?
        weak var overlayHost: NSHostingView<AnyView>?
        weak var layout: CanvasWorldLayout?
        private(set) var nodes: [CanvasNode] = []
        weak var inputView: CanvasInputView?
        var boundsObserver: NSObjectProtocol?
        var magnifyObserver: NSObjectProtocol?
        var liveScrollStart: NSObjectProtocol?
        var liveScrollEnd: NSObjectProtocol?
        var escMonitor: Any?
        var colorKeyMonitor: Any?
        var colorPicker: RadialColorPicker?
        /// While true (a live pan/pinch is in flight), the scroll→camera sync is
        /// frozen so the SwiftUI cards don't re-render every frame. The scroll
        /// view still scales the content natively; we sync the camera once the
        /// gesture (incl. momentum) ends.
        var suppressPush = false
        private var lastCamera: Camera?
        private var applyingProgrammatic = false
        // Card appear animation: track which node IDs we've already shown so a
        // genuinely-new card (added after the first load) scales in, while the
        // initial board doesn't animate every card on open.
        private var seenNodeIDs: Set<UUID> = []
        private var didInitialApply = false
        var pendingAppearIDs: Set<UUID> = []

        init(_ parent: CollectionCanvas) { self.parent = parent }

        func detach() {
            for o in [boundsObserver, magnifyObserver, liveScrollStart, liveScrollEnd] {
                if let o { NotificationCenter.default.removeObserver(o) }
            }
            if let m = escMonitor { NSEvent.removeMonitor(m) }
            if let m = colorKeyMonitor { NSEvent.removeMonitor(m) }
        }

        /// Show the radial color picker at the cursor and recolor `id` on pick.
        func presentColorPicker(for id: UUID) {
            guard let window = scroll?.window, let host = window.contentView else { return }
            // Cursor: screen → window → host coords.
            let winPt = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let hostPt = host.convert(winPt, from: nil)
            let picker = RadialColorPicker()
            picker.onPick = { [weak self] color in self?.parent.onRecolorNode(id, color) }
            picker.onDismiss = { [weak self] in self?.colorPicker = nil }
            colorPicker = picker
            picker.present(in: host, at: hostPt)
        }

        /// Recompute item frames (content coords) + content size from the nodes,
        /// then refresh. Cheap structural compare avoids needless reloads.
        func apply(_ p: CollectionCanvas) {
            let minX = p.worldBounds.minX, minY = p.worldBounds.minY
            let frames = p.nodes.map { n in
                CGRect(x: n.position.x - minX, y: n.position.y - minY,
                       width: max(1, n.width), height: max(1, n.height ?? 120))
            }
            // Snapshot the OLD nodes by id so we can detect content-only edits
            // (text/colour) on native cards, which don't change count or frame.
            let oldByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let countChanged = nodes.count != p.nodes.count
            let oldFrames = layout?.itemFrames ?? []
            let framesChanged = oldFrames != frames
            // Flag genuinely-new cards (added after the first load) to scale in,
            // and snapshot just-removed cards so they can scale OUT (the item is
            // gone after reloadData, so we animate a snapshot in its place).
            let currentIDs = Set(p.nodes.map(\.id))
            let removedIDs = didInitialApply ? seenNodeIDs.subtracting(currentIDs) : []
            if didInitialApply {
                pendingAppearIDs.formUnion(currentIDs.subtracting(seenNodeIDs))
            }
            seenNodeIDs = currentIDs
            didInitialApply = true
            if !removedIDs.isEmpty { spawnExitSnapshots(removedIDs) }
            nodes = p.nodes
            layout?.itemFrames = frames
            layout?.contentSize = p.worldBounds.size
            (collection as? WideCollectionView)?.contentWidth = p.worldBounds.size.width
            // Keep the document container + overlay's content-coordinate camera
            // in sync with the world extent.
            if container?.frame.size != p.worldBounds.size {
                container?.setFrameSize(p.worldBounds.size)
                collection?.setFrameSize(p.worldBounds.size)
                overlayHost?.setFrameSize(p.worldBounds.size)
            }
            if countChanged {
                // Items added/removed: full reload.
                layout?.invalidateLayout()
                collection?.reloadData()
            } else if framesChanged {
                // Position/size change (drag, resize). Refresh the layout cache…
                layout?.invalidateLayout()
                if let cv = collection {
                    // …but ALSO reposition the visible items DIRECTLY this turn.
                    // A bare `invalidateLayout()` defers repositioning to the next
                    // layout pass, which during a fast multi-item drag doesn't keep
                    // up (NSCollectionView under-updates cached attributes) — so a
                    // group move "didn't move". Setting the frames here, with
                    // implicit animation off, makes every selected item track the
                    // drag instantly.
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    for ip in cv.indexPathsForVisibleItems() where ip.item < frames.count {
                        cv.item(at: ip)?.view.frame = frames[ip.item]
                    }
                    CATransaction.commit()
                    // A SIZE change (resize) also needs the hosted card to re-render
                    // to the new dimensions (native content auto-resizes via
                    // constraints, so only the SwiftUI fallback needs a re-host).
                    for ip in cv.indexPathsForVisibleItems() where ip.item < p.nodes.count {
                        let i = ip.item
                        if i < oldFrames.count, oldFrames[i].size != frames[i].size,
                           let it = cv.item(at: ip) as? HostingCollectionItem {
                            // Native content auto-resizes via constraints; only
                            // the SwiftUI fallback needs a re-host to redraw.
                            if !it.usesNativeContent {
                                it.host(p.content(p.nodes[i]))
                            }
                            it.cardView.nodeID = p.nodes[i].id
                            it.cardView.coordinator = self
                        }
                    }
                }
            }
            // Content-only refresh: a native card (section/sticky/text) whose
            // payload changed — e.g. a section recolour via the `c` picker —
            // doesn't change count or frame, so neither branch above touches it.
            // Push the new node into the existing native view (no re-host).
            if !countChanged, let cv = collection {
                for ip in cv.indexPathsForVisibleItems() where ip.item < p.nodes.count {
                    let newNode = p.nodes[ip.item]
                    guard let it = cv.item(at: ip) as? HostingCollectionItem,
                          let updatable = it.nativeContentView as? NativeCardUpdatable,
                          let old = oldByID[newNode.id],
                          nativeContentKey(for: old) != nativeContentKey(for: newNode) else { continue }
                    updatable.update(for: newNode)
                }
            }
            refreshChrome()
        }

        /// Refresh the native selection chrome (white ring/handles) on every
        /// visible item. Driven by `liveSelection`, so calling this right after a
        /// selection change updates the ring SYNCHRONOUSLY — no waiting for the
        /// next SwiftUI re-render (which lagged the ring by one event).
        func refreshChrome() {
            guard let cv = collection else { return }
            for ip in cv.indexPathsForVisibleItems() {
                if let card = (cv.item(at: ip) as? HostingCollectionItem)?.cardView {
                    card.updateChrome()
                    card.updateShadow()      // fade the float shadow with zoom
                }
            }
        }

        /// Move the dragged items' VIEWS directly during a drag — bypassing the
        /// SwiftUI→model→`apply` round-trip, which is too slow/deferred to drive a
        /// many-item move in real time (a 20+ item group move "didn't move" because
        /// `apply` never repositioned them mid-gesture). The model is still updated
        /// per tick (connectors + undo/commit); this just makes the visuals track
        /// the cursor instantly. `startPos` is each node's pre-drag world position.
        /// Visually translate the dragged items during the gesture by applying a
        /// TRANSFORM to each item's layer. NSCollectionView owns the item FRAMES
        /// (it re-applies its cached layout every pass, which is why direct frame
        /// sets "did nothing"), but it does NOT touch the layer transform — so a
        /// translate rides on top of the layout and actually moves the card.
        @discardableResult
        func liveReposition(_ startPos: [UUID: CGPoint], dx: CGFloat, dy: CGFloat) -> Int {
            guard let cv = collection else { return -2 }
            let t = CATransform3DMakeTranslation(dx, dy, 0)
            var applied = 0
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for id in startPos.keys {
                guard let idx = nodes.firstIndex(where: { $0.id == id }) else { continue }
                if let v = cv.item(at: IndexPath(item: idx, section: 0))?.view {
                    v.layer?.transform = t
                    applied += 1
                }
            }
            CATransaction.commit()
            return applied
        }

        /// End of a move: write each dragged item's final frame into the layout
        /// cache, then `reloadData` to rebuild + REPAINT every item at its new
        /// position. A bare `invalidateLayout()` (or a per-item layer transform)
        /// does NOT repaint the rasterized zoomed-out canvas — which is why a
        /// low-zoom group move "didn't move" no matter what we set. `reloadData`
        /// forces a full repaint, so the commit lands at ANY magnification.
        func endLiveReposition(_ startPos: [UUID: CGPoint], dx: CGFloat, dy: CGFloat) {
            guard let cv = collection, let layout = layout else { return }
            let minX = parent.worldBounds.minX, minY = parent.worldBounds.minY
            for (id, sp) in startPos {
                guard let idx = nodes.firstIndex(where: { $0.id == id }), idx < layout.itemFrames.count
                else { continue }
                let n = nodes[idx]
                layout.itemFrames[idx] = CGRect(x: sp.x + dx - minX, y: sp.y + dy - minY,
                                                width: max(1, n.width), height: max(1, n.height ?? 120))
            }
            layout.invalidateLayout()
            cv.reloadData()
        }

        /// Spatial-style zoom-OUT on delete: the collection removes the item
        /// instantly on reload, so we drop a bitmap snapshot of each removed card
        /// into the container at its frame and spring it down + fade out. Purely
        /// cosmetic + fully guarded — never blocks the actual removal.
        private func spawnExitSnapshots(_ removed: Set<UUID>) {
            guard let cv = collection, let container = container else { return }
            for item in cv.visibleItems() {
                guard let card = (item as? HostingCollectionItem)?.cardView,
                      let id = card.nodeID, removed.contains(id),
                      card.bounds.width > 1, card.bounds.height > 1,
                      let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds)
                else { continue }
                card.cacheDisplay(in: card.bounds, to: rep)
                guard let cg = rep.cgImage else { continue }
                let frame = container.convert(card.bounds, from: card)
                let ghost = CALayer()
                ghost.contents = cg
                ghost.frame = frame
                ghost.contentsGravity = .resizeAspect
                ghost.zPosition = 50
                container.layer?.addSublayer(ghost)

                let c = CGPoint(x: ghost.bounds.midX, y: ghost.bounds.midY)
                let small = CATransform3DConcat(
                    CATransform3DConcat(CATransform3DMakeTranslation(-c.x, -c.y, 0),
                                        CATransform3DMakeScale(0.82, 0.82, 1)),
                    CATransform3DMakeTranslation(c.x, c.y, 0))
                CATransaction.begin()
                CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
                let s = CASpringAnimation(keyPath: "transform")
                s.fromValue = CATransform3DIdentity; s.toValue = small
                s.stiffness = CLIPSpring.Preset.settle.stiffness
                s.damping = CLIPSpring.Preset.settle.caDamping
                s.duration = s.settlingDuration
                let o = CABasicAnimation(keyPath: "opacity")
                o.fromValue = 1; o.toValue = 0; o.duration = 0.22
                o.timingFunction = CLIPSpring.easeOutSoft
                ghost.transform = small; ghost.opacity = 0
                ghost.add(s, forKey: "exitScale"); ghost.add(o, forKey: "exitFade")
                CATransaction.commit()
            }
        }

        /// Center + fit the actual content (the nodes' bounding rect, not the
        /// padded world) in the viewport. Run once the scroll view has a real
        /// size, so the canvas opens framed on the cards rather than off in the
        /// empty margin.
        func fitContent() {
            guard let scroll else { return }
            let p = parent
            guard !p.nodes.isEmpty else { return }
            var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            for n in p.nodes {
                minX = min(minX, n.position.x); minY = min(minY, n.position.y)
                maxX = max(maxX, n.position.x + n.width)
                maxY = max(maxY, n.position.y + (n.height ?? 120))
            }
            let cw = maxX - minX, ch = maxY - minY
            let vs = scroll.bounds.size
            guard cw > 0, ch > 0, vs.width > 0, vs.height > 0 else { return }
            let fit = min(vs.width / cw, vs.height / ch) * 0.85
            let zoom = max(p.minZoom, min(p.maxZoom, fit))
            applyingProgrammatic = true
            scroll.magnification = zoom
            let centerX = (minX + maxX) / 2 - p.worldBounds.minX
            let centerY = (minY + maxY) / 2 - p.worldBounds.minY
            let visW = vs.width / zoom, visH = vs.height / zoom
            scroll.contentView.scroll(to: CGPoint(x: centerX - visW / 2, y: centerY - visH / 2))
            scroll.reflectScrolledClipView(scroll.contentView)
            applyingProgrammatic = false
            pushCameraFromScroll()
        }

        // MARK: Data source

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            nodes.count
        }

        func collectionView(_ cv: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = cv.makeItem(withIdentifier: Coordinator.itemID, for: indexPath)
            if let hosting = item as? HostingCollectionItem, indexPath.item < nodes.count {
                let node = nodes[indexPath.item]
                hosting.cardView.nodeID = node.id
                hosting.cardView.coordinator = self
                hosting.setContent(node: node, swiftUI: parent.content(node))
                hosting.cardView.updateShadow()
                hosting.cardView.updateChrome()
                if pendingAppearIDs.remove(node.id) != nil {
                    let card = hosting.cardView
                    DispatchQueue.main.async { card.playAppear() }   // after layout sets bounds
                }
            }
            return item
        }

        // MARK: Camera sync

        /// Derive a `Camera` from the scroll view's magnification + scroll
        /// position and push it out (skipped mid programmatic apply).
        func pushCameraFromScroll() {
            guard !applyingProgrammatic, let scroll else { return }
            let zoom = scroll.magnification
            let visible = scroll.documentVisibleRect
            let worldOriginX = visible.origin.x + parent.worldBounds.minX
            let worldOriginY = visible.origin.y + parent.worldBounds.minY
            let cam = Camera(x: -worldOriginX * zoom, y: -worldOriginY * zoom, zoom: zoom)
            lastCamera = cam
            parent.onCameraChange(cam)
        }

        /// Apply an external camera ONLY if it genuinely differs from the scroll
        /// view's *current* state. Live scrolling pushes a camera out and SwiftUI
        /// feeds it straight back here; comparing against the scroll's live state
        /// (not a stored `lastCamera`, which races across render cycles) makes
        /// those echoes no-ops while real programmatic moves (zoom buttons, fit,
        /// glide) still apply. This is what stops the drift/zoom-anchor fight.
        func applyCameraIfChanged(_ cam: Camera) {
            guard let scroll else { return }
            let zoom = scroll.magnification
            let visible = scroll.documentVisibleRect
            let curX = -(visible.origin.x + parent.worldBounds.minX) * zoom
            let curY = -(visible.origin.y + parent.worldBounds.minY) * zoom
            // Echo of our own live scroll → skip. (Generous epsilons: anything
            // this close is the round-trip, not a deliberate camera move.)
            if abs(cam.zoom - zoom) < 0.0005,
               abs(cam.x - curX) < 0.5,
               abs(cam.y - curY) < 0.5 {
                return
            }
            applyCamera(cam)
        }

        func applyCamera(_ cam: Camera) {
            guard let scroll, cam.zoom > 0 else { return }
            applyingProgrammatic = true
            defer { applyingProgrammatic = false; lastCamera = cam }
            scroll.magnification = cam.zoom
            let worldOriginX = -cam.x / cam.zoom
            let worldOriginY = -cam.y / cam.zoom
            scroll.contentView.scroll(to: CGPoint(x: worldOriginX - parent.worldBounds.minX,
                                                  y: worldOriginY - parent.worldBounds.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

// MARK: - Custom layout: place each item at its world rect

/// Positions items by absolute frame (content coords), not a flow/grid. Content
/// size spans the whole world so the scroll view can roam the full canvas.
final class CanvasWorldLayout: NSCollectionViewLayout {
    /// Item frames in content coords, indexed by item (section 0).
    var itemFrames: [CGRect] = []
    var contentSize: CGSize = .zero
    private var cache: [NSCollectionViewLayoutAttributes] = []

    override var collectionViewContentSize: NSSize {
        NSSize(width: contentSize.width, height: contentSize.height)
    }

    override func prepare() {
        super.prepare()
        cache = itemFrames.enumerated().map { idx, frame in
            let attr = NSCollectionViewLayoutAttributes(
                forItemWith: IndexPath(item: idx, section: 0))
            attr.frame = frame
            return attr
        }
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        // No culling: keep every item mounted so cards never create/destroy as
        // the visible rect changes through a zoom — that mount/unmount is the
        // blink at the gesture boundaries. (Fine for canvas-scale item counts;
        // revisit with recycling if a board grows to thousands of cards.)
        cache
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item < cache.count else { return nil }
        return cache[indexPath.item]
    }

    // Magnification changes bounds but not item layout — don't thrash.
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { false }
}

// MARK: - Item: hosts a SwiftUI view, fills the item's frame

/// Purely VISUAL container for one card. It hosts the card content (native
/// image/video, or a SwiftUI `NSHostingView` for the rest) and draws all chrome
/// natively on its own layer — float shadow, the section outline, and the
/// selection ring + corner handles. It owns NO pointer interaction: every click
/// is handled by `CanvasInputView` (the sole pointer owner), so `hitTest`
/// returns nil. Chrome is driven by the LIVE selection via `updateChrome`, kept
/// magnification-correct so strokes stay a constant width on screen.
final class CardItemView: NSView {
    override var isFlipped: Bool { true }

    /// Identity + a back-reference so we read the *live* node + selection (the
    /// coordinator's `parent` is refreshed every update).
    var nodeID: UUID?
    weak var coordinator: CollectionCanvas.Coordinator?
    /// True when this item renders native content (image/video) vs the SwiftUI
    /// fallback — used only to decide re-host on resize, not chrome.
    var usesNativeContent = false

    private let sectionLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    /// 8 resize handles: 0–3 corners (tl, tr, bl, br), 4–7 edges (top, bottom,
    /// left, right) — matching Spatial's corner + edge resize handles.
    private let handleLayers: [CAShapeLayer] = (0..<8).map { _ in CAShapeLayer() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupChrome()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: - Native chrome (section outline + selection ring + handles)

    private func setupChrome() {
        // Section outline — a crisp neutral border so empty section frames read
        // clearly at any zoom (the SwiftUI 1pt border vanished when zoomed out).
        sectionLayer.fillColor = nil
        sectionLayer.strokeColor = NSColor.tertiaryLabelColor.cgColor
        sectionLayer.zPosition = 99
        sectionLayer.isHidden = true
        layer?.addSublayer(sectionLayer)

        // Selection ring + handles use `opacity` (not isHidden) so they can FADE
        // in/out; they start fully transparent.
        selectionLayer.fillColor = nil
        selectionLayer.strokeColor = NSColor.white.cgColor
        selectionLayer.shadowColor = NSColor.white.cgColor
        selectionLayer.shadowOpacity = 0.9
        selectionLayer.shadowOffset = .zero
        selectionLayer.zPosition = 100
        selectionLayer.opacity = 0
        layer?.addSublayer(selectionLayer)
        for h in handleLayers {
            h.fillColor = NSColor.white.cgColor
            h.strokeColor = NSColor.black.withAlphaComponent(0.18).cgColor
            h.zPosition = 101
            h.opacity = 0
            layer?.addSublayer(h)
        }
    }

    /// Draw the section outline, selection ring + 8 resize handles. Geometry is
    /// magnification-correct (constant on-screen widths) and applied WITHOUT
    /// animation so it tracks live during resize/zoom; visibility fades via
    /// `opacity` so selection glides in/out like Spatial
    /// (`highlightForSelectionWithIntensity:animated:`). Called on layout and
    /// whenever selection or zoom changes.
    func updateChrome() {
        let mag = magnification
        let node = liveNode
        let valid = bounds.width > 1 && bounds.height > 1

        CATransaction.begin(); CATransaction.setDisableActions(true)

        // Section outline — always visible (not gated on selection) so empty
        // section frames read clearly at any zoom, like Spatial.
        if let node, node.isSection, valid {
            sectionLayer.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75 / mag, dy: 0.75 / mag),
                                       cornerWidth: SectionNodeView.cornerRadius,
                                       cornerHeight: SectionNodeView.cornerRadius, transform: nil)
            sectionLayer.lineWidth = 1.5 / mag
            sectionLayer.isHidden = false
        } else {
            sectionLayer.isHidden = true
        }

        // Selection ring geometry (always sized so it's correct the instant it
        // fades in). One native ring per card; hosted cards' SwiftUI ring is off.
        let selected = valid && nodeID.map { coordinator?.parent.liveSelection().contains($0) == true } ?? false
        if valid {
            let inset = 1.25 / mag
            selectionLayer.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                         cornerWidth: CardChrome.cornerRadius,
                                         cornerHeight: CardChrome.cornerRadius, transform: nil)
            selectionLayer.lineWidth = 2 / mag
            selectionLayer.shadowRadius = 3 / mag

            // 8 handles: corners + edge midpoints, each centered on its point.
            let hs = 9 / mag
            let pts = [CGPoint(x: bounds.minX, y: bounds.minY),   // tl
                       CGPoint(x: bounds.maxX, y: bounds.minY),   // tr
                       CGPoint(x: bounds.minX, y: bounds.maxY),   // bl
                       CGPoint(x: bounds.maxX, y: bounds.maxY),   // br
                       CGPoint(x: bounds.midX, y: bounds.minY),   // top
                       CGPoint(x: bounds.midX, y: bounds.maxY),   // bottom
                       CGPoint(x: bounds.minX, y: bounds.midY),   // left
                       CGPoint(x: bounds.maxX, y: bounds.midY)]   // right
            for (i, h) in handleLayers.enumerated() {
                h.frame = CGRect(x: pts[i].x - hs / 2, y: pts[i].y - hs / 2, width: hs, height: hs)
                h.cornerRadius = hs * 0.22
                h.lineWidth = 1 / mag
            }
        }
        CATransaction.commit()

        // Animated visibility (fade) — OUTSIDE the no-animation transaction.
        fade(selectionLayer, to: selected ? 1 : 0)
        let showHandles = selected && resizeEnabled
        for h in handleLayers { fade(h, to: showHandles ? 1 : 0) }
    }

    /// Animate a chrome layer's opacity toward `target` (Spatial-style selection
    /// fade). No-op when already there, so resize/zoom ticks don't re-trigger it.
    private func fade(_ layer: CALayer, to target: Float) {
        guard layer.opacity != target else { return }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = layer.presentation()?.opacity ?? layer.opacity
        anim.toValue = target
        anim.duration = 0.14
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "fade")
        layer.opacity = target
    }

    // Purely visual: CanvasInputView (above the collection) owns ALL pointer
    // interaction. The item never sees mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var magnification: CGFloat { max(enclosingScrollView?.magnification ?? 1, 0.0001) }

    private var liveNode: CanvasNode? {
        guard let id = nodeID else { return nil }
        return coordinator?.parent.nodes.first { $0.id == id }
    }
    /// Whether this item is the lone selected resizable node — drives whether
    /// the corner handles are drawn (display only; the resize gesture lives in
    /// CanvasInputView). Reads the LIVE selection so it's never one event stale.
    private var resizeEnabled: Bool {
        guard let n = liveNode, let id = nodeID,
              let sel = coordinator?.parent.liveSelection(),
              sel.count == 1, sel.contains(id) else { return false }
        if case .text = n.kind { return false }
        return true
    }

    // MARK: - Appear animation (Spatial zoom-in)

    /// Scale-in + fade for a freshly-added card (Spatial's CanvasItemsAnimator
    /// pop). Center-anchored so it grows in place; spring settle.
    func playAppear() {
        guard let layer = layer, bounds.width > 1, bounds.height > 1 else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let small = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-c.x, -c.y, 0),
                                CATransform3DMakeScale(0.86, 0.86, 1)),
            CATransform3DMakeTranslation(c.x, c.y, 0))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = small; layer.opacity = 0
        CATransaction.commit()
        CLIPSpring.scale(self, to: 1.0, preset: .settle)
        CLIPSpring.run(duration: 0.22) { layer.opacity = 1 }
    }

    // MARK: - Float shadow (Spatial-style)

    /// Card corner radius — matches `figmaCardStyle`'s default so the shadow
    /// hugs the rounded card. (Text/sticky use a tighter radius; the small
    /// difference in their shadow corners is imperceptible.)
    private let shadowCornerRadius: CGFloat = 19.375

    override func layout() {
        super.layout()
        updateShadow()
        updateChrome()
    }

    /// Only solid card tiles cast a float shadow. Drawings, text frames and
    /// sections are transparent, so a full-rect layer shadow would show THROUGH
    /// them as an ugly grey box — they get none.
    private func castsShadow(_ kind: CanvasNode.Kind) -> Bool {
        switch kind {
        case .image, .video, .tweet, .instagram, .youtube, .webclip, .stickyNote:
            return true
        case .text, .drawing, .section:
            return false
        }
    }

    /// Spatial draws the card shadow on the item's CALayer (not in the card
    /// content) precisely because a layer shadow renders OUTSIDE the bounds —
    /// a SwiftUI shadow would be clipped by the collection item, just like the
    /// resize handles were. `shadowPath` keeps it cheap and correctly rounded.
    func updateShadow() {
        guard let layer = layer else { return }
        layer.masksToBounds = false
        guard let n = liveNode, castsShadow(n.kind), bounds.width > 1, bounds.height > 1 else {
            layer.shadowOpacity = 0
            return
        }
        // Fade the float shadow out when zoomed far out (Spatial's
        // minMagnificationForShadow) — dozens of soft shadows on a zoomed-out
        // board read as mud and cost fill-rate; near 1× they lift cleanly.
        let mag = magnification
        let minMag: CGFloat = 0.30, fullMag: CGFloat = 0.55
        let fade = max(0, min(1, (mag - minMag) / (fullMag - minMag)))
        // Spatial's float shadow is soft + wide + low-opacity (a gentle ambient
        // lift), not a tight dark drop shadow.
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = Float(0.12 * fade)
        layer.shadowRadius = 17
        layer.shadowOffset = CGSize(width: 0, height: 6)
        layer.shadowPath = CGPath(roundedRect: bounds,
                                  cornerWidth: shadowCornerRadius,
                                  cornerHeight: shadowCornerRadius,
                                  transform: nil)
    }
}

final class HostingCollectionItem: NSCollectionViewItem {
    private var hosting: NSHostingView<AnyView>?
    private var nativeContent: NSView?
    /// True while showing native content — the re-host (size) loop skips us
    /// (native content auto-resizes via constraints).
    var usesNativeContent: Bool { nativeContent != nil }
    /// The installed native content view (for in-place content refresh).
    var nativeContentView: NSView? { nativeContent }
    var cardView: CardItemView { view as! CardItemView }

    override func loadView() {
        let v = CardItemView()
        v.wantsLayer = true
        view = v
    }

    /// Install native content for the node if a native renderer exists; else
    /// host the SwiftUI fallback. `swiftUI` is an autoclosure so we don't build
    /// the SwiftUI card for natively-rendered kinds.
    func setContent(node: CanvasNode, swiftUI: @autoclosure () -> AnyView) {
        if let native = makeNativeCardContent(for: node) {
            hosting?.removeFromSuperview(); hosting = nil
            nativeContent?.removeFromSuperview()
            native.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(native, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                native.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                native.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                native.topAnchor.constraint(equalTo: view.topAnchor),
                native.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            nativeContent = native
            cardView.usesNativeContent = true
        } else {
            nativeContent?.removeFromSuperview(); nativeContent = nil
            cardView.usesNativeContent = false
            host(swiftUI())
        }
    }

    /// Mount / update the hosted SwiftUI content, pinned to fill the item.
    func host(_ root: AnyView) {
        if let h = hosting {
            h.rootView = root
            return
        }
        let h = NSHostingView(rootView: root)
        h.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            h.topAnchor.constraint(equalTo: view.topAnchor),
            h.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting = h
    }
}

// MARK: - Milestone-1 placeholder card

/// Stand-in for a real card while validating the collection-view skeleton:
/// a labelled box sized to the node's rect, so we can see that items land at
/// the right world positions and pan/zoom natively. Replaced by real card
/// hosting in milestone 2.
struct CanvasItemPlaceholder: View {
    let node: CanvasNode

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(6)
            }
    }

    private var label: String { "\(node.kind)" }
}
