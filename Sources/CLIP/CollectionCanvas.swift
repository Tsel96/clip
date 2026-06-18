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
    /// Called when an empty-canvas point is clicked (no drag) → deselect.
    var onEmptyClick: (() -> Void)?
    /// Live marquee: selection rect in this view's (content) coordinates.
    var onMarquee: ((CGRect) -> Void)?

    private var marqueeStart: NSPoint?
    private var marqueeDidDrag = false
    private lazy var marqueeLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        // Spatial's marquee is a subtle neutral outline with a barely-there
        // fill — not a saturated accent box.
        l.fillColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        l.strokeColor = NSColor.labelColor.withAlphaComponent(0.35).cgColor
        l.zPosition = 10_000
        l.isHidden = true
        return l
    }()

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: max(newSize.width, contentWidth),
                                  height: newSize.height))
    }

    override func mouseDown(with event: NSEvent) {
        // A card's hosting view consumes clicks that land on it, so this only
        // fires on empty canvas. Begin a *potential* marquee; the deselect (a
        // plain click) is deferred to mouseUp so a drag becomes a box-select.
        let pt = convert(event.locationInWindow, from: nil)
        if indexPathForItem(at: pt) == nil {
            marqueeStart = pt
            marqueeDidDrag = false
            if marqueeLayer.superlayer == nil { wantsLayer = true; layer?.addSublayer(marqueeLayer) }
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = marqueeStart else { super.mouseDragged(with: event); return }
        let pt = convert(event.locationInWindow, from: nil)
        let rect = CGRect(x: min(start.x, pt.x), y: min(start.y, pt.y),
                          width: abs(pt.x - start.x), height: abs(pt.y - start.y))
        if rect.width > 2 || rect.height > 2 { marqueeDidDrag = true }
        // Keep the marquee a constant width on screen regardless of zoom.
        marqueeLayer.lineWidth = 1 / max(enclosingScrollView?.magnification ?? 1, 0.0001)
        marqueeLayer.path = CGPath(rect: rect, transform: nil)
        marqueeLayer.isHidden = false
        onMarquee?(rect)
    }

    override func mouseUp(with event: NSEvent) {
        marqueeStart = nil; marqueeLayer.isHidden = true; marqueeLayer.path = nil
        // Deselect is handled by the canvas-level NSEvent monitor (Spatial's
        // CanvasMouseMonitor approach) — not here, since this override is
        // unreliable inside the scroll view.
    }
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
    /// Native resize callbacks (the item runs the drag in AppKit coords).
    let onResizeBegan: () -> Void
    let onResize: (UUID, CGRect) -> Void
    let onResizeEnded: () -> Void
    /// Marquee box-select: rect in CONTENT coordinates (world − worldBounds.origin).
    let onMarquee: (CGRect) -> Void
    /// Native click-select: (node id, shift held). SwiftUI taps don't fire here.
    let onSelect: (UUID, Bool) -> Void

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
        // Selection (incl. ⇧-multi-select) is handled by each card's own tap.
        // We only need empty-canvas clicks to deselect — handled in the
        // collection view's mouseDown (fires only when no item is hit), so it
        // never intercepts the cards' drag/resize/tap gestures.
        let bgClick = onBackgroundClick
        collection.onEmptyClick = { bgClick() }
        let marquee = onMarquee
        collection.onMarquee = { marquee($0) }

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
        }

        // Deselect, the Spatial way: `CanvasMouseMonitor` + `CanvasDeselector`.
        // Spatial doesn't override NSView.mouseDown (unreliable inside an
        // NSScrollView/NSCollectionView — our override fired 0 times); it watches
        // events with an NSEvent monitor and deselects when a click lands on no
        // item. We do the same: a local left-mouse-down monitor that, for clicks
        // inside the canvas hitting empty space (no item under the point), clears
        // the selection. The event is NOT consumed, so pan/marquee still work.
        coord.mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak coord] event in
            guard let coord, let scroll = coord.scroll,
                  event.window === scroll.window,
                  let root = scroll.window?.contentView else { return event }
            // Use real hit-testing (respects rendered geometry + magnification —
            // manual coordinate math got the magnification wrong). If the view
            // under the cursor is NOT inside a CardItemView, it's empty canvas
            // (or chrome) → deselect. CardItemView.hitTest claims card areas.
            let ptInScroll = scroll.convert(event.locationInWindow, from: nil)
            guard scroll.bounds.contains(ptInScroll) else { return event }   // sidebar/toolbar
            // Find the CardItemView under the cursor (real hit-test: respects
            // rendered geometry + magnification).
            var v = root.hitTest(event.locationInWindow)
            var hitCard: CardItemView?
            while let cur = v {
                if let c = cur as? CardItemView { hitCard = c; break }
                v = cur.superview
            }
            // Deselect when the click lands on empty canvas OR on a SECTION —
            // sections are background containers that blanket large areas, so a
            // body-click on one reads as "clicking the canvas", not selecting a
            // foreground card. Foreground cards keep the selection (their own
            // click recognizer selects them).
            let isBackground: Bool
            if let id = hitCard?.nodeID, let node = coord.parent.nodes.first(where: { $0.id == id }) {
                if case .section = node.kind { isBackground = true } else { isBackground = false }
            } else {
                isBackground = true
            }
            if isBackground { coord.parent.onBackgroundClick() }
            return event
        }
        // Escape also deselects (keyboard path, always available).
        coord.escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coord] event in
            if event.keyCode == 53 {            // Escape
                coord?.parent.onBackgroundClick()
                return nil
            }
            return event
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
        var boundsObserver: NSObjectProtocol?
        var magnifyObserver: NSObjectProtocol?
        var liveScrollStart: NSObjectProtocol?
        var liveScrollEnd: NSObjectProtocol?
        var escMonitor: Any?
        var mouseMonitor: Any?
        /// While true (a live pan/pinch is in flight), the scroll→camera sync is
        /// frozen so the SwiftUI cards don't re-render every frame. The scroll
        /// view still scales the content natively; we sync the camera once the
        /// gesture (incl. momentum) ends.
        var suppressPush = false
        private var lastCamera: Camera?
        private var applyingProgrammatic = false

        init(_ parent: CollectionCanvas) { self.parent = parent }

        func detach() {
            for o in [boundsObserver, magnifyObserver, liveScrollStart, liveScrollEnd] {
                if let o { NotificationCenter.default.removeObserver(o) }
            }
            if let m = escMonitor { NSEvent.removeMonitor(m) }
            if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        }

        /// Recompute item frames (content coords) + content size from the nodes,
        /// then refresh. Cheap structural compare avoids needless reloads.
        func apply(_ p: CollectionCanvas) {
            let minX = p.worldBounds.minX, minY = p.worldBounds.minY
            let frames = p.nodes.map { n in
                CGRect(x: n.position.x - minX, y: n.position.y - minY,
                       width: max(1, n.width), height: max(1, n.height ?? 120))
            }
            let countChanged = nodes.count != p.nodes.count
            let oldFrames = layout?.itemFrames ?? []
            let framesChanged = oldFrames != frames
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
                // Position/size change (drag, resize): re-position the EXISTING
                // items via layout invalidation — no reload, so cards don't
                // re-render/blink and the move stays smooth.
                layout?.invalidateLayout()
                // `invalidateLayout` only moves/resizes the item FRAMES; the
                // hosted card still renders at the node size captured when it
                // was last hosted. A pure move (drag) is fine — the item frame
                // carries the card. But a SIZE change (resize) needs the card
                // itself to re-render to the new dimensions, so re-host any
                // visible item whose size changed. `host()` reuses the hosting
                // view (updates `rootView`), so this is a cheap SwiftUI diff —
                // not a re-mount — and media cards don't blink.
                if let cv = collection {
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
            // Selection can change with no frame change, so refresh native chrome
            // (white ring/handles) on every visible item each apply — cheap.
            if let cv = collection {
                for ip in cv.indexPathsForVisibleItems() {
                    (cv.item(at: ip) as? HostingCollectionItem)?.cardView.updateChrome()
                }
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

/// The card item's container view. It owns resize hit-testing + the resize
/// drag **natively** (AppKit mouse coordinates are correct; SwiftUI's inside a
/// collection item are frozen at ~(6,4)). Anything that isn't a resize corner
/// falls through to the hosted SwiftUI card — tap-to-select, body-drag-to-move,
/// and in-card controls all keep working.
final class CardItemView: NSView {
    override var isFlipped: Bool { true }

    /// Identity + a back-reference so we read the *live* node, selection and
    /// callbacks (the coordinator's `parent` is refreshed every update).
    var nodeID: UUID?
    weak var coordinator: CollectionCanvas.Coordinator?
    /// True when this item renders native content (not the SwiftUI fallback) —
    /// then the chrome (selection ring + handles) is drawn natively here too,
    /// since there's no SwiftUI DraggableNode to draw it.
    var usesNativeContent = false

    private let selectionLayer = CAShapeLayer()
    private let handleLayers: [CAShapeLayer] = (0..<4).map { _ in CAShapeLayer() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // SwiftUI's `onTapGesture` never fires inside a collection item (the
        // same event-routing bug that froze the resize gesture), so selection
        // is done natively: a click recognizer that doesn't delay/consume the
        // event, so the SwiftUI body-drag (move) + in-card buttons still work —
        // a click selects, a drag moves.
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
        setupChrome()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: - Native selection chrome (Spatial CanvasCornerResizeHandle / border)

    private func setupChrome() {
        selectionLayer.fillColor = nil
        selectionLayer.strokeColor = NSColor.white.cgColor
        selectionLayer.shadowColor = NSColor.white.cgColor
        selectionLayer.shadowOpacity = 0.9
        selectionLayer.shadowOffset = .zero
        selectionLayer.zPosition = 100
        selectionLayer.isHidden = true
        layer?.addSublayer(selectionLayer)
        for h in handleLayers {
            h.fillColor = NSColor.white.cgColor
            h.strokeColor = NSColor.black.withAlphaComponent(0.18).cgColor
            h.zPosition = 101
            h.isHidden = true
            layer?.addSublayer(h)
        }
    }

    /// Draw / hide the white selection ring + corner handles. Called on layout
    /// and whenever selection changes (the coordinator's `apply`).
    func updateChrome() {
        let mag = magnification
        guard usesNativeContent, let id = nodeID,
              coordinator?.parent.selectedNodeIDs.contains(id) == true,
              bounds.width > 1, bounds.height > 1 else {
            selectionLayer.isHidden = true
            handleLayers.forEach { $0.isHidden = true }
            return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let inset = 1.25 / mag
        selectionLayer.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                     cornerWidth: CardChrome.cornerRadius,
                                     cornerHeight: CardChrome.cornerRadius, transform: nil)
        selectionLayer.lineWidth = 2.5 / mag
        selectionLayer.shadowRadius = 4 / mag
        selectionLayer.isHidden = false
        let hs = 9 / mag
        let show = resizeEnabled
        let corners = [CGPoint(x: bounds.minX, y: bounds.minY),
                       CGPoint(x: bounds.maxX, y: bounds.minY),
                       CGPoint(x: bounds.minX, y: bounds.maxY),
                       CGPoint(x: bounds.maxX, y: bounds.maxY)]
        for (i, h) in handleLayers.enumerated() {
            guard show else { h.isHidden = true; continue }
            let c = corners[i]
            h.frame = CGRect(x: (i % 2 == 0) ? c.x : c.x - hs,
                             y: (i < 2) ? c.y : c.y - hs, width: hs, height: hs)
            h.cornerRadius = hs * 0.18
            h.lineWidth = 1 / mag
            h.isHidden = false
        }
        CATransaction.commit()
    }

    @objc private func handleClick(_ gr: NSClickGestureRecognizer) {
        guard let id = nodeID else { return }
        coordinator?.parent.onSelect(id, NSEvent.modifierFlags.contains(.shift))
    }

    private enum Corner {
        case tl, tr, bl, br
        var movesLeft: Bool { self == .tl || self == .bl }
        var movesTop:  Bool { self == .tl || self == .tr }
        var cursor: NSCursor {
            let sel: Selector = (self == .tl || self == .br)
                ? Selector("_windowResizeNorthWestSouthEastCursor")
                : Selector("_windowResizeNorthEastSouthWestCursor")
            if NSCursor.responds(to: sel),
               let c = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor { return c }
            return .crosshair
        }
    }

    private var dragCorner: Corner?
    private var movingNative = false
    private var didBeginInteraction = false
    private var startFrame: CGRect = .zero
    private var startMouse: NSPoint = .zero

    private var magnification: CGFloat { max(enclosingScrollView?.magnification ?? 1, 0.0001) }
    /// Corner grab radius in this view's (world) units → ~26 pt on screen, but
    /// capped to a quarter of the smaller side so the four corners never cover
    /// the whole card (which would make every click a resize + leave no margin).
    private var cornerHit: CGFloat {
        min(26 / magnification, min(bounds.width, bounds.height) * 0.25)
    }

    private var liveNode: CanvasNode? {
        guard let id = nodeID else { return nil }
        return coordinator?.parent.nodes.first { $0.id == id }
    }
    private var resizeEnabled: Bool {
        guard let n = liveNode, n.id == coordinator?.parent.selectedNodeID else { return false }
        // Everything except auto-sizing text is resizable (matches isResizableKind).
        if case .text = n.kind { return false }
        return true
    }

    private func corner(at p: NSPoint) -> Corner? {
        guard resizeEnabled else { return nil }
        let r = cornerHit, w = bounds.width, h = bounds.height
        let left = p.x <= r, right = p.x >= w - r
        let top = p.y <= r, bottom = p.y >= h - r
        if left && top { return .tl }
        if right && top { return .tr }
        if left && bottom { return .bl }
        if right && bottom { return .br }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if resizeEnabled, corner(at: local) != nil { return self }   // corner resize
        // Native cards have no SwiftUI DraggableNode, so WE own the body too
        // (click-select via the recognizer, drag-to-move via mouseDragged).
        if usesNativeContent { return self }
        return super.hitTest(point)                        // SwiftUI fallback: it handles it
    }

    override func resetCursorRects() {
        guard resizeEnabled else { return }
        let r = cornerHit, w = bounds.width, h = bounds.height
        addCursorRect(CGRect(x: 0,     y: 0,     width: r, height: r), cursor: Corner.tl.cursor)
        addCursorRect(CGRect(x: w - r, y: 0,     width: r, height: r), cursor: Corner.tr.cursor)
        addCursorRect(CGRect(x: 0,     y: h - r, width: r, height: r), cursor: Corner.bl.cursor)
        addCursorRect(CGRect(x: w - r, y: h - r, width: r, height: r), cursor: Corner.br.cursor)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let n = liveNode else { super.mouseDown(with: event); return }
        if let c = corner(at: local) {
            dragCorner = c
        } else if usesNativeContent {
            movingNative = true   // body drag → move (native cards only)
        } else {
            super.mouseDown(with: event); return
        }
        startFrame = CGRect(x: n.position.x, y: n.position.y,
                            width: n.width, height: n.height ?? 120)
        startMouse = event.locationInWindow
        // onResizeBegan (undo snapshot) is deferred to the first drag so a plain
        // click (select) doesn't create a no-op undo entry.
    }

    private func beginInteractionIfNeeded() {
        guard !didBeginInteraction else { return }
        didBeginInteraction = true
        coordinator?.parent.onResizeBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        let mag = magnification
        // Native body move: reposition (same size) following the cursor.
        if movingNative, let n = liveNode {
            beginInteractionIfNeeded()
            let dx = (event.locationInWindow.x - startMouse.x) / mag
            let dy = -(event.locationInWindow.y - startMouse.y) / mag
            coordinator?.parent.onResize(n.id, CGRect(x: startFrame.minX + dx,
                                                      y: startFrame.minY + dy,
                                                      width: startFrame.width,
                                                      height: startFrame.height))
            return
        }
        guard let c = dragCorner, let n = liveNode else {
            super.mouseDragged(with: event); return
        }
        beginInteractionIfNeeded()
        let dx = (event.locationInWindow.x - startMouse.x) / mag
        // Window Y is bottom-up; our flipped / world Y is top-down.
        let dy = -(event.locationInWindow.y - startMouse.y) / mag

        var w = startFrame.width  + (c.movesLeft ? -dx : dx)
        var h = startFrame.height + (c.movesTop  ? -dy : dy)

        // Media keeps aspect by default; hold Shift OR ⌘ to free-resize the
        // frame to any dimensions (Figma-style).
        let freeAspect = event.modifierFlags.contains(.shift)
            || event.modifierFlags.contains(.command)
        let locks = locksAspect(n) != freeAspect
        if locks, startFrame.height > 0 {
            let aspect = startFrame.width / startFrame.height
            if abs(dx) > abs(dy) { h = w / aspect } else { w = h * aspect }
        }
        let minS = n.kind.minSize
        w = max(minS.width, w); h = max(minS.height, h)
        let originX = c.movesLeft ? (startFrame.maxX - w) : startFrame.minX
        let originY = c.movesTop  ? (startFrame.maxY - h) : startFrame.minY
        coordinator?.parent.onResize(n.id, CGRect(x: originX, y: originY, width: w, height: h))
    }

    override func mouseUp(with event: NSEvent) {
        if didBeginInteraction { coordinator?.parent.onResizeEnded() }
        dragCorner = nil
        movingNative = false
        didBeginInteraction = false
    }

    private func locksAspect(_ n: CanvasNode) -> Bool {
        switch n.kind {
        case .image, .video, .tweet, .instagram, .youtube, .webclip: return true
        default: return false
        }
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
        // Spatial's float shadow is soft + wide + low-opacity (a gentle ambient
        // lift), not a tight dark drop shadow.
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.12
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
