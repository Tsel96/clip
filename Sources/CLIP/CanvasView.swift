import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CanvasView: View {
    @EnvironmentObject var state: CanvasState
    @EnvironmentObject var cameraStore: CameraStore
    @Environment(\.clipTheme) private var theme
    @State private var isDropTargeted = false
    /// One-shot guard so we only restore `lastViewMode` once per launch,
    /// after the GeometryReader has measured the actual viewport.
    @State private var didRestoreLastViewMode = false
    /// NSEvent monitor for Archive's keyboard nav (Esc + arrow keys).
    /// Installed on appear, torn down on disappear so it doesn't leak.
    @State private var archiveKeyMonitor: Any? = nil
    /// Cursor position over the canvas (hover or drag), driving the
    /// Stitch-style grid spotlight. `nil` when the pointer is off-canvas.
    @State private var pointerLocation: CGPoint? = nil

    // MARK: - Colorform zoom-driven crossfade
    //
    // At z ≤ 0.30  → bulbs fully visible, cards fully transparent
    // At z ≥ 0.55  → bulbs fully transparent, cards fully visible
    // Between is a smooth cubic crossfade with cards also blurring out
    // as the bulbs come in — the "satisfying" continuous transition.

    /// The non-section nodes that should render in the current mode.
    /// - In Archive's Day level we show only that day's cards (looked
    ///   up via the cached `archiveDays` index).
    /// - In Archive's Card level we show only the focused card —
    ///   resolved via the O(1) `nodeByID` index, not a linear filter.
    /// - Everywhere else: every non-section node.
    private var bentoVisibleNodes: [CanvasNode] {
        // Hide every non-head member of a card-stack (⌘G group). The head
        // node draws the deck visual on the canvas; the hidden members
        // still live in `nodes` (so undo + Codable + drag-translation
        // continue to work) but are skipped here so they don't visually
        // pile on top of one another at the stack's anchor.
        let visibleStackMember: (CanvasNode) -> Bool = { node in
            !state.isHiddenByStack(node.id)
        }
        guard state.canvasMode == .archive else {
            return state.nodes.filter { !$0.isSection && visibleStackMember($0) }
        }
        switch state.archiveLevel {
        case .calendar:
            return []
        case .day(let date):
            let ids = Set(state.archiveDays[date] ?? [])
            return state.nodes.filter { ids.contains($0.id) && visibleStackMember($0) }
        case .card(let id):
            return state.nodeByID[id].map { [$0] } ?? []
        }
    }

    /// Per-mode background tint. Colorform keeps the warm cream tied to
    /// its bulb constellation; Archive uses a deeper warm cream for the
    /// calendar level and shifts to near-black at the lightbox level;
    /// Canvas uses the system window background.
    private var backgroundColor: Color {
        switch state.canvasMode {
        case .colorform: return Color(red: 0.985, green: 0.965, blue: 0.945)
        case .archive:   return Color(red: 0.965, green: 0.955, blue: 0.940)
        case .canvas:    return theme.canvas
        }
    }

    /// On first non-zero viewport measurement, restore the exact mode
    /// the user was in at quit (saved as `pendingRestoredMode`). Modes
    /// that re-layout based on viewport size (Archive) need a
    /// real size, hence the gate on `currentSize.width > 0`. Colorform
    /// is honoured too — it re-enters via its async `enterColorform`.
    private func restoreLastViewModeIfNeeded(currentSize: CGSize) {
        guard !didRestoreLastViewMode,
              currentSize.width > 0,
              state.canvasMode == .canvas,
              let mode = state.pendingRestoredMode,
              mode != .canvas else {
            // Even if there's nothing to restore, mark the one-shot
            // guard so a viewport resize doesn't keep retrying.
            if currentSize.width > 0 { didRestoreLastViewMode = true }
            return
        }
        didRestoreLastViewMode = true
        state.pendingRestoredMode = nil
        state.setMode(mode)
    }

    // MARK: - Archive key monitor

    /// Install a local NSEvent monitor that handles Archive-specific
    /// keys (Esc to pop a level, ← → ↑ ↓ to navigate Lightbox) AND a
    /// canvas-mode Esc panic-button that drops any stuck Smart Selection
    /// chrome state. Skipped when a text editor has focus (per audit
    /// A6: Esc should commit the edit first, not pop the level).
    private func installArchiveKeyMonitor() {
        guard archiveKeyMonitor == nil else { return }
        archiveKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // If an editable text field has focus, let it have the key —
            // never steal Esc / arrows from an active text editor.
            if NSApp.keyWindow?.firstResponder is NSText { return event }

            // Inline video trim takes top key priority: Esc cancels it.
            if state.trimmingCardID != nil, event.keyCode == 53 {
                state.trimmingCardID = nil
                return nil
            }

            // Card lightbox takes key priority: Esc closes, ← → navigate.
            if state.lightboxCardID != nil {
                switch event.keyCode {
                case 53:  state.closeLightbox();   return nil
                case 123: state.lightboxStep(-1);  return nil
                case 124: state.lightboxStep(1);   return nil
                default:  return event
                }
            }

            // Unfolded folder Esc: close it first (re-fold) before any other
            // Esc semantics — same panic-out priority as stack focus.
            if event.keyCode == 53,
               state.canvasMode == .canvas,
               state.focusedFolderID != nil {
                state.exitFolderFocus()
                return nil
            }

            // Stack focus mode Esc: exit focus first so the user can
            // panic out of the deep modal without other Esc semantics
            // interfering. Falls through to the Smart Selection
            // panic-clear only when there's no active focus.
            if event.keyCode == 53,
               state.canvasMode == .canvas,
               state.focusedStackID != nil {
                state.exitStackFocus()
                return nil
            }

            // Canvas-mode Esc: clear any in-flight Smart Selection
            // interaction (marks, reorder drag, gutter drag, marquee).
            // Acts as a panic button if a gesture got interrupted.
            if event.keyCode == 53, state.canvasMode == .canvas {
                let didAnything =
                    !state.smartSelection.markedIDs.isEmpty ||
                    state.smartSelection.reorderDrag != nil ||
                    state.smartSelection.gutterDrag != nil ||
                    state.rubberBandScreenRect != nil
                state.smartSelection.cancelAllDrags()
                state.smartSelection.clearMarks()
                state.rubberBandScreenRect = nil
                // Swallow Esc only if we actually did something — otherwise
                // let it propagate (so menu close / app cancel still fires).
                return didAnything ? nil : event
            }

            // Everything else is Archive-specific.
            guard state.canvasMode == .archive else { return event }

            switch event.keyCode {
            case 53:      // Escape
                state.popArchiveLevel()
                return nil
            case 123:     // Left arrow
                if case .card = state.archiveLevel {
                    state.lightboxNavigate(.previousCard)
                    return nil
                }
                return event
            case 124:     // Right arrow
                if case .card = state.archiveLevel {
                    state.lightboxNavigate(.nextCard)
                    return nil
                }
                return event
            case 125:     // Down arrow
                if case .card = state.archiveLevel {
                    state.lightboxNavigate(.nextDay)
                    return nil
                }
                return event
            case 126:     // Up arrow
                if case .card = state.archiveLevel {
                    state.lightboxNavigate(.previousDay)
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private func removeArchiveKeyMonitor() {
        if let m = archiveKeyMonitor {
            NSEvent.removeMonitor(m)
            archiveKeyMonitor = nil
        }
    }

    private var bulbsOpacity: Double {
        guard state.canvasMode == .colorform else { return 0 }
        let z = cameraStore.camera.zoom
        let t = max(0, min(1, (0.55 - z) / 0.25))
        return Double(3 * t * t - 2 * t * t * t)   // smoothstep
    }
    private var cardsOpacity: Double {
        state.canvasMode == .colorform ? 1 - bulbsOpacity : 1
    }
    private var cardsBlur: CGFloat {
        state.canvasMode == .colorform ? 14 * CGFloat(bulbsOpacity) : 0
    }

    /// Phase 1 — route the node layer through the native `NSScrollView` canvas
    /// core. Off by default; flip on to test the new pan/zoom.
    /// First-pass issues to fix before re-enabling: (1) coordinate sync — cards
    /// land offset from the camera-derived overlays; (2) card drag math (÷zoom +
    /// `.global`) is wrong inside a magnified scroll view; (3) pan/zoom feel.
    /// Now points at the NSCollectionView core (milestone 1 = placeholder cards).
    /// Native canvas rewrite (Spatial-style NSScrollView + NSCollectionView).
    /// Zoom-anchor coordinate bug fixed (document-view coords). Placeholder
    /// boxes for now — validating pan/zoom smoothness before card hosting.
    private let useNativeCanvas = true

    /// Native shell collapse (A5): host the canvas-core SCREEN-space overlays
    /// (dot-grid, tool-input, smart-selection, alignment/spacing guides) as two
    /// passthrough islands INSIDE the native `CLIPCanvasView` instead of as
    /// SwiftUI ZStack siblings — so the canvas is one native view with one input
    /// owner. Flip to `false` to fall back to the proven ZStack shell (kept
    /// intact below as the `!useNativeShell` branches).
    /// Re-enabled for the debug-together: the palette rework fixes tool-mode
    /// switching (the cursor button reliably returns to select) and the
    /// ToolInputLayer coordinate space is declared on the island. Flip to
    /// `false` for the proven ZStack shell if select/tools misbehave.
    private let useNativeShell = true

    /// Phase B: draw connectors as native CAShapeLayers in the scrolled
    /// container (off → the proven SwiftUI ConnectorsLayer renders them). ENABLED
    /// for the all-phases push: content-space frames match the cards, the layer
    /// rides the scroll magnification, and drags track live via `liveReposition`.
    /// The SwiftUI overlay is left empty when this is true (no double-render).
    private let useNativeConnectors = true

    /// Live cursor for the native-shell dot-grid spotlight. The behind-island
    /// observes this; `CanvasView.body` does NOT, so pointer moves re-render the
    /// grid in isolation instead of churning the whole body.
    @StateObject private var pointerStore = CanvasPointerStore()

    /// World extent for the native scroll view: all content plus a generous
    /// margin so you can pan well past the edges.
    // Grows-only canvas extent (see CanvasState.stableWorldBounds) — a
    // content-following box shifted with a select-all drag, making the move
    // invisible; this stays put so the cards actually move on screen.
    private var worldBounds: CGRect { state.stableWorldBounds() }

    /// Content-coordinate camera for the native canvas's world-space overlay
    /// (connectors): maps world → (world − worldBounds.origin) so the overlay
    /// lines up with the collection's item frames. Kept in sync by
    /// `syncOverlayCamera()`.
    @StateObject private var overlayCamera = CameraStore()

    /// A deliberately frozen camera injected into the native collection cards so
    /// the live camera sync (which feeds the minimap) never re-renders them —
    /// the layout positions them and they're always-live, so they need no camera.
    @StateObject private var cardCamera = CameraStore()

    private func syncOverlayCamera() {
        overlayCamera.camera = Camera(x: -worldBounds.minX, y: -worldBounds.minY, zoom: 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Background dot grid (toggleable). Hidden in Archive
                // because its calendar / bento layers paint their own
                // surface.
                if !useNativeShell, state.showGrid, state.canvasMode != .archive {
                    // No `.ignoresSafeArea()` — the grid must share the
                    // exact coordinate space the pointer is reported in
                    // (the canvas view's safe-area-respecting bounds), or
                    // the spotlight draws offset from the real cursor.
                    // (Native shell: moved into CLIPCanvasView's behind-island.)
                    DotGrid(camera: cameraStore.camera, pointer: pointerLocation)
                        .allowsHitTesting(false)
                }

                // Empty-state hint. (Native shell: in the behind-island.)
                if !useNativeShell, state.nodes.isEmpty {
                    EmptyStateView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }

                // Drawing / text input layer (active when not in select mode).
                // Sits BEHIND nodes so nodes still get hover/click in select mode.
                // Only rendered in Canvas mode — Colorform and Archive
                // are all read-only views. Suppressed in stack focus
                // mode so the focus backdrop receives clicks cleanly.
                if !useNativeShell, state.canvasMode == .canvas, state.focusedStackID == nil {
                    ToolInputLayer()
                }

                // Archive — a chronological list of everything added,
                // newest first, grouped by day with per-row timestamps.
                // The node group is hidden entirely in this mode (gate
                // below); rows jump back to the card on the canvas.
                if state.canvasMode == .archive {
                    ArchiveListView()
                        .transition(.opacity)
                }

                // Colorform bulbs — big blurred color clouds, only in
                // Colorform mode. Painted BELOW the cards so the cards
                // sit on top until the zoom-driven crossfade fades them.
                if state.canvasMode == .colorform {
                    ColorformLayer()
                        .opacity(bulbsOpacity)
                }

                // Stack focus mode backdrop — mounted right before the
                // node group so the focused cards paint ON TOP of it
                // (the chrome — count pill + exit chip — mounts later in
                // this same ZStack so it sits on top of the focused cards
                // for the count display + close affordance).
                if state.canvasMode == .canvas, state.focusedStackID != nil {
                    StackFocusLayer(layer: .backdrop)
                }

                // Nodes themselves. In Colorform they crossfade as zoom
                // drops, revealing the bulbs beneath. Hidden entirely in
                // Archive (the list paints its own layer).
                //
                // Camera scale + pan is applied ONCE on the parent — pan
                // ticks only re-evaluate this one transform regardless of
                // how many cards live on the page. (Maps to the thesis's
                // "apply scale changes directly to the whole graphics
                // context.")
                if state.canvasMode != .archive {
                    if useNativeCanvas {
                        // Phase 1 — native NSScrollView core (zoom = magnification,
                        // pan = scrolling). Only the node layer moves in; the
                        // overlays below stay screen-space and track the camera
                        // we sync back out.
                        CollectionCanvas(config: CanvasConfig(
                            worldBounds: worldBounds,
                            nodes: state.canvasDisplayNodes,
                            camera: cameraStore.camera,
                            minZoom: 0.05, maxZoom: 8,
                            onCameraChange: { cameraStore.camera = $0 },
                            content: { node in
                                // Each collection item hosts a real card. It's a
                                // separate NSHostingView, so re-inject the env
                                // objects the card tree needs. CanvasInputView sits
                                // ABOVE the cards and owns every click, so hosted
                                // content stays renderable but never gets events —
                                // except a text node being edited, which the input
                                // view passes through to (see `editingTextNodeID`).
                                AnyView(
                                    DraggableNode(node: node, positioned: false)
                                        .environmentObject(state)
                                        .environmentObject(cardCamera)
                                        .environmentObject(state.smartSelection)
                                )
                            },
                            // World-space connectors, drawn inside the scrolled
                            // content so they pan/zoom with the cards. No camera
                            // here — CollectionCanvas supplies the content-coord one.
                            overlay: AnyView(
                                // Native mode: committed lines drawn natively; this
                                // overlay keeps ONLY the live connect-drag preview.
                                ConnectorsLayer(committedHidden: useNativeConnectors)
                                    .frame(width: worldBounds.width,
                                           height: worldBounds.height,
                                           alignment: .topLeading)
                                    .environmentObject(state)
                                    .environmentObject(state.smartSelection)
                                    .environmentObject(overlayCamera)
                            ),
                            // Screen-space islands (native shell): dot-grid +
                            // empty-state BEHIND the cards; tool-input + smart-
                            // selection + alignment/spacing guides ABOVE.
                            behindOverlay: useNativeShell ? AnyView(
                                CanvasBehindOverlays()
                                    .environmentObject(state)
                                    .environmentObject(cameraStore)
                                    .environmentObject(pointerStore)
                            ) : nil,
                            aboveOverlay: useNativeShell ? AnyView(
                                CanvasAboveOverlays()
                                    .environmentObject(state)
                                    .environmentObject(cameraStore)
                                    .environmentObject(state.smartSelection)
                            ) : nil,
                            isSelectMode: { state.toolMode == .select },
                            isDrawMode: { state.toolMode == .draw },
                            drawColor: {
                                let c = state.drawColor
                                return NSColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green),
                                               blue: CGFloat(c.blue), alpha: 1)
                            },
                            drawWidth: { state.drawWidth },
                            onCommitStroke: { world in state.commitStroke(worldPoints: world) },
                            connectors: state.connectors,
                            useNativeConnectors: useNativeConnectors,
                            onSelectConnector: { state.selectConnector($0) },
                            selectedConnectorIDs: state.selectedConnectorIDs,
                            onBackgroundClick: {
                                if state.toolMode == .select { state.deselectAll() }
                            },
                            selectedNodeID: state.selectedNodeIDs.count == 1
                                ? state.selectedNodeIDs.first : nil,
                            selectedNodeIDs: state.selectedNodeIDs,
                            editingTextNodeID: state.editingTextNodeID,
                            liveSelection: { state.selectedNodeIDs },
                            onInteractionBegan: { primary in
                                state.activeResizeUndoSnapshot = state.snapshotForUndo()
                                if let primary { state.beginDrag(of: primary) }   // connector tug
                            },
                            onInteractionEnded: {
                                state.endDrag()
                                if let snap = state.activeResizeUndoSnapshot {
                                    state.commitUndoable(from: snap)
                                }
                                state.activeResizeUndoSnapshot = nil
                            },
                            onMoveCommitted: { state.handleDropOntoFolder(draggedIDs: $0) },
                            onMove: { id, position in
                                // Move (not resize) so connectors stay attached.
                                state.updatePosition(of: id, to: position)
                            },
                            onResize: { id, frame in
                                state.resize(id: id, frame: frame)
                            },
                            onActivate: { id in
                                guard state.toolMode == .select else { return }
                                if let node = state.nodes.first(where: { $0.id == id }) {
                                    if case .text = node.kind {
                                        // Native text card: setting editingTextNodeID
                                        // swaps the item to the SwiftUI inline editor
                                        // (HostingCollectionItem.setContent); pendingFocus
                                        // makes that editor grab focus on appear.
                                        state.select(id)
                                        state.editingTextNodeID = id
                                        state.pendingFocusNodeID = id
                                    } else if state.isStackHead(id), state.focusedStackID == nil {
                                        state.enterStackFocus(headID: id)
                                    } else if case .folder = node.kind {
                                        state.enterFolderFocus(folderID: id)
                                    } else if state.canvasMode == .canvas, !node.isSection {
                                        state.openLightbox(id)
                                    }
                                }
                            },
                            onMarquee: { contentRect, additive in
                                // Content → world, then select every node the box touches.
                                let world = contentRect.offsetBy(dx: worldBounds.minX,
                                                                 dy: worldBounds.minY)
                                let hits = Set(state.nodes.filter { n in
                                    world.intersects(CGRect(x: n.position.x, y: n.position.y,
                                                            width: n.width, height: n.height ?? 120))
                                }.map(\.id))
                                state.selectNodes(additive ? state.selectedNodeIDs.union(hits) : hits)
                            },
                            onSelect: { id, shift in
                                guard state.toolMode == .select else { return }
                                if shift { state.toggleNodeSelection(id) }
                                else { state.select(id) }
                            },
                            onRecolorNode: { id, nsColor in
                                // Radial picker → nearest section preset (model
                                // stores presets, not arbitrary RGB).
                                if let node = state.nodes.first(where: { $0.id == id }), node.isSection {
                                    state.setSectionColor(id: id,
                                        to: RadialColorPicker.nearestSectionColor(to: nsColor))
                                }
                            }
                        ))
                        .onAppear {
                            syncOverlayCamera()
                            // Native cards are always-live + layout-positioned, so
                            // a zoom must not re-render them (the gesture-boundary
                            // blink). Minimap/readout still update via cameraStore.
                            state.suppressZoomEpoch = true
                        }
                        .onChange(of: worldBounds) { _ in syncOverlayCamera() }
                        .opacity(cardsOpacity)
                        .blur(radius: cardsBlur)
                        .allowsHitTesting(state.toolMode == .select && state.canvasMode != .colorform)
                    }
                }

                // Figma-style Smart Selection chrome — pink center rings +
                // gutter handles + tooltip + insertion indicator. Sits
                // above connectors so it can intercept clicks on rings and
                // handles cleanly. Auto-detects 1D rows / columns / 2D
                // grids in the current selection.
                // Suppressed in stack focus mode — the focus chrome owns
                // the screen and Smart Selection wouldn't apply anyway.
                if !useNativeShell, state.canvasMode == .canvas, state.focusedStackID == nil {
                    // On the native canvas, gate Smart Selection's ring/gutter
                    // gestures OFF — they're competing pointer handlers that would
                    // re-enter the very race CanvasInputView exists to remove.
                    // Re-introduce via the native controller later (task #15).
                    // (Native shell: in the above-island, non-interactive.)
                    SmartSelectionLayer()
                        .allowsHitTesting(!useNativeCanvas)
                }

                // Stack focus chrome — count pill + exit chip — sits
                // ABOVE the nodes so it's always reachable. The matching
                // backdrop (behind the nodes) is mounted further up in
                // the ZStack, just before the node group itself.
                if state.canvasMode == .canvas, state.focusedStackID != nil {
                    StackFocusLayer(layer: .chrome)
                }

                // Live alignment guides (red lines while dragging). Only
                // relevant during a drag, which only happens in canvas mode.
                // (Native shell: in the above-island, non-interactive.)
                if !useNativeShell, state.canvasMode == .canvas {
                    AlignmentGuidesOverlay()
                        .allowsHitTesting(false)
                    SpacingIndicatorsOverlay()
                        .allowsHitTesting(false)
                }

                // Trackpad scroll & pinch capture. Archive owns its own
                // navigation (calendar ScrollView, breadcrumb pop) so we
                // keep the global camera neutral there.
                if state.canvasMode != .archive {
                    CanvasEventMonitor(
                        onScroll: { dx, dy, modifiers, location in
                            // Details mode (lightbox open) freezes the canvas —
                            // swallow pan/zoom so the background never moves
                            // behind the hero.
                            guard state.lightboxCardID == nil else { return }
                            if modifiers.contains(.command) {
                                // Pinching mid-inertia should stop the
                                // coast immediately — feels weird if
                                // the camera keeps drifting while you
                                // try to zoom in.
                                state.cancelPanInertia()
                                state.zoom(by: 1 + dy * 0.01, around: location)
                            } else {
                                state.panWithInertia(deltaX: dx, deltaY: dy)
                            }
                        },
                        onMagnify: { delta, location in
                            // Frozen while details mode (lightbox) is open.
                            guard state.lightboxCardID == nil else { return }
                            state.cancelPanInertia()
                            state.zoom(by: 1 + delta, around: location)
                        },
                        onBackgroundClick: {
                            if state.toolMode == .select { state.deselectAll() }
                        },
                        onPointerMove: { p in
                            // Native shell feeds the behind-island's spotlight via
                            // the store (no body churn); legacy uses @State.
                            if useNativeShell { pointerStore.location = p }
                            else { pointerLocation = p }
                        },
                        // Native canvas owns pan/zoom — don't consume scroll/magnify.
                        capturesScrollMagnify: !useNativeCanvas
                    )
                    .zIndex(-1)
                }
            }
            .background(backgroundColor)
            // Pre-decode every video's first-frame poster as nodes load, so the
            // during-zoom poster cover (VideoNodeView) always has a real frame
            // instead of falling back to black on a cold cache — the "videos go
            // black while zooming" symptom. Re-runs when the node set changes.
            .task(id: state.nodes.count) {
                let urls = state.nodes.compactMap { node -> URL? in
                    if case .video(let url, _) = node.kind { return url }
                    return nil
                }
                VideoPosterStore.warm(urls)
            }
            // Publish this container's window-global frame so the lightbox can
            // map a node's camera-local position to its real on-screen rect
            // (the camera offset is relative to this ZStack). Plain write — not
            // observed — so it never triggers re-renders.
            .background(
                GeometryReader { proxy in
                    let f = proxy.frame(in: .global)
                    Color.clear
                        .onAppear { state.canvasViewFrame = f }
                        .onChange(of: f) { state.canvasViewFrame = $0 }
                }
            )
            .clipped()
            .coordinateSpace(name: CanvasCoords.name)
            // Empty state for the pinned iPhone inbox page: before any link
            // has been shared from the phone, invite the user to set it up.
            .overlay {
                if state.canvasMode == .canvas, state.isInboxEmpty,
                   state.lightboxCardID == nil, state.trimmingCardID == nil {
                    InboxEmptyState()
                }
            }
            // Figma-style "drop something here" highlight while dragging
            // a file or URL over the canvas.
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor.opacity(0.06))
                        )
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                state.viewportSize = geo.size
                restoreLastViewModeIfNeeded(currentSize: geo.size)
                installArchiveKeyMonitor()
            }
            .onDisappear {
                removeArchiveKeyMonitor()
            }
            .onChange(of: geo.size) { newSize in
                state.viewportSize = newSize
                restoreLastViewModeIfNeeded(currentSize: newSize)
            }
            .onDrop(
                of: CanvasDrop.supportedTypes,
                isTargeted: $isDropTargeted
            ) { providers, location in
                let world = state.screenToWorld(point: location)
                return CanvasDrop.handle(providers: providers, at: world, state: state)
            }
        }
        // Bottom-left zoom pill + bottom-right toggle pill. Applied
        // OUTSIDE the GeometryReader closure so SwiftUI positions them
        // against the actual window bounds — not the inner ZStack's
        // potentially-extended frame. This is what makes them stay
        // visible when the user resizes the window (in any direction).
        // Bottom-LEFT: connectors / grid / play toggles (Figma 51:12692).
        .overlay(alignment: .bottomLeading) {
            if state.canvasMode != .archive {
                NativeCanvasTogglesPill()
                    .fixedSize()
                    .padding(.leading, 18)
                    .padding(.bottom, 18)
            }
        }
        // Unfolded-folder back chip (top-centre): re-fold to the main canvas.
        // Esc does the same; this is the discoverable affordance.
        .overlay(alignment: .top) {
            if state.canvasMode == .canvas, let fid = state.focusedFolderID,
               case .folder(let title, _, _)? = state.nodeByID[fid]?.kind {
                Button { state.exitFolderFocus() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text(title.isEmpty ? "Untitled" : title).lineLimit(1)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
        }
        // Liquid-glass minimap dome — anchored to the bottom-right corner
        // with most of the circle bleeding off-screen, so its top-left
        // quadrant sweeps across the viewport. Mounted here (window
        // bounds) for the same reason as the pills — the inner ZStack's
        // frame can extend past the window. Hidden while the floating-
        // window minimap is being shown.
        .overlay(alignment: .bottomTrailing) {
            if state.canvasMode != .archive, !state.isMinimapDetached {
                LiquidGlassMinimap()
                    .ignoresSafeArea()
            }
        }
        // Bottom-RIGHT: zoom −/NN%/+ pill (Figma 51:12692).
        .overlay(alignment: .bottomTrailing) {
            if state.canvasMode != .archive {
                NativeZoomControlsPill()
                    .fixedSize()
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
            }
        }
        // Click-catcher: while the link input is open, a tap anywhere ELSE on the
        // canvas dismisses it. Sits BELOW the palette + input overlays (added
        // first), so the "+" and the field stay interactive — only outside
        // clicks are caught.
        .overlay {
            if state.canvasMode == .canvas, state.isLinkInputPresented {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Motion.pop) { state.isLinkInputPresented = false }
                    }
            }
        }
        // Bottom-CENTER: the Spatial-style yellow tool palette + "+" (Figma 51:12692).
        .overlay(alignment: .bottom) {
            if state.canvasMode == .canvas {
                NativeCanvasToolPalette(state: state)
                    .frame(width: CanvasToolPaletteView.totalW,
                           height: CanvasToolPaletteView.totalH)
                    // Pill sits exactly 18 pt off the viewport bottom (user spec):
                    // frame bottom flush with the viewport + the 18 pt shadow-bleed
                    // IS that gap.
                    .padding(.bottom, 0)
            }
        }
        // Inline "Insert link here" field (Figma 72:36784) — floats above the
        // toolbar, centered on the round "+" (240 pt right of the toolbar's
        // center: 542/2 − 31). Its own overlay so the palette's fixed frame
        // can't clip it. Scales up FROM ITS BOTTOM-CENTER — i.e. out of the "+"
        // directly below it (was `.bottomTrailing`, which read as "from the left").
        .overlay(alignment: .bottom) {
            if state.canvasMode == .canvas, state.isLinkInputPresented {
                LinkInputBar()
                    // Transition must be applied BEFORE the offset: otherwise the
                    // scale anchors to the panel's un-offset layout frame (canvas
                    // center, ~240pt left of the "+"), so it grows from the left
                    // and slides right. Inside the offset, the pivot moves with
                    // the panel — it scales up out of the "+" directly below it.
                    .transition(.scale(scale: 0.6, anchor: .bottom)
                        .combined(with: .opacity))
                    .offset(x: 240, y: -92)
            }
        }
        // Acute tool-mode visibility — while a non-Select tool is active,
        // a chip at the top of the canvas says WHY clicks now draw/place/
        // connect, and offers the way back (click or V).
        .overlay(alignment: .top) {
            Group {
                if state.canvasMode == .canvas, state.toolMode != .select {
                    NativeActiveToolChip()
                        .fixedSize()
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85),
                       value: state.toolMode)
        }
        // Transient share toast — slides in from the top when a link
        // arrives from the iPhone; tap to jump to the Incoming page.
        .overlay(alignment: .top) {
            if let toast = state.toast {
                ToastView(toast: toast) { state.goToIncomingPage() }
                    .padding(.top, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Coordinate space

enum CanvasCoords {
    static let name: String = "canvas"
}

// MARK: - Empty state

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No tweets yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Press ⌘V to paste an X.com link, or use the + button in the toolbar.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

// MARK: - Native-shell screen-space islands

/// The BEHIND-the-cards island (native shell): dot-grid spotlight + empty-state.
/// Hosted once inside `CLIPCanvasView` (below the scroll) and click-transparent.
/// Observes the stores directly, so a camera/pointer change re-renders only this
/// island — never `CanvasView.body`.
struct CanvasBehindOverlays: View {
    @EnvironmentObject var state: CanvasState
    @EnvironmentObject var cameraStore: CameraStore
    @EnvironmentObject var pointerStore: CanvasPointerStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.showGrid, state.canvasMode != .archive {
                DotGrid(camera: cameraStore.camera, pointer: pointerStore.location)
                    .allowsHitTesting(false)
            }
            if state.nodes.isEmpty {
                EmptyStateView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The ABOVE-the-cards island (native shell): tool-input + smart-selection +
/// alignment/spacing guides. `ToolInputLayer` is interactive in a tool mode;
/// the rest are non-interactive. Hosted in a `ToolOverlayHostingView` (above the
/// scroll) that passes clicks through to `CanvasInputView` in select mode.
struct CanvasAboveOverlays: View {
    @EnvironmentObject var state: CanvasState
    @EnvironmentObject var cameraStore: CameraStore
    @EnvironmentObject var smartSelection: SmartSelectionController

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.canvasMode == .canvas, state.focusedStackID == nil {
                ToolInputLayer()
                SmartSelectionLayer()
                    .allowsHitTesting(false)
            }
            if state.canvasMode == .canvas {
                AlignmentGuidesOverlay()
                    .allowsHitTesting(false)
                SpacingIndicatorsOverlay()
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ToolInputLayer / SmartSelection gestures read locations in the
        // `CanvasCoords.name` space (which `state.screenToWorld` expects). That
        // space is declared on CanvasView's GeometryReader, which this island's
        // separate NSHostingView does NOT inherit — so re-declare it here at the
        // island's bounds (= the canvas area), or every tool gets bad coords.
        .coordinateSpace(name: CanvasCoords.name)
    }
}

// MARK: - Dot grid

/// Stitch-style spotlight dot grid. The grid is invisible across the
/// canvas and reveals only as a soft pool of dots around the cursor; the
/// pool fades out when the pointer leaves. Spacing scales 1:1 with zoom
/// so the grid reads as part of the zoomable space (unlike the old
/// always-on, octave-locked grid).
///
/// Kept cheap:
///   1. **Spotlight-clipped.** Only dots inside `spotlightRadius` of the
///      cursor are ever generated — the dot count is bounded at any
///      zoom, however far the user zooms out.
///   2. **Octave-doubled floor.** Spacing scales freely with zoom, but
///      doubles if it would fall below `minScreenSpacing` (~6 pt) — a
///      pure safety floor for extreme zoom-out; never triggers in the
///      normal 25–400 % range.
///   3. **Single batched `Path` + one radial-gradient `fill`.** The
///      gradient itself does the distance falloff — no per-dot work.
struct DotGrid: View {
    var camera: Camera
    /// Cursor position in canvas-view coordinates, or `nil` when the
    /// pointer is off the canvas.
    var pointer: CGPoint?

    private static let baseSpacing: CGFloat = 24
    private static let baseDot: CGFloat = 2.4
    /// Reveal radius around the cursor, in screen points.
    private static let spotlightRadius: CGFloat = 220
    /// Screen spacing never drops below this (octave-doubled if it would) —
    /// bounds the dot count for the now full-screen grid at extreme zoom-out.
    private static let minScreenSpacing: CGFloat = 12

    /// 0…1 reveal, animated up when the pointer enters the canvas and
    /// down when it leaves so the pool fades rather than popping.
    @State private var strength: Double = 0
    /// Last known cursor position — the pool fades out here after the
    /// pointer has already left (`pointer` is `nil` by then).
    @State private var lastPointer: CGPoint = .zero

    var body: some View {
        Canvas { context, size in
            // Spacing scales with zoom; octave-double only as a floor.
            var spacing = Self.baseSpacing * camera.zoom
            while spacing < Self.minScreenSpacing { spacing *= 2 }
            let dotSize = max(1, Self.baseDot * camera.zoom)

            // World-anchored phase: dots sit on world multiples of
            // `baseSpacing`, so they track the camera exactly.
            var phaseX = camera.x.truncatingRemainder(dividingBy: spacing)
            if phaseX > 0 { phaseX -= spacing }
            var phaseY = camera.y.truncatingRemainder(dividingBy: spacing)
            if phaseY > 0 { phaseY -= spacing }

            // Full-screen, world-anchored dot field (whole background, not just
            // a cursor patch).
            var path = Path()
            var x = phaseX
            while x <= size.width {
                var y = phaseY
                while y <= size.height {
                    path.addEllipse(in: CGRect(x: x - dotSize / 2, y: y - dotSize / 2,
                                               width: dotSize, height: dotSize))
                    y += spacing
                }
                x += spacing
            }

            // Persistent background grid — always visible, even with the cursor
            // off the canvas.
            context.fill(path, with: .color(Color.primary.opacity(0.22)))

            // Cursor spotlight — brightens the dots near the pointer (the nice
            // Spatial-style reveal), layered ON TOP of the base grid.
            if strength > 0.001 {
                let center = pointer ?? lastPointer
                context.fill(path, with: .radialGradient(
                    Gradient(colors: [
                        Color.primary.opacity(0.32 * strength),
                        Color.primary.opacity(0.14 * strength),
                        .clear
                    ]),
                    center: center, startRadius: 0, endRadius: Self.spotlightRadius))
            }
        }
        // Fade the pool in/out only on enter/leave transitions.
        .onChange(of: pointer == nil) { gone in
            withAnimation(.easeOut(duration: gone ? 0.4 : 0.18)) {
                strength = gone ? 0 : 1
            }
        }
        // Remember where to keep drawing while the pool fades out.
        .onChange(of: pointer) { p in
            if let p { lastPointer = p }
        }
    }
}

// MARK: - Alignment guides

/// Renders the live alignment guides reported by `AlignmentEngine`. Draws
/// in screen space (so the line stays 1pt regardless of zoom), converting
/// each guide's world position through the active camera.
struct AlignmentGuidesOverlay: View {
    @EnvironmentObject var state: CanvasState
    @EnvironmentObject var cameraStore: CameraStore

    var body: some View {
        Canvas { ctx, _ in
            guard !state.activeAlignmentGuides.isEmpty else { return }
            let cam = cameraStore.camera
            for g in state.activeAlignmentGuides {
                var path = Path()
                switch g.axis {
                case .vertical:
                    let x = g.position * cam.zoom + cam.x
                    let y0 = g.extent.lowerBound * cam.zoom + cam.y
                    let y1 = g.extent.upperBound * cam.zoom + cam.y
                    path.move(to: CGPoint(x: x, y: y0))
                    path.addLine(to: CGPoint(x: x, y: y1))
                case .horizontal:
                    let y = g.position * cam.zoom + cam.y
                    let x0 = g.extent.lowerBound * cam.zoom + cam.x
                    let x1 = g.extent.upperBound * cam.zoom + cam.x
                    path.move(to: CGPoint(x: x0, y: y))
                    path.addLine(to: CGPoint(x: x1, y: y))
                }
                ctx.stroke(
                    path,
                    with: .color(Color(red: 0.95, green: 0.20, blue: 0.32)),
                    lineWidth: 1
                )
            }
        }
    }
}

// MARK: - Spacing indicators

/// Renders the live equal-gap measurements (`SpacingIndicator`) reported
/// by `AlignmentEngine.equalSpacing` while a card is dragged — pink
/// segments with end caps and a pixel-distance badge, Stitch / Figma
/// style. Drawn in screen space so lines stay 1 pt regardless of zoom,
/// converting each world point through the active camera.
struct SpacingIndicatorsOverlay: View {
    @EnvironmentObject var state: CanvasState
    @EnvironmentObject var cameraStore: CameraStore

    private static let pink = Color(red: 0.96, green: 0.24, blue: 0.62)

    var body: some View {
        Canvas { ctx, _ in
            guard !state.activeSpacingIndicators.isEmpty else { return }
            let cam = cameraStore.camera
            for ind in state.activeSpacingIndicators {
                let a = CGPoint(x: ind.from.x * cam.zoom + cam.x,
                                y: ind.from.y * cam.zoom + cam.y)
                let b = CGPoint(x: ind.to.x * cam.zoom + cam.x,
                                y: ind.to.y * cam.zoom + cam.y)

                // The gap segment.
                var line = Path()
                line.move(to: a)
                line.addLine(to: b)
                ctx.stroke(line, with: .color(Self.pink), lineWidth: 1)

                // End caps, perpendicular to the segment.
                let cap: CGFloat = 4
                var caps = Path()
                switch ind.axis {
                case .horizontal:
                    caps.move(to: CGPoint(x: a.x, y: a.y - cap))
                    caps.addLine(to: CGPoint(x: a.x, y: a.y + cap))
                    caps.move(to: CGPoint(x: b.x, y: b.y - cap))
                    caps.addLine(to: CGPoint(x: b.x, y: b.y + cap))
                case .vertical:
                    caps.move(to: CGPoint(x: a.x - cap, y: a.y))
                    caps.addLine(to: CGPoint(x: a.x + cap, y: a.y))
                    caps.move(to: CGPoint(x: b.x - cap, y: b.y))
                    caps.addLine(to: CGPoint(x: b.x + cap, y: b.y))
                }
                ctx.stroke(caps, with: .color(Self.pink), lineWidth: 1)

                // Pixel-distance badge at the midpoint.
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let resolved = ctx.resolve(
                    Text("\(Int(ind.distance.rounded()))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.white)
                )
                let textSize = resolved.measure(in: CGSize(width: 200, height: 60))
                let badge = CGRect(
                    x: mid.x - textSize.width / 2 - 5,
                    y: mid.y - textSize.height / 2 - 2,
                    width: textSize.width + 10,
                    height: textSize.height + 4
                )
                ctx.fill(
                    Path(roundedRect: badge, cornerRadius: 3),
                    with: .color(Self.pink)
                )
                ctx.draw(resolved, at: mid)
            }
        }
    }
}
