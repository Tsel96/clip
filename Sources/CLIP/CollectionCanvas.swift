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
    override func magnify(with event: NSEvent) {
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

/// Hosts the screen-space tool overlays (tool-input / selection / guides) ABOVE
/// the scroll. In **select** mode it is click-transparent (returns `nil`) so
/// clicks fall straight through to `CanvasInputView`; in a **tool** mode it
/// hit-tests normally so draw/text/connect route through `ToolInputLayer`.
/// Scroll/magnify always forward to the scroll view so pan/zoom works in any
/// mode (its `CLIPCanvasView` host also forwards bubbled scroll events).
final class ToolOverlayHostingView: NSHostingView<AnyView> {
    /// Reads the LIVE select-mode flag (from the coordinator's current config).
    var isSelectMode: () -> Bool = { true }
    weak var scrollRef: NSScrollView?
    required init(rootView: AnyView) { super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        isSelectMode() ? nil : super.hitTest(point)
    }
    override func scrollWheel(with event: NSEvent) { scrollRef?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { scrollRef?.magnify(with: event) }
}

/// Live cursor position (screen-space, SwiftUI top-left coords) for the native
/// shell's dot-grid spotlight. Updated by the canvas event monitor and observed
/// ONLY by the behind-island — so pointer moves re-render the grid in isolation,
/// never the whole `CanvasView` body.
final class CanvasPointerStore: ObservableObject {
    @Published var location: CGPoint?
}


/// Pure-data inputs to the native canvas engine, shared by the SwiftUI bridge
/// (`CollectionCanvas`) and the `Coordinator`. Carrying these as a value
/// (instead of the representable `self`) decouples the engine
/// (`Coordinator` / `CanvasInputView`) from SwiftUI — so a plain `NSView` can
/// host the same engine later (Phase A `CLIPCanvasView`/`CanvasHost`) — and
/// makes the inputs testable.
struct CanvasConfig {
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
    /// SCREEN-space island drawn BEHIND the cards (dot-grid spotlight,
    /// empty-state). Non-interactive. `nil` in the legacy ZStack shell, where
    /// these render as SwiftUI siblings instead.
    let behindOverlay: AnyView?
    /// SCREEN-space island drawn ABOVE the cards (tool-input, smart-selection,
    /// alignment/spacing guides). Interactive only in a tool mode — its host
    /// passes clicks through to `CanvasInputView` in select mode. `nil` in the
    /// legacy ZStack shell.
    let aboveOverlay: AnyView?
    /// True when the canvas is in select mode — drives the above-island's
    /// click-passthrough so cards stay directly clickable.
    let isSelectMode: () -> Bool
    /// True in draw (marker) mode — the above-island ALSO passes clicks through
    /// then, so `CanvasInputView` draws the stroke natively (no SwiftUI gesture).
    let isDrawMode: () -> Bool
    /// Live marker colour + width for the native draw preview.
    let drawColor: () -> NSColor
    let drawWidth: () -> CGFloat
    /// Commit a finished stroke (points in WORLD coords).
    let onCommitStroke: ([CGPoint]) -> Void
    /// Phase B native connectors (flag-gated). When `useNativeConnectors` is
    /// true, `ConnectorOverlayController` draws these as CAShapeLayers in the
    /// scrolled container and the SwiftUI ConnectorsLayer overlay is left empty.
    let connectors: [Connector]
    let useNativeConnectors: Bool
    /// Select (or clear) a connector — native connector click-select.
    let onSelectConnector: (UUID?) -> Void
    /// Selected connector ids — drives the native connector highlight colour.
    let selectedConnectorIDs: Set<UUID>
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
    /// A finished move (real drag) committed these node ids — used to detect a
    /// drop ONTO a folder (→ tuck them in). A no-op for ordinary moves.
    let onMoveCommitted: (Set<UUID>) -> Void
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
}

/// The SwiftUI bridge: mounts the native canvas engine and feeds it a
/// `CanvasConfig` each update. (Phase A introduces a sibling `CanvasHost` /
/// `CLIPCanvasView` that hosts the same engine from a plain `NSView`; both
/// share `CanvasConfig` and the `Coordinator`.)
struct CollectionCanvas: NSViewRepresentable {
    let config: CanvasConfig

    func makeCoordinator() -> Coordinator { Coordinator(config) }

    // The engine subtree + observers/monitors now live in `CLIPCanvasView.init`;
    // this bridge just mounts it and drives state→view sync each update.
    func makeNSView(context: Context) -> CLIPCanvasView {
        CLIPCanvasView(config: config, coordinator: context.coordinator)
    }

    func updateNSView(_ view: CLIPCanvasView, context: Context) {
        let coord = context.coordinator
        coord.config = config
        coord.scroll?.minMagnification = config.minZoom
        coord.scroll?.maxMagnification = config.maxZoom
        coord.apply(config)
        // Re-enabled programmatic camera: the zoom pill / ⌘± / fit / zoom-to-
        // selection / minimap jumps move the canvas. `applyCameraIfChanged`
        // compares against the scroll view's LIVE state and no-ops echoes of our
        // own pinch/scroll, so the round-trip can't fight the cursor-anchored
        // `magnify`.
        coord.applyCameraIfChanged(config.camera)
    }

    static func dismantleNSView(_ view: CLIPCanvasView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator (data source + two-way camera sync)

    final class Coordinator: NSObject, NSCollectionViewDataSource {
        static let itemID = NSUserInterfaceItemIdentifier("CanvasItem")
        var config: CanvasConfig
        weak var scroll: NSScrollView?
        weak var collection: NSCollectionView?
        weak var container: FlippedContainer?
        weak var overlayHost: NSHostingView<AnyView>?
        weak var layout: CanvasWorldLayout?
        private(set) var nodes: [CanvasNode] = []
        weak var inputView: CanvasInputView?
        var boundsObserver: NSObjectProtocol?
        var escMonitor: Any?
        var colorKeyMonitor: Any?
        var colorPicker: RadialColorPicker?
        var connectorController: ConnectorOverlayController?
        var guideController: GuideOverlayController?
        // internal (not private) so the camera-sync seam in
        // CanvasCameraController.swift can read/write the echo-suppression state.
        var lastCamera: Camera?
        var applyingProgrammatic = false
        // Card appear animation: track which node IDs we've already shown so a
        // genuinely-new card (added after the first load) scales in, while the
        // initial board doesn't animate every card on open.
        private var seenNodeIDs: Set<UUID> = []
        private var didInitialApply = false
        var pendingAppearIDs: Set<UUID> = []

        init(_ config: CanvasConfig) { self.config = config }

        func detach() {
            if let o = boundsObserver { NotificationCenter.default.removeObserver(o) }
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
            picker.onPick = { [weak self] color in self?.config.onRecolorNode(id, color) }
            picker.onDismiss = { [weak self] in self?.colorPicker = nil }
            colorPicker = picker
            picker.present(in: host, at: hostPt)
        }

        /// Recompute item frames (content coords) + content size from the nodes,
        /// then refresh. Cheap structural compare avoids needless reloads.
        func apply(_ p: CanvasConfig) {
            let minX = p.worldBounds.minX, minY = p.worldBounds.minY
            let frames = p.nodes.map { n in
                CGRect(x: n.position.x - minX, y: n.position.y - minY,
                       width: max(1, n.width), height: max(1, n.height ?? 120))
            }
            // Snapshot the OLD nodes by id so we can detect content-only edits
            // (text/colour) on native cards, which don't change count or frame.
            let oldByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let oldOrderedIDs = nodes.map(\.id)   // OLD order, before `nodes` is replaced below
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
            if !removedIDs.isEmpty {
                // A card that left the canvas because it was FILED into a folder
                // flies INTO that folder (Spatial's "jump inside"); a genuinely
                // deleted card springs out + down. Tell them apart by whether the
                // removed id now appears in some folder's childIDs.
                var deleted = Set<UUID>()
                var filed: [UUID: Set<UUID>] = [:]
                for rid in removedIDs {
                    if let folder = p.nodes.first(where: {
                        if case .folder(_, _, let kids) = $0.kind { return kids.contains(rid) }
                        return false
                    }) {
                        filed[folder.id, default: []].insert(rid)
                    } else {
                        deleted.insert(rid)
                    }
                }
                if !deleted.isEmpty { spawnExitSnapshots(deleted) }
                for (fid, cards) in filed { spawnFolderDropSnapshots(cards, into: fid) }
            }
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
                // Items added / removed / filtered (e.g. a card filed into a folder
                // disappears from `canvasDisplayNodes`). `reloadData` is the only
                // update that can't desync the data-source count from the batch ops:
                // the incremental `performBatchUpdates` diff raised an
                // NSInternalInconsistencyException on the folder count-change (the
                // data-source count and the delete op got out of sync inside a
                // re-entrant layout pass). Web / video cards reuse their cached
                // views across the reload (WebViewCache / PlayerCache), so this
                // does NOT reintroduce the add/delete blink.
                _ = (oldOrderedIDs, currentIDs)   // (kept for the diff comment above)
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
                    guard let it = cv.item(at: ip) as? HostingCollectionItem else { continue }
                    // Native text ⇄ SwiftUI editor swap when this node enters or
                    // leaves edit mode (editingTextNodeID isn't in nativeContentKey,
                    // so the content-only branch below would miss the transition).
                    // Gated with the renderer so flag-off text is plain SwiftUI.
                    if case .text = newNode.kind, FeatureFlags.useNativeText {
                        let shouldEdit = (p.editingTextNodeID == newNode.id)
                        if shouldEdit == it.usesNativeContent {
                            // Mismatch: editing → SwiftUI field, resting → native.
                            it.setContent(node: newNode, swiftUI: p.content(newNode),
                                          isEditing: shouldEdit)
                        } else if let u = it.nativeContentView as? NativeCardUpdatable,
                                  let old = oldByID[newNode.id],
                                  nativeContentKey(for: old) != nativeContentKey(for: newNode) {
                            u.update(for: newNode)
                        }
                        continue
                    }
                    guard let updatable = it.nativeContentView as? NativeCardUpdatable,
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
            refreshConnectors()
        }

        /// Phase B native connectors: rebuild content-space node frames and push
        /// them into the CAShapeLayer controller. Driven from `refreshChrome`, so
        /// it tracks node changes (apply → refreshChrome) AND zoom (bounds
        /// observer → refreshChrome). No-op unless `useNativeConnectors`.
        func refreshConnectors(offsets: [UUID: CGPoint] = [:]) {
            guard let cc = connectorController else { return }
            let minX = config.worldBounds.minX, minY = config.worldBounds.minY
            var frames: [UUID: CGRect] = [:]
            for n in config.nodes {
                let o = offsets[n.id] ?? .zero
                frames[n.id] = CGRect(x: n.position.x - minX + o.x, y: n.position.y - minY + o.y,
                                      width: max(1, n.width), height: max(1, n.height ?? 120))
            }
            cc.update(connectors: config.connectors, nodeFrames: frames,
                      selected: config.selectedConnectorIDs,
                      magnification: scroll?.magnification ?? 1)
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
        func liveReposition(_ startPos: [UUID: CGPoint], dx: CGFloat, dy: CGFloat) {
            guard let cv = collection else { return }
            let t = CATransform3DMakeTranslation(dx, dy, 0)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for id in startPos.keys {
                guard let idx = nodes.firstIndex(where: { $0.id == id }) else { continue }
                cv.item(at: IndexPath(item: idx, section: 0))?.view.layer?.transform = t
            }
            CATransaction.commit()
            // Native connectors: rebuild paths with the live visual positions.
            // Use startPos (captured at drag-start) for dragged endpoints so
            // config.nodes staleness can never cause a position mismatch.
            if let cc = connectorController {
                let minX = config.worldBounds.minX, minY = config.worldBounds.minY
                var frames: [UUID: CGRect] = [:]
                for n in config.nodes {
                    if let sp = startPos[n.id] {
                        frames[n.id] = CGRect(x: sp.x - minX + dx, y: sp.y - minY + dy,
                                              width: max(1, n.width), height: max(1, n.height ?? 120))
                    } else {
                        frames[n.id] = CGRect(x: n.position.x - minX, y: n.position.y - minY,
                                              width: max(1, n.width), height: max(1, n.height ?? 120))
                    }
                }
                cc.update(connectors: config.connectors, nodeFrames: frames,
                          selected: config.selectedConnectorIDs,
                          magnification: scroll?.magnification ?? 1)
            }
        }

        /// End of a move: write each dragged item's final frame into the layout
        /// cache, then `reloadData` to rebuild + REPAINT every item at its new
        /// position. A bare `invalidateLayout()` (or a per-item layer transform)
        /// does NOT repaint the rasterized zoomed-out canvas — which is why a
        /// low-zoom group move "didn't move" no matter what we set. `reloadData`
        /// forces a full repaint, so the commit lands at ANY magnification.
        func endLiveReposition(_ startPos: [UUID: CGPoint], dx: CGFloat, dy: CGFloat) {
            guard let cv = collection, let layout = layout else { return }
            let minX = config.worldBounds.minX, minY = config.worldBounds.minY
            for (id, sp) in startPos {
                guard let idx = nodes.firstIndex(where: { $0.id == id }), idx < layout.itemFrames.count
                else { continue }
                let n = nodes[idx]
                layout.itemFrames[idx] = CGRect(x: sp.x + dx - minX, y: sp.y + dy - minY,
                                                width: max(1, n.width), height: max(1, n.height ?? 120))
                // Clear the live drag transform explicitly (don't rely on reloadData
                // to discard it — required if item recycling is ever enabled).
                cv.item(at: IndexPath(item: idx, section: 0))?.view.layer?.transform = CATransform3DIdentity
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

        /// A card FILED into a folder flies into it: snapshot the card, then
        /// shrink + translate the ghost to the folder's centre and fade — Spatial's
        /// "card jumps inside". Reuses `spawnExitSnapshots`' bitmap-ghost trick but
        /// aims at the folder instead of straight down. Purely cosmetic + guarded.
        private func spawnFolderDropSnapshots(_ filed: Set<UUID>, into folderID: UUID) {
            guard let cv = collection, let container = container,
                  let folderCard = cv.visibleItems()
                      .compactMap({ ($0 as? HostingCollectionItem)?.cardView })
                      .first(where: { $0.nodeID == folderID }),
                  folderCard.bounds.width > 1
            else { return }
            let folderCenter = container.convert(
                CGPoint(x: folderCard.bounds.midX, y: folderCard.bounds.midY), from: folderCard)
            var flew = false
            for item in cv.visibleItems() {
                guard let card = (item as? HostingCollectionItem)?.cardView,
                      let id = card.nodeID, filed.contains(id),
                      card.bounds.width > 1, card.bounds.height > 1,
                      let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds)
                else { continue }
                card.cacheDisplay(in: card.bounds, to: rep)
                guard let cg = rep.cgImage else { continue }
                // Start at the card's current visual position (fold in the live drag
                // translation if it's still on the layer, so the fly-in begins where
                // the user released rather than at the card's home slot).
                var frame = container.convert(card.bounds, from: card)
                if let t = card.layer?.transform { frame.origin.x += t.m41; frame.origin.y += t.m42 }
                let ghost = CALayer()
                ghost.contents = cg
                ghost.frame = frame
                ghost.contentsGravity = .resizeAspect
                ghost.zPosition = 60
                container.layer?.addSublayer(ghost)

                let c = CGPoint(x: ghost.bounds.midX, y: ghost.bounds.midY)
                let dx = folderCenter.x - frame.midX, dy = folderCenter.y - frame.midY
                let target = CATransform3DConcat(
                    CATransform3DConcat(CATransform3DMakeTranslation(-c.x, -c.y, 0),
                                        CATransform3DMakeScale(0.12, 0.12, 1)),
                    CATransform3DMakeTranslation(c.x + dx, c.y + dy, 0))
                CATransaction.begin()
                CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
                let s = CASpringAnimation(keyPath: "transform")
                s.fromValue = CATransform3DIdentity; s.toValue = target
                s.stiffness = CLIPSpring.Preset.settle.stiffness
                s.damping = CLIPSpring.Preset.settle.caDamping
                s.duration = s.settlingDuration
                let o = CABasicAnimation(keyPath: "opacity")
                o.fromValue = 1; o.toValue = 0; o.duration = 0.38
                o.timingFunction = CLIPSpring.easeOutSoft
                ghost.transform = target; ghost.opacity = 0
                ghost.add(s, forKey: "dropFly"); ghost.add(o, forKey: "dropFade")
                CATransaction.commit()
                flew = true
            }
            if flew { MainActor.assumeIsolated { Haptics.generic() } }
        }

        /// Center + fit the actual content (the nodes' bounding rect, not the
        /// padded world) in the viewport. Run once the scroll view has a real
        /// size, so the canvas opens framed on the cards rather than off in the
        /// empty margin.
        func fitContent() {
            guard let scroll else { return }
            let p = config
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
    /// coordinator's `config` is refreshed every update).
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
        let selected = valid && nodeID.map { coordinator?.config.liveSelection().contains($0) == true } ?? false
        // Folders show selection via their glow art + a slight scale (Spatial),
        // not the white ring.
        let folderView = subviews.compactMap { $0 as? FolderCardView }.first
        folderView?.setSelected(selected)
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
        // Folders show selection via their own subtle scale (FolderCardView.setSelected),
        // NOT the node-bounds ring — that rect ring doesn't trace the folder silhouette
        // and reads as a broken stray outline.
        fade(selectionLayer, to: (selected && folderView == nil) ? 1 : 0)
        // Every NON-folder card pops with the same subtle scale folders use
        // (folders apply it via FolderCardView.setSelected above).
        if folderView == nil { applySelectionScale(selected) }
        let showHandles = selected && resizeEnabled
        for h in handleLayers { fade(h, to: showHandles ? 1 : 0) }
    }

    private var lastSelectedForScale = false
    /// Subtle "pop" on selection for every card (Spatial). Scales the content
    /// subviews (they fill the card) around the card centre — NOT the item's own
    /// layer, which carries the live-drag transform, so the two compose cleanly.
    /// No-op when selection state hasn't changed — avoids per-call layer writes
    /// during zoom ticks and resize ticks where selection is stable.
    private func applySelectionScale(_ selected: Bool) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        guard selected != lastSelectedForScale else { return }
        lastSelectedForScale = selected
        let factor: CGFloat = selected ? 1.04 : 1.0
        let cx = bounds.width / 2, cy = bounds.height / 2
        let t = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-cx, -cy, 0),
                                CATransform3DMakeScale(factor, factor, 1)),
            CATransform3DMakeTranslation(cx, cy, 0))
        for sv in subviews {
            guard let layer = sv.layer else { continue }
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = layer.presentation()?.transform ?? layer.transform
            a.toValue = t
            a.duration = 0.18
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: "selectScale")
            layer.transform = t
        }
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

    /// Set when this item represents a freshly-added node; the scale-in fires
    /// from `layout()` once the collection view has given the item real bounds
    /// (the async path raced the collection-view layout and could no-op).
    var wantsAppear = false

    private var liveNode: CanvasNode? {
        guard let id = nodeID else { return nil }
        return coordinator?.config.nodes.first { $0.id == id }
    }
    /// Whether this item is the lone selected resizable node — drives whether
    /// the corner handles are drawn (display only; the resize gesture lives in
    /// CanvasInputView). Reads the LIVE selection so it's never one event stale.
    private var resizeEnabled: Bool {
        guard let n = liveNode, let id = nodeID,
              let sel = coordinator?.config.liveSelection(),
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
        if wantsAppear, bounds.width > 1, bounds.height > 1 {
            wantsAppear = false
            playAppear()
        }
    }

    /// Only solid card tiles cast a float shadow. Drawings, text frames and
    /// sections are transparent, so a full-rect layer shadow would show THROUGH
    /// them as an ugly grey box — they get none.
    private func castsShadow(_ kind: CanvasNode.Kind) -> Bool {
        switch kind {
        case .image, .video, .tweet, .instagram, .youtube, .webclip, .stickyNote:
            return true
        case .text, .drawing, .section, .folder:
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
    /// Typed item view, set in `loadView` — avoids a force-cast on a hot accessor.
    private(set) var cardView = CardItemView()

    override func loadView() {
        cardView.wantsLayer = true
        view = cardView
    }

    /// Install native content for the node if a native renderer exists; else
    /// host the SwiftUI fallback. `swiftUI` is an autoclosure so we don't build
    /// the SwiftUI card for natively-rendered kinds.
    func setContent(node: CanvasNode, swiftUI: @autoclosure () -> AnyView,
                    isEditing: Bool = false) {
        // The outgoing video VIEW is cached by node id (NativeVideoCache) so it's
        // re-parented to its next item instead of rebuilt — no reload/blink. Tell
        // the cache it detached so off-screen videos still tear down ~1.2s later.
        if FeatureFlags.useWebViewCache,
           let vid = nativeContent as? CardVideoContentView, let id = vid.cacheNodeID {
            NativeVideoCache.shared.park(id)
        }
        // A text node in edit mode falls back to the SwiftUI inline editor
        // (auto-sizing field + focus); every other case prefers native content.
        if let native = isEditing ? nil : makeNativeCardContent(for: node) {
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
