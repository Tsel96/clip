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

    /// `bentoVisibleNodes` viewport-culled. In Canvas — the free-roam
    /// editing surface where a large moodboard is panned — only nodes
    /// whose world rect intersects the viewport (inflated by ~½ screen
    /// each side) are mounted, so the live view tree is O(on-screen) not
    /// O(document). Selected nodes are always kept so an in-progress drag
    /// never unmounts its own gesture view. The view modes
    /// (Colorform / Archive) each re-flow with their own animated
    /// layout, so they pass through unculled.
    private var visibleNodes: [CanvasNode] {
        let base = bentoVisibleNodes
        guard state.canvasMode == .canvas else { return base }
        // Stack focus mode: render ONLY the focused stack's members.
        // Every other node is suppressed so the focus grid stands
        // alone over the dimmed backdrop — no random off-screen
        // cards leaking onto the focus surface.
        if let focused = state.focusedStackID {
            return base.filter { $0.groupID == focused }
        }
        let v = state.visibleWorldRect
        let cull = v.insetBy(dx: -v.width / 2, dy: -v.height / 2)
        let kept = state.selectedNodeIDs
        return base.filter { node in
            if kept.contains(node.id) { return true }
            // Use effective (mode-overridden) position + size for the
            // cull rect so cards relocated by Archive / focus
            // grids aren't accidentally pruned even though their layout
            // slot is on-screen.
            let p = state.effectivePosition(of: node)
            let s = state.effectiveSize(of: node)
            let rect = CGRect(x: p.x, y: p.y, width: s.width, height: s.height)
            return cull.intersects(rect)
        }
    }

    /// True when a card projects so small (deep zoom-out) that the full
    /// interactive card is wasted work — render `DraggableNode`'s cheap LOD
    /// proxy instead. Selected cards always stay full so they're manipulable;
    /// only applies on the free canvas (the view modes have their own layout).
    private func isTinyOnScreen(_ node: CanvasNode) -> Bool {
        guard state.canvasMode == .canvas,
              !state.selectedNodeIDs.contains(node.id) else { return false }
        return state.projectedScreenSide(of: node) < CanvasState.lodMinScreenSide
    }

    /// The world-space card layer: sections beneath, then the viewport-culled
    /// nodes (each at full detail or its cheap LOD proxy). Extracted from
    /// `body` so the big canvas expression stays type-checkable.
    @ViewBuilder
    private var nodeLayer: some View {
        // Sections render BELOW everything else so they never occlude their
        // contained cards — except in Archive, where they're hidden.
        if state.canvasMode == .canvas || state.canvasMode == .colorform {
            ForEach(state.nodes.filter(\.isSection)) { node in
                DraggableNode(node: node)
            }
        }
        ForEach(visibleNodes) { node in
            DraggableNode(node: node, isTiny: isTinyOnScreen(node))
        }
    }

    /// Per-mode background tint. Colorform keeps the warm cream tied to
    /// its bulb constellation; Archive uses a deeper warm cream for the
    /// calendar level and shifts to near-black at the lightbox level;
    /// Canvas uses the system window background.
    private var backgroundColor: Color {
        switch state.canvasMode {
        case .colorform: return Color(red: 0.985, green: 0.965, blue: 0.945)
        case .archive:
            switch state.archiveLevel {
            case .calendar:   return Color(red: 0.965, green: 0.955, blue: 0.940)
            case .day:        return Color(red: 0.985, green: 0.985, blue: 0.985)
            case .card:       return Color(red: 0.04, green: 0.05, blue: 0.08)
            }
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

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Background dot grid (toggleable). Hidden in Archive
                // because its calendar / bento layers paint their own
                // surface.
                if state.showGrid && state.canvasMode != .archive {
                    // No `.ignoresSafeArea()` — the grid must share the
                    // exact coordinate space the pointer is reported in
                    // (the canvas view's safe-area-respecting bounds), or
                    // the spotlight draws offset from the real cursor.
                    DotGrid(camera: cameraStore.camera, pointer: pointerLocation)
                        .allowsHitTesting(false)
                }

                // Empty-state hint.
                if state.nodes.isEmpty {
                    EmptyStateView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }

                // Drawing / text input layer (active when not in select mode).
                // Sits BEHIND nodes so nodes still get hover/click in select mode.
                // Only rendered in Canvas mode — Colorform and Archive
                // are all read-only views. Suppressed in stack focus
                // mode so the focus backdrop receives clicks cleanly.
                if state.canvasMode == .canvas, state.focusedStackID == nil {
                    ToolInputLayer()
                }

                // Archive — Calendar level paints its own heatmap; the
                // normal node group is hidden by the gate below. Day +
                // Card levels still use the node group (cards laid out
                // by `effectivePosition` / `effectiveSize`).
                if state.canvasMode == .archive && state.archiveLevel == .calendar {
                    ArchiveCalendarLayer()
                        .transition(.opacity)
                }

                // Archive — Lightbox chrome (caption pill + action row +
                // radial vignette). The focused card itself comes from
                // the node group, positioned + sized via the archive
                // overrides set up by `drillToCard`.
                if state.canvasMode == .archive,
                   case .card(let id) = state.archiveLevel {
                    ArchiveLightboxLayer(cardID: id)
                        .transition(.opacity)
                        .zIndex(1)
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
                // drops, revealing the bulbs beneath. In Archive's
                // Calendar level the group is hidden entirely
                // (the calendar paints its own layer). In Archive's Day
                // level only that day's cards are visible, laid out by
                // `effectivePosition` + `effectiveSize` (the Bento grid).
                //
                // Camera scale + pan is applied ONCE on the parent — pan
                // ticks only re-evaluate this one transform regardless of
                // how many cards live on the page. (Maps to the thesis's
                // "apply scale changes directly to the whole graphics
                // context.")
                if !(state.canvasMode == .archive && state.archiveLevel == .calendar) {
                    Group { nodeLayer }
                    .scaleEffect(cameraStore.camera.zoom, anchor: .topLeading)
                    .offset(x: cameraStore.camera.x, y: cameraStore.camera.y)
                    .opacity(cardsOpacity)
                    .blur(radius: cardsBlur)
                    .allowsHitTesting(state.toolMode == .select && state.canvasMode != .colorform)
                }

                // Connectors (arrows) — drawn above nodes so the live preview
                // and arrowheads stay visible during a drag-to-connect.
                // Hidden in Colorform because the re-laid-out cards make
                // their endpoints meaningless.
                if state.showConnectors && state.canvasMode == .canvas {
                    ConnectorsLayer()
                        .allowsHitTesting(state.toolMode == .select)
                }

                // Figma-style Smart Selection chrome — pink center rings +
                // gutter handles + tooltip + insertion indicator. Sits
                // above connectors so it can intercept clicks on rings and
                // handles cleanly. Auto-detects 1D rows / columns / 2D
                // grids in the current selection.
                // Suppressed in stack focus mode — the focus chrome owns
                // the screen and Smart Selection wouldn't apply anyway.
                if state.canvasMode == .canvas, state.focusedStackID == nil {
                    SmartSelectionLayer()
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
                if state.canvasMode == .canvas {
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
                        onPointerMove: { pointerLocation = $0 }
                    )
                    .zIndex(-1)
                }
            }
            .background(backgroundColor)
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
            .overlay(alignment: .top) {
                // Archive breadcrumb pill — appears in Day + Card levels
                // (the only places where there's a "back" path that the
                // user might want as a persistent affordance).
                if state.canvasMode == .archive,
                   state.archiveLevel != .calendar {
                    ArchiveBreadcrumb()
                        .padding(.top, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
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
        .overlay(alignment: .bottomLeading) {
            if state.canvasMode != .archive {
                ZoomControlsPill()
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if state.canvasMode != .archive {
                VStack(alignment: .trailing, spacing: 2) {
                    // Circular liquid-glass minimap. Hidden while the
                    // floating-window version is being shown. Mounted here
                    // (window bounds) for the same reason as the pills —
                    // the inner ZStack's frame can extend past the window.
                    if !state.isMinimapDetached {
                        LiquidGlassMinimap()
                    }
                    CanvasTogglesPill()
                        .padding(.trailing, 6)
                }
                .padding(.trailing, 10)
                .padding(.bottom, 16)
            }
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
    /// Screen spacing never drops below this (octave-doubled if it
    /// would) — bounds the dot count at extreme zoom-out.
    private static let minScreenSpacing: CGFloat = 6

    /// 0…1 reveal, animated up when the pointer enters the canvas and
    /// down when it leaves so the pool fades rather than popping.
    @State private var strength: Double = 0
    /// Last known cursor position — the pool fades out here after the
    /// pointer has already left (`pointer` is `nil` by then).
    @State private var lastPointer: CGPoint = .zero

    var body: some View {
        Canvas { context, size in
            guard strength > 0.001 else { return }
            let center = pointer ?? lastPointer
            let radius = Self.spotlightRadius

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

            // Clip iteration to the spotlight's bounding box.
            let loMinX = max(phaseX, center.x - radius)
            let loMaxX = min(size.width, center.x + radius)
            let loMinY = max(phaseY, center.y - radius)
            let loMaxY = min(size.height, center.y + radius)
            guard loMinX <= loMaxX, loMinY <= loMaxY else { return }

            let firstX = phaseX + ((loMinX - phaseX) / spacing).rounded(.down) * spacing
            let firstY = phaseY + ((loMinY - phaseY) / spacing).rounded(.down) * spacing
            let r2 = radius * radius

            var path = Path()
            var x = firstX
            while x <= loMaxX {
                let dx = x - center.x
                var y = firstY
                while y <= loMaxY {
                    let dy = y - center.y
                    if dx * dx + dy * dy <= r2 {
                        path.addEllipse(in: CGRect(
                            x: x - dotSize / 2, y: y - dotSize / 2,
                            width: dotSize, height: dotSize))
                    }
                    y += spacing
                }
                x += spacing
            }

            // One fill — the radial gradient fades the dots out toward
            // the spotlight edge.
            context.fill(
                path,
                with: .radialGradient(
                    Gradient(colors: [
                        Color.primary.opacity(0.55 * strength),
                        Color.primary.opacity(0.35 * strength),
                        .clear
                    ]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
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
