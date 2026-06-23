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
    /// Fired on every live magnify tick so connector stroke widths (÷ magnification
    /// → constant on-screen) and the inline label editor track the zoom in real
    /// time (the contentView bounds notification alone lagged the pinch).
    var onZoomChange: (() -> Void)?
    override func magnify(with event: NSEvent) {
        let target = max(minMagnification,
                         min(maxMagnification, magnification * (1 + event.magnification)))
        let point = documentView?.convert(event.locationInWindow, from: nil)
            ?? convert(event.locationInWindow, from: nil)
        setMagnification(target, centeredAt: point)   // routes through the override below
    }
    override func setMagnification(_ magnification: CGFloat, centeredAt point: NSPoint) {
        super.setMagnification(magnification, centeredAt: point)
        onZoomChange?()
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
    /// True in connect (connectors) mode — native drag-to-connect in CanvasInputView.
    let isConnectMode: () -> Bool
    /// True in hand (pan) mode — the above-island passes clicks through so
    /// `CanvasInputView` grabs-and-pans the scroll view (Figma hand tool).
    let isHandMode: () -> Bool
    /// Create a connector between two nodes (drag-to-connect commit): src, dst,
    /// the source side it was drawn from, the target side it was dropped onto.
    let onAddConnector: (UUID, UUID, ConnSide?, ConnSide?) -> Void
    /// Live marker colour + width for the native draw preview.
    let drawColor: () -> NSColor
    let drawWidth: () -> CGFloat
    /// Commit a finished stroke (points in WORLD coords).
    let onCommitStroke: ([CGPoint]) -> Void
    /// Phase B native connectors (flag-gated). When `useNativeConnectors` is
    /// true, `ConnectorOverlayController` draws these as CAShapeLayers in the
    /// scrolled container and the SwiftUI ConnectorsLayer overlay is left empty.
    let connectors: [Connector]
    /// Whether the connector overlay is shown (bottom-left controls toggle).
    let showConnectors: Bool
    let useNativeConnectors: Bool
    /// Select (or clear) a connector — native connector click-select.
    let onSelectConnector: (UUID?) -> Void
    /// Set a connector's midpoint label (double-click to edit).
    let onSetConnectorLabel: (UUID, String) -> Void
    /// Persist a dragged connector label's offset from the bezier midpoint.
    let onMoveConnectorLabel: (UUID, CGPoint) -> Void
    /// Selected connector ids — drives the native connector highlight colour.
    let selectedConnectorIDs: Set<UUID>
    /// Empty-canvas click → deselect (cards handle their own selection taps).
    let onBackgroundClick: () -> Void
    /// Delete the current selection (Delete/⌫ key — driven by a native key
    /// monitor since the SwiftUI menu shortcut goes stale-disabled).
    let onDelete: () -> Void
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
    /// True while the camera is panning/zooming — native video pauses to its
    /// poster so an AVPlayerLayer doesn't composite during the magnify (LOD).
    let isCameraInteracting: Bool
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
    /// Option-drag duplicate: clone these ids IN PLACE and return original→copy id
    /// mapping (the drag retargets onto the copies; copies render as posters via
    /// `draggingNodeIDs` so the drag stays smooth, then go live on release).
    let onOptionDuplicate: (Set<UUID>) -> [UUID: UUID]
    /// Move a node to a new WORLD position (per drag tick). Uses the move API
    /// (`updatePosition`) so connectors stay attached — NOT `resize`.
    let onMove: (UUID, CGPoint) -> Void
    /// Resize a node to a new WORLD frame (per drag tick).
    let onResize: (UUID, CGRect) -> Void
    /// Rotate a node (radians around its centre) — per drag tick of the handle.
    let onRotate: (UUID, CGFloat) -> Void
    /// Double-click a node → activate (text edit / stack focus / lightbox).
    let onActivate: (UUID) -> Void
    /// Commit an inline folder rename: (folder id, new title).
    let onRenameFolder: (UUID, String) -> Void
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
        var deleteMonitor: Any?
        var colorPicker: RadialColorPicker?
        var connectorController: ConnectorOverlayController?
        var guideController: GuideOverlayController?
        // Inline connector-label editor (double-click a connector).
        var editingConnectorID: UUID?
        var editingConnectorField: NSTextField?
        var editingConnectorPill: NSView?      // green-pill wrapper (Figma 88-422)
        var editingConnectorEnter: NSImageView?
        var editingConnectorMonitor: Any?      // click-outside-to-commit monitor
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
        /// Node currently under the cursor (drives the hover state — scale +
        /// elevated shadow). Set by `CanvasInputView`'s mouse tracking; read by
        /// `CardItemView.updateChrome`. `nil` = nothing hovered.
        var hoveredNodeID: UUID?

        init(_ config: CanvasConfig) { self.config = config }

        func detach() {
            if let o = boundsObserver { NotificationCenter.default.removeObserver(o) }
            if let m = escMonitor { NSEvent.removeMonitor(m) }
            if let m = colorKeyMonitor { NSEvent.removeMonitor(m) }
            if let m = deleteMonitor { NSEvent.removeMonitor(m) }
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
                // Filed-into-folder cards get the SAME scale-down + fade as a delete
                // (preferred over a fly-into-folder jump).
                let exiting = deleted.union(filed.values.reduce(into: Set<UUID>()) { $0.formUnion($1) })
                if !exiting.isEmpty { spawnExitSnapshots(exiting) }
            }
            // World-extent geometry — doesn't affect the data-source count, so it's
            // safe to apply before any batch update.
            layout?.contentSize = p.worldBounds.size
            (collection as? WideCollectionView)?.contentWidth = p.worldBounds.size.width
            // Keep the document container + overlay's content-coordinate camera
            // in sync with the world extent.
            if container?.frame.size != p.worldBounds.size {
                container?.setFrameSize(p.worldBounds.size)
                collection?.setFrameSize(p.worldBounds.size)
                overlayHost?.setFrameSize(p.worldBounds.size)
            }

            // Count-change strategy. An insert/delete/folder-fill that keeps the
            // surviving cards' relative order is applied with `performBatchUpdates`
            // so the SURVIVING item views (and their cached AVPlayer / WKWebView
            // layers) are NOT re-created or re-parented — that re-parent is the
            // add/delete/fill video blink. The data source is mutated INSIDE the
            // batch (count-safe), and the folder survivor's count refreshes via the
            // content pass below. `reloadData` stays the fallback for REORDERS only.
            let oldIDset = Set(oldOrderedIDs)
            let newIDs = p.nodes.map(\.id)
            let orderPreserved = oldOrderedIDs.filter { currentIDs.contains($0) }
                               == newIDs.filter { oldIDset.contains($0) }
            let pureBatch = countChanged && orderPreserved

            if pureBatch, let cv = collection {
                let deletedPaths = Set(oldOrderedIDs.enumerated()
                    .filter { !currentIDs.contains($0.element) }
                    .map { IndexPath(item: $0.offset, section: 0) })
                let insertedPaths = Set(newIDs.enumerated()
                    .filter { !oldIDset.contains($0.element) }
                    .map { IndexPath(item: $0.offset, section: 0) })
                cv.performBatchUpdates({
                    // Mutate the data source INSIDE the batch: NSCollectionView reads
                    // the OLD count at entry and the NEW count after the block, so the
                    // delete/insert ops must straddle the `nodes` swap (deletes index
                    // the old array, inserts the new — per AppKit's contract).
                    nodes = p.nodes
                    layout?.itemFrames = frames
                    layout?.invalidateLayout()
                    if !deletedPaths.isEmpty { cv.deleteItems(at: deletedPaths) }
                    if !insertedPaths.isEmpty { cv.insertItems(at: insertedPaths) }
                }, completionHandler: nil)
            } else if countChanged {
                nodes = p.nodes
                layout?.itemFrames = frames
                layout?.invalidateLayout()
                collection?.reloadData()
            } else if framesChanged {
                nodes = p.nodes
                layout?.itemFrames = frames
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
            } else {
                // No count/frame change (content-only — e.g. a section recolour or
                // sticky edit). Keep the data source + layout in sync; the refresh
                // below pushes the new payload into the existing item in place.
                nodes = p.nodes
                layout?.itemFrames = frames
            }
            // Content-only refresh: a native card (section/sticky/text/folder) whose
            // payload changed — e.g. a section recolour, or a FOLDER whose item count
            // changed when a card was filed (the survivor isn't re-created in the
            // batch path, so its count must be pushed in here). Runs after a
            // `pureBatch` too, since that path doesn't re-host survivors.
            if !countChanged || pureBatch, let cv = collection {
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

        // MARK: - Persistent per-node z-order (bring-to-front that STAYS)

        /// Monotonic z assigned to a node when it's selected; persists across
        /// deselect + reloadData (item views re-read it), so a clicked card stays
        /// above its neighbours WITHOUT reordering the model (no reload → no blink).
        private var zCounter: CGFloat = 0
        private var nodeZ: [UUID: CGFloat] = [:]
        func raiseZ(_ id: UUID) { zCounter += 1; nodeZ[id] = zCounter }
        func zFor(_ id: UUID) -> CGFloat { nodeZ[id] ?? 0 }

        /// Refresh the native selection chrome (white ring/handles) on every
        /// visible item. Driven by `liveSelection`, so calling this right after a
        /// selection change updates the ring SYNCHRONOUSLY — no waiting for the
        /// next SwiftUI re-render (which lagged the ring by one event).
        func refreshChrome() {
            guard let cv = collection else { return }
            // VIEWPORT CULLING (chrome only): every item stays MOUNTED (so cards
            // never blink in/out), but we skip the per-tick chrome + shadow recompute
            // for cards well outside the viewport — they're invisible, so there's
            // nothing to update. Cuts pan/zoom cost from O(all cards) to O(on-screen).
            let vis = cv.visibleRect
            let mx = vis.width * 0.35, my = vis.height * 0.35
            let near = vis.insetBy(dx: -mx, dy: -my)
            for ip in cv.indexPathsForVisibleItems() {
                if let card = (cv.item(at: ip) as? HostingCollectionItem)?.cardView {
                    guard near.intersects(card.frame) else { continue }
                    card.updateChrome()
                    card.updateShadow()      // fade the float shadow with zoom
                }
            }
            refreshConnectors()
            // Keep the inline label editor matched to the live zoom/pan.
            if let cid = editingConnectorID { positionEditor(at: cid) }
        }

        /// Live rotate ONE item's visual (no model write) during a handle drag —
        /// keeps FPS high. `angle == nil` clears the override (reads the model).
        func liveRotate(_ id: UUID, angle: CGFloat?) {
            guard let cv = collection else { return }
            for ip in cv.indexPathsForVisibleItems() {
                if let card = (cv.item(at: ip) as? HostingCollectionItem)?.cardView,
                   card.nodeID == id {
                    card.setLiveRotation(angle); return
                }
            }
        }

        /// Phase B native connectors: rebuild content-space node frames and push
        /// them into the CAShapeLayer controller. Driven from `refreshChrome`, so
        /// it tracks node changes (apply → refreshChrome) AND zoom (bounds
        /// observer → refreshChrome). No-op unless `useNativeConnectors`.
        func refreshConnectors() {
            guard let cc = connectorController else { return }
            cc.setVisible(config.showConnectors)        // honour the show/hide toggle
            let minX = config.worldBounds.minX, minY = config.worldBounds.minY
            var frames: [UUID: CGRect] = [:]
            for n in config.nodes {
                frames[n.id] = CGRect(x: n.position.x - minX, y: n.position.y - minY,
                                      width: max(1, n.width), height: max(1, n.height ?? 120))
            }
            // Committed frames only; live drag offsets live in the controller
            // (`setLiveDragOffsets`) and are re-applied on every redraw.
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
        // MARK: - Folder drop-over (Spatial: lid opens + dragged card shrinks)

        /// The folder the dragged cards are held over (drives lid-open + card-shrink).
        private var dropTargetID: UUID?

        /// Bounding-rect centre of the dragged cards at their LIVE position.
        private func draggedCentre(_ startPos: [UUID: CGPoint], dx: CGFloat, dy: CGFloat) -> CGPoint? {
            var rect: CGRect?
            for (id, sp) in startPos {
                guard let n = nodes.first(where: { $0.id == id }) else { continue }
                let r = CGRect(x: sp.x + dx, y: sp.y + dy, width: n.width, height: n.height ?? n.width)
                rect = rect?.union(r) ?? r
            }
            return rect.map { CGPoint(x: $0.midX, y: $0.midY) }
        }

        /// The live native `FolderCardView` for a folder node id (visible items).
        func folderContentView(_ id: UUID) -> FolderCardView? {
            guard let cv = collection else { return nil }
            for item in cv.visibleItems() {
                if let h = item as? HostingCollectionItem, h.cardView.nodeID == id,
                   let fv = h.nativeContentView as? FolderCardView { return fv }
            }
            return nil
        }

        /// Inline-rename a folder (double-click the name label) — drive the native
        /// title field into edit mode; commit routes back through `onRenameFolder`.
        func beginFolderRename(_ id: UUID) {
            folderContentView(id)?.beginRename { [weak self] newTitle in
                self?.config.onRenameFolder(id, newTitle)
            }
        }

        func liveReposition(_ startPos: [UUID: CGPoint], dx: CGFloat, dy: CGFloat) {
            guard let cv = collection else { return }
            let draggedIDs = Set(startPos.keys)

            // Drop-target: the dragged centre over a non-dragged folder (Spatial:
            // the shrunk card's centre lands on the folder).
            var newTarget: UUID?
            var fit: CGFloat = 1
            if let centre = draggedCentre(startPos, dx: dx, dy: dy) {
                for n in nodes {
                    guard case .folder = n.kind, !draggedIDs.contains(n.id) else { continue }
                    let fr = CGRect(x: n.position.x, y: n.position.y,
                                    width: n.width, height: n.height ?? 172)
                    if fr.contains(centre) {
                        newTarget = n.id
                        let cardH = startPos.keys.compactMap { id in nodes.first { $0.id == id } }
                            .map { $0.height ?? $0.width }.max() ?? 1
                        fit = max(0.28, min(0.6, (n.height ?? 172) * 0.5 / max(cardH, 1)))
                        break
                    }
                }
            }
            let targetChanged = newTarget != dropTargetID
            if targetChanged {
                dropTargetID.flatMap(folderContentView)?.setDropHover(false)     // close old lid
                if let new = newTarget {
                    folderContentView(new)?.setDropHover(true)                   // open new lid
                    MainActor.assumeIsolated { Haptics.generic() }               // one tap on enter
                }
                dropTargetID = newTarget
            }

            // Translate (+ shrink toward the folder) each dragged item.
            let t = CATransform3DMakeTranslation(dx, dy, 0)
            for id in startPos.keys {
                guard let idx = nodes.firstIndex(where: { $0.id == id }),
                      let view = cv.item(at: IndexPath(item: idx, section: 0))?.view else { continue }
                let xform: CATransform3D
                if newTarget != nil {
                    let cx = view.bounds.width / 2, cy = view.bounds.height / 2
                    let s = CATransform3DConcat(
                        CATransform3DConcat(CATransform3DMakeTranslation(-cx, -cy, 0),
                                            CATransform3DMakeScale(fit, fit, 1)),
                        CATransform3DMakeTranslation(cx, cy, 0))
                    xform = CATransform3DConcat(s, t)
                } else {
                    xform = t
                }
                if targetChanged {
                    // Animate the shrink / grow on enter / exit (0.16s ease).
                    let a = CABasicAnimation(keyPath: "transform")
                    a.fromValue = view.layer?.presentation()?.transform ?? view.layer?.transform ?? xform
                    a.toValue = xform
                    a.duration = 0.16
                    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    view.layer?.transform = xform
                    view.layer?.add(a, forKey: "dropShrink")
                } else {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    view.layer?.transform = xform
                    CATransaction.commit()
                }
            }

            // Native connectors track the dragged cards live (model commits on up).
            if let cc = connectorController {
                var offs: [UUID: CGPoint] = [:]
                for id in startPos.keys { offs[id] = CGPoint(x: dx, y: dy) }
                cc.setLiveDragOffsets(offs)
            }
        }

        /// End of a move: write each dragged item's final frame into the layout
        /// cache, then `reloadData` to rebuild + REPAINT every item at its new
        /// position. A bare `invalidateLayout()` (or a per-item layer transform)
        /// does NOT repaint the rasterized zoomed-out canvas — which is why a
        /// low-zoom group move "didn't move" no matter what we set. `reloadData`
        /// forces a full repaint, so the commit lands at ANY magnification.
        func endLiveReposition(_ startPos: [UUID: CGPoint], dx: CGFloat, dy: CGFloat) {
            // Close any open folder lid; if a card was filed, apply()'s refresh +
            // spawnFolderDropSnapshots take over the "jump inside".
            if let t = dropTargetID { folderContentView(t)?.setDropHover(false); dropTargetID = nil }
            guard let cv = collection, let layout = layout else { return }
            let minX = config.worldBounds.minX, minY = config.worldBounds.minY
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (id, sp) in startPos {
                guard let idx = nodes.firstIndex(where: { $0.id == id }), idx < layout.itemFrames.count
                else { continue }
                let n = nodes[idx]
                let f = CGRect(x: sp.x + dx - minX, y: sp.y + dy - minY,
                               width: max(1, n.width), height: max(1, n.height ?? 120))
                layout.itemFrames[idx] = f
                // Commit the move by repositioning the item VIEW DIRECTLY (and clear
                // its live-drag transform) — NOT via `reloadData`, which re-parents
                // the cached AVPlayer video views and flashes their AVPlayerLayer
                // black for a frame (the drag-release / quick-select video blink).
                if let item = cv.item(at: IndexPath(item: idx, section: 0)) {
                    item.view.layer?.transform = CATransform3DIdentity
                    item.view.frame = f
                }
            }
            CATransaction.commit()
            // Redraw connectors at the COMMITTED positions and clear the live
            // drag offset in one shot (avoids a double-offset / snap-back flicker
            // before SwiftUI's updateNSView round-trips the new model positions).
            if let cc = connectorController {
                var frames: [UUID: CGRect] = [:]
                for n in nodes {
                    let p = startPos[n.id].map { CGPoint(x: $0.x + dx, y: $0.y + dy) } ?? n.position
                    frames[n.id] = CGRect(x: p.x - minX, y: p.y - minY,
                                          width: max(1, n.width), height: max(1, n.height ?? 120))
                }
                cc.setLiveDragOffsets([:])
                cc.update(connectors: config.connectors, nodeFrames: frames,
                          selected: config.selectedConnectorIDs,
                          magnification: scroll?.magnification ?? 1)
            }
            layout.invalidateLayout()
            // NB: no `reloadData()` here — the moved item views were repositioned
            // directly above, so videos never re-parent (no blink). The model
            // round-trip via `apply`'s `framesChanged` path confirms the commit.
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
                // The dragged card is corner-anchored (layer anchorPoint 0,0) and may
                // be SHRUNK + translated over the folder. Reproduce its exact current
                // transform on the ghost (same anchor + home frame) so the fly-in
                // begins seamlessly from the shrunk card, then springs it to a dot at
                // the folder centre.
                let live = card.layer?.transform ?? CATransform3DIdentity
                let home = container.convert(card.bounds, from: card)   // full-size home rect
                let ghost = CALayer()
                ghost.contents = cg
                ghost.contentsGravity = .resizeAspect
                ghost.zPosition = 60
                ghost.anchorPoint = .zero                               // match the card's layer
                ghost.frame = home
                container.layer?.addSublayer(ghost)

                let c = CGPoint(x: home.width / 2, y: home.height / 2)
                let dx = folderCenter.x - home.midX, dy = folderCenter.y - home.midY
                let target = CATransform3DConcat(
                    CATransform3DConcat(CATransform3DMakeTranslation(-c.x, -c.y, 0),
                                        CATransform3DMakeScale(0.12, 0.12, 1)),
                    CATransform3DMakeTranslation(c.x + dx, c.y + dy, 0))
                CATransaction.begin()
                CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
                let s = CASpringAnimation(keyPath: "transform")
                s.fromValue = live; s.toValue = target
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
            // Honor a persisted camera (per-page zoom memory): only auto-fit a page
            // that has never been framed — i.e. its camera is still the default
            // `Camera()`. A restored zoom/pan (non-default) is left exactly as saved.
            let cam = p.camera
            if cam.zoom != 1 || cam.x != 0 || cam.y != 0 { return }
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
    /// Selection outline (cards): a white rounded rect sitting an **8px gap**
    /// outside the (scaled) card edge, **4px** thick, **8px** corner radius — all
    /// three constant on-screen (÷ magnification). Shown on SELECT only (Figma
    /// 88:336). Folders draw their own curved silhouette outline instead.
    private let outlineLayer = CAShapeLayer()
    /// Inner hairline (0.5px, 15% black, drawn INSIDE the card edge) on media
    /// cards — defines the card against the light canvas. Always on.
    private let innerHairlineLayer = CAShapeLayer()
    /// Rotate handle — a small dot on a short stem above the top-middle edge,
    /// shown on SELECT. Rotates + scales WITH the card (it's in the lift/rotate
    /// transform group), so it always sits at the card's rotated "top".
    private let rotateHandleLayer = CAShapeLayer()
    /// BAKED drop shadow: a dedicated rasterized layer BEHIND the content so the
    /// soft blur is computed once and cheaply *resampled* when zooming (NSScrollView
    /// magnification is an ancestor transform) instead of re-blurred every frame —
    /// the high-zoom FPS fix. Content stays unrasterized (crisp). The zoom-out fade
    /// rides this layer's `opacity` (composite-time → no re-raster); only a
    /// lift/resize changes the baked `shadowPath`/radius and re-bakes.
    private let shadowLayer = CALayer()
    /// Tracks the select→deselect edge so we only bump the persistent z ONCE per
    /// selection (not on every chrome refresh).
    private var wasSelectedForZ = false
    /// Hover/selected scale, applied to every canvas object EXCEPT marker
    /// drawings (user spec). Same factor for hover and select (not compounded).
    static let liftScale: CGFloat = 1.02

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupChrome()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: - Native chrome (section outline + selection ring + handles)

    private func setupChrome() {
        // Baked shadow caster — BACKMOST (behind content), rasterized so a zoom
        // just resamples the cached blur. Driven in `updateShadow`; the item's own
        // layer no longer casts (set its shadowOpacity 0).
        shadowLayer.zPosition = -1
        shadowLayer.masksToBounds = false
        shadowLayer.backgroundColor = nil            // invisible body; only the shadow shows
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shouldRasterize = true
        shadowLayer.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2
        shadowLayer.magnificationFilter = .trilinear
        shadowLayer.opacity = 0
        layer?.addSublayer(shadowLayer)
        layer?.shadowOpacity = 0

        // Section outline — a crisp neutral border so empty section frames read
        // clearly at any zoom (the SwiftUI 1pt border vanished when zoomed out).
        sectionLayer.fillColor = nil
        sectionLayer.strokeColor = NSColor.tertiaryLabelColor.cgColor
        sectionLayer.zPosition = 99
        sectionLayer.isHidden = true
        layer?.addSublayer(sectionLayer)

        // Selection outline uses `opacity` (not isHidden) so it FADES in/out;
        // starts transparent. White stroke with a faint black drop shadow for
        // depth (Figma 88:340), geometry set per-frame in `updateChrome`.
        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = NSColor.white.cgColor
        outlineLayer.lineJoin = .round
        outlineLayer.shadowColor = NSColor.black.cgColor
        outlineLayer.shadowOpacity = 0.12
        outlineLayer.shadowOffset = .zero
        outlineLayer.zPosition = 100
        outlineLayer.opacity = 0
        layer?.addSublayer(outlineLayer)

        // Inner card hairline — black 15%, 0.5px, drawn inside the edge.
        innerHairlineLayer.fillColor = nil
        innerHairlineLayer.strokeColor = NSColor.black.withAlphaComponent(0.15).cgColor
        innerHairlineLayer.zPosition = 98
        innerHairlineLayer.isHidden = true
        layer?.addSublayer(innerHairlineLayer)

        // Rotate handle (dot + stem) — green on white, shown on select.
        rotateHandleLayer.fillColor = NSColor.white.cgColor
        rotateHandleLayer.strokeColor = NSColor(srgbRed: 0.239, green: 0.655, blue: 0.149, alpha: 1).cgColor
        rotateHandleLayer.lineWidth = 1.5
        rotateHandleLayer.zPosition = 101
        rotateHandleLayer.opacity = 0
        layer?.addSublayer(rotateHandleLayer)
    }

    /// Screen-constant geometry of the rotate handle (stem length + dot radius,
    /// ÷mag) — shared by the renderer and the input hit-test. The dot centre is at
    /// `(midX, -gap - stem)` in the item's (unrotated) coordinate space.
    static func rotateHandleGeometry(mag: CGFloat) -> (gap: CGFloat, stem: CGFloat, dot: CGFloat) {
        (gap: 7 / mag, stem: 22 / mag, dot: 5.5 / mag)
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
        let folderView = subviews.compactMap { $0 as? FolderCardView }.first
        let selected = valid && isSelectedNow
        let hovered = valid && isHoveredNow
        let lifted = selected || hovered
        // Bring a card to front on selection and KEEP it there after deselect — via
        // a PERSISTENT per-node zPosition held by the coordinator (NOT a model
        // reorder, which would force a `reloadData` and blink videos). The z value
        // survives reload because each item re-reads it here.
        if let id = nodeID {
            if selected && !wasSelectedForZ { coordinator?.raiseZ(id) }
            wasSelectedForZ = selected
            layer?.zPosition = coordinator?.zFor(id) ?? 0
        }
        var isDrawing = false, wantsHairline = false
        switch node?.kind {
        case .drawing: isDrawing = true
        case .image, .video, .stickyNote, .text: wantsHairline = true
        default: break
        }
        let liftS: CGFloat = (lifted && !isDrawing) ? Self.liftScale : 1.0

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

        // Selection outline geometry (cards only — folders trace their own
        // silhouette). Always sized so it's correct the instant it fades in.
        // Lengths are SCREEN-constant (÷mag) so the gap/thickness DON'T drift as
        // you zoom — a clean fixed 8px gap / 4px line like Figma at every zoom.
        // The 4px stroke is drawn INSIDE the gap boundary (Figma border-box): the
        // outer edge sits 8px out from the card frame, the stroke grows inward →
        // centreline at gap − 2px, outer corner radius 8px.
        if valid, folderView == nil {
            let lineW = 4 / mag, gap = 7 / mag      // gap 1px smaller (was 8)
            let inset = -(gap - lineW / 2)
            let rect = bounds.insetBy(dx: inset, dy: inset)
            // Square cards → radius = gap; stickies add their 37pt corner; text is
            // a full pill (height/2). Same white ring for all — just the shape differs.
            let cardR: CGFloat = node?.isStickyNote == true ? StickyNodeView.cornerRadius * liftS
                               : node?.isText == true ? bounds.height / 2 : 0
            let radius = cardR + gap - lineW / 2    // outer corner radius
            outlineLayer.path = CGPath(roundedRect: rect, cornerWidth: radius,
                                       cornerHeight: radius, transform: nil)
            outlineLayer.lineWidth = lineW
            outlineLayer.shadowRadius = 2 / mag
        }

        // Inner card hairline (media + sticky): 0.5px black 15%, drawn INSIDE the
        // (scaled) card edge. Screen-constant (÷mag) so it stays a visible 0.5px
        // at any zoom; tracks the scaled card edge via `liftS`.
        if valid, wantsHairline {
            let sw = bounds.width * liftS, sh = bounds.height * liftS
            let scaled = CGRect(x: (bounds.width - sw) / 2, y: (bounds.height - sh) / 2,
                                width: sw, height: sh)
            let lw = 0.5 / mag
            // Stickies are rounded (37pt) and text is a full pill (height/2) —
            // round the hairline to match. Media cards stay square (r = 0).
            let r: CGFloat = node?.isStickyNote == true ? StickyNodeView.cornerRadius * liftS
                           : node?.isText == true ? scaled.height / 2 : 0
            innerHairlineLayer.path = CGPath(roundedRect: scaled.insetBy(dx: lw / 2, dy: lw / 2),
                                             cornerWidth: r, cornerHeight: r, transform: nil)
            innerHairlineLayer.lineWidth = lw
            innerHairlineLayer.isHidden = false
        } else {
            innerHairlineLayer.isHidden = true
        }

        // Rotate handle (dot on a stem) above the top-middle edge — flipped view,
        // so "above" is negative y. Drawn unrotated here; the lift/rotate transform
        // (applyLiftScale) carries it to the card's rotated top.
        if valid, folderView == nil, !(node?.isSection ?? false) {
            let geo = Self.rotateHandleGeometry(mag: mag)
            let midX = bounds.midX
            let topY = -geo.gap
            let dotC = CGPoint(x: midX, y: topY - geo.stem)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: midX, y: topY))
            p.addLine(to: CGPoint(x: dotC.x, y: dotC.y + geo.dot))
            p.addEllipse(in: CGRect(x: dotC.x - geo.dot, y: dotC.y - geo.dot,
                                    width: geo.dot * 2, height: geo.dot * 2))
            rotateHandleLayer.path = p
            rotateHandleLayer.lineWidth = 1.5 / mag
        }
        CATransaction.commit()

        // Animated visibility (fade) — OUTSIDE the no-animation transaction.
        // Outline shows on SELECT only (hover never shows it, per Figma 88:330).
        let showOutline = selected && folderView == nil
        fade(outlineLayer, to: showOutline ? 1 : 0)
        fade(rotateHandleLayer, to: (showOutline && !(node?.isSection ?? false)) ? 1 : 0)
        // Lift scale (hover OR select): folders scale + show their curved outline
        // internally; every other card scales its content here.
        if let folderView {
            folderView.setState(lifted: lifted, selected: selected, mag: mag)
        } else {
            applyLiftScale(lifted, kind: node?.kind,
                           angle: liveRotationOverride ?? (node?.rotation ?? 0))
        }
    }

    /// Live (drag-time) rotation override — set while the rotate handle is being
    /// dragged so the visual tracks WITHOUT a per-tick model write (which would
    /// re-render all of SwiftUI and tank FPS). Committed to the model on mouse-up.
    var liveRotationOverride: CGFloat?
    func setLiveRotation(_ angle: CGFloat?) {
        liveRotationOverride = angle
        guard bounds.width > 1 else { return }
        let n = liveNode
        let lifted = isSelectedNow || isHoveredNow
        applyLiftScale(lifted, kind: n?.kind, angle: angle ?? (n?.rotation ?? 0))
        updateShadow()      // re-bake the rotated shadow silhouette live
    }

    private var lastLiftFactor: CGFloat = 1.0
    private var lastAngle: CGFloat = 0
    /// Hover/selected "pop" for every card except marker drawings. Scales the
    /// content subviews (they fill the card) around the card centre — NOT the
    /// item's own layer, which carries the live-drag transform, so the two
    /// compose cleanly. The SAME transform is applied to the selection outline +
    /// inner hairline + section border (chrome sublayers) so they scale in
    /// LOCKSTEP with the card — this is what keeps the outline's gap a constant
    /// 8px from the *visible* (scaled) card edge at any zoom, instead of the card
    /// poking through it. Re-applied every call so it survives a `reloadData`; it
    /// only ANIMATES when the factor changes.
    private func applyLiftScale(_ lifted: Bool, kind: CanvasNode.Kind?, angle: CGFloat) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        var isDrawing = false
        if case .drawing = kind { isDrawing = true }
        let factor: CGFloat = (lifted && !isDrawing) ? Self.liftScale : 1.0
        let cx = bounds.width / 2, cy = bounds.height / 2
        // T = translate(c) · scale(factor) · rotate(angle) · translate(-c)
        var t = CATransform3DMakeTranslation(-cx, -cy, 0)
        if angle != 0 { t = CATransform3DConcat(t, CATransform3DMakeRotation(angle, 0, 0, 1)) }
        t = CATransform3DConcat(t, CATransform3DMakeScale(factor, factor, 1))
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(cx, cy, 0))
        // Spring ONLY the lift pop; rotation must track the drag live (no implicit
        // animation), so a rotation change sets the transform inside a disabled
        // transaction instead.
        let animateLift = factor != lastLiftFactor && angle == lastAngle
        lastLiftFactor = factor
        lastAngle = angle
        let contentLayers = subviews.compactMap { $0.layer }
        let all = contentLayers + [outlineLayer, innerHairlineLayer,
                                   sectionLayer, rotateHandleLayer]
        for layer in all {
            if animateLift {
                layer.add(Self.liftSpring(from: layer.presentation()?.transform ?? layer.transform,
                                          to: t), forKey: "liftScale")
                layer.transform = t
            } else {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.transform = t
                CATransaction.commit()
            }
        }
        // The shadow does NOT use a layer transform (its offset frame +
        // anchorPoint made every pivot slide it). Its rotation is baked straight
        // into the `shadowPath` in `updateShadow` instead — bulletproof.
    }

    /// The canvas-item scale spring (Spatial's `CanvasItemsAnimator` /
    /// `resetScaleWithStiffness:damping:`). Critically damped — a smooth fast
    /// ease with NO overshoot/bounce, settling ~150ms (stiffness 950, mass 1,
    /// damping 64 → ζ≈1.0). Shared by cards + folders.
    static func liftSpring(from: CATransform3D, to: CATransform3D) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: "transform")
        a.fromValue = from
        a.toValue = to
        a.stiffness = 950
        a.damping = 64
        a.mass = 1
        if #available(macOS 14.0, *) { a.allowsOverdamping = true }
        a.duration = a.settlingDuration
        a.fillMode = .forwards
        return a
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
    /// Live select/hover state (reads the coordinator so it's never one event
    /// stale). `isLifted` = either → drives the 1.06 scale + elevated shadow.
    private var isSelectedNow: Bool {
        nodeID.map { coordinator?.config.liveSelection().contains($0) == true } ?? false
    }
    private var isHoveredNow: Bool { nodeID != nil && coordinator?.hoveredNodeID == nodeID }
    private var isLifted: Bool { isSelectedNow || isHoveredNow }

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

    /// Cards are square (Figma), so the float shadow is square too.
    private let shadowCornerRadius: CGFloat = CardChrome.cornerRadius

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
        case .image, .video, .tweet, .instagram, .youtube, .webclip, .stickyNote, .text:
            return true
        case .drawing, .section, .folder:
            return false
        }
    }

    /// The float shadow lives on a dedicated BAKED `shadowLayer` (rasterized), not
    /// the item's own layer, so zooming resamples a cached blur instead of
    /// re-running the gaussian every frame (the high-zoom FPS fix). The expensive
    /// parts (`shadowPath`/radius/offset/`shadowOpacity`) change only on lift/resize
    /// → the cache is reused across zoom ticks; the zoom-out fade rides the layer's
    /// composite `opacity`, which never invalidates the cache.
    private var lastLiftedForShadow: Bool?
    /// Skips the shadow path/radius/offset re-bake when geometry/rotation is
    /// unchanged (the common pan/zoom case) — only the zoom-fade opacity updates.
    private var lastShadowGeomKey: String = ""
    /// Enlarge the shadow layer past the card so rasterization can't clip the blur.
    private static let shadowMargin: CGFloat = 48
    func updateShadow() {
        guard layer != nil else { return }
        layer?.masksToBounds = false
        guard let n = liveNode, castsShadow(n.kind), bounds.width > 1, bounds.height > 1 else {
            shadowLayer.opacity = 0
            lastLiftedForShadow = nil
            return
        }
        // Fade out when zoomed far out (Spatial's minMagnificationForShadow): dozens
        // of soft shadows zoomed out read as mud. This rides the LAYER opacity
        // (composite-time) — set instantly per tick, no re-raster.
        let mag = magnification
        let minMag: CGFloat = 0.30, fullMag: CGFloat = 0.55
        let zoomFade = max(0, min(1, (mag - minMag) / (fullMag - minMag)))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shadowLayer.opacity = Float(zoomFade)
        shadowLayer.rasterizationScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.commit()

        // Per-state baked shadow (Figma 88:329 rest vs 88:330/336 lifted): rest is a
        // tight contact shadow; hover/selected lifts into a larger softer pool. These
        // change only on a lift/resize → no per-zoom re-raster.
        let lifted = isLifted
        // The expensive part (shadowPath/radius/offset re-bake) only changes on a
        // lift/resize/rotation. On a plain pan/zoom NONE of those change, so skip
        // it — the cheap zoom-fade `opacity` above already updated. Big pan/zoom win.
        let angleNow = liveRotationOverride ?? n.rotation
        let geomKey = "\(lifted)|\(Int(bounds.width))x\(Int(bounds.height))|\(Int(angleNow * 1000))|\(n.isText)|\(n.isStickyNote)"
        if geomKey == lastShadowGeomKey { return }
        lastShadowGeomKey = geomKey
        let baseOpacity: Float = lifted ? 0.17 : 0.13
        let offsetY: CGFloat   = lifted ? 16 : 6
        let radius: CGFloat    = lifted ? 20 : 8
        let liftS: CGFloat     = lifted ? Self.liftScale : 1.0
        let m = Self.shadowMargin
        let sw = bounds.width * liftS, sh = bounds.height * liftS
        // Card rect inside the enlarged shadowLayer space (origin shifted by +m).
        let shadowRect = CGRect(x: m + (bounds.width - sw) / 2, y: m + (bounds.height - sh) / 2,
                                width: sw, height: sh)
        let shadowR: CGFloat = n.isText ? shadowRect.height / 2
                             : n.isStickyNote ? StickyNodeView.cornerRadius * liftS
                             : shadowCornerRadius
        // Animate ONLY on a rest⇄lifted transition; everything else is instant.
        let animated = (lastLiftedForShadow != nil && lastLiftedForShadow != lifted)
        lastLiftedForShadow = lifted
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.14)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        shadowLayer.frame = bounds.insetBy(dx: -m, dy: -m)
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = baseOpacity         // baked (fade is on .opacity)
        shadowLayer.shadowRadius = radius
        shadowLayer.shadowOffset = CGSize(width: 0, height: offsetY)
        // Bake the card's rotation INTO the silhouette path (rotated about its own
        // centre) — so the shadow matches the rotated card and stays put. No layer
        // transform (which kept sliding it). `liveRotationOverride` makes it track
        // the live handle drag.
        let basePath = CGPath(roundedRect: shadowRect,
                              cornerWidth: shadowR, cornerHeight: shadowR, transform: nil)
        let angle = liveRotationOverride ?? n.rotation
        if angle != 0 {
            let cx = shadowRect.midX, cy = shadowRect.midY
            var t = CGAffineTransform(translationX: cx, y: cy)
                .rotated(by: angle).translatedBy(x: -cx, y: -cy)
            shadowLayer.shadowPath = basePath.copy(using: &t) ?? basePath
        } else {
            shadowLayer.shadowPath = basePath
        }
        CATransaction.commit()
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
    /// The node id whose content is currently installed (for the idempotent skip).
    private var currentContentID: UUID?

    func setContent(node: CanvasNode, swiftUI: @autoclosure () -> AnyView,
                    isEditing: Bool = false) {
        let native = isEditing ? nil : makeNativeCardContent(for: node)
        // IDEMPOTENT: if the SAME cached native view is already installed (the most
        // common case is the video view for an unchanged node on a drag-release /
        // bring-to-front `reloadData`), leave it untouched. Re-parenting the
        // AVPlayer-backed view (removeFromSuperview → addSubview) flashes its
        // AVPlayerLayer black for a frame — THE video blink. Skipping it = stable.
        if let native, native === nativeContent {
            cardView.usesNativeContent = true
            currentContentID = node.id
            return
        }
        // We ARE swapping content now — park the outgoing video so its AVPlayer is
        // reclaimed (not rebuilt) if it reappears, else torn down ~1.2s later.
        if FeatureFlags.useWebViewCache,
           let vid = nativeContent as? CardVideoContentView, let id = vid.cacheNodeID {
            NativeVideoCache.shared.park(id)
        }
        currentContentID = node.id
        // A text node in edit mode falls back to the SwiftUI inline editor
        // (auto-sizing field + focus); every other case prefers native content.
        if let native {
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
