import SwiftUI
import AppKit

/// Wraps any `CanvasNode` with: world-space positioning, camera scaling,
/// drag-to-move (singular or multi-selection), Option-duplicate-on-drag,
/// click-to-select, Shift-click-to-toggle, and a selection ring.
struct DraggableNode: View {
    @EnvironmentObject var state: CanvasState
    let node: CanvasNode

    /// True for the entire lightbox session of THIS card (open + the close
    /// animation, since `lightboxCardID` stays set until the hero unmounts).
    /// Hidden so the full-window hero — which grows out of, and shrinks back
    /// onto, this exact spot — never shows a duplicate beside it.
    private var isHiddenForLightbox: Bool { state.lightboxCardID == node.id }

    /// `nil` until the drag has begun. Used as a "drag-in-progress" flag.
    @State private var dragInProgress: Bool = false

    /// 0…1 creation-pop progress (0.85→1 scale + 0→1 opacity). Set in
    /// `init` to 0 for a node created within the last second — it pops
    /// in — and 1 for any older node (loaded from disk, or just scrolled
    /// back into the viewport-cull window; those must not replay the pop).
    @State private var appearProgress: CGFloat

    /// Each dragged node's position at the moment the drag began.
    /// Drag math always adds `value.translation` to these snapshots — never
    /// to the live mutating positions.
    @State private var startPositions: [UUID: CGPoint] = [:]

    /// Set of node ids being moved. Equal to either {node.id} (single drag)
    /// or to the entire current selection (multi drag), or to a freshly
    /// created set of duplicates (Option-drag).
    @State private var draggingIDs: Set<UUID> = []

    /// Page snapshot taken once at drag-start so the entire drag (and any
    /// Option-drag duplicate that happened on the first tick) collapses
    /// into a single undo entry when the gesture ends.
    @State private var undoSnapshot: PageSnapshot? = nil

    /// Hover state at the DraggableNode level — drives the "Show description"
    /// toggle's visibility. This is separate from each card view's internal
    /// hover (which controls in-card chrome like play/mute buttons).
    @State private var nodeHovering: Bool = false

    /// Tiny rotation applied when a user attempts to drag in a
    /// read-only view (Archive's Bento). Communicates "this view
    /// doesn't accept drags" without saying it (audit S3).
    @State private var rejectWiggle: CGFloat = 0

    /// Direction-tracking tilt during an active drag. Tracks
    /// *recent motion* (delta since the previous tick), not cumulative
    /// translation — so the card returns to vertical when the user
    /// pauses with the mouse still down. Reset to 0 on drag-end so the
    /// card settles flat with the same spring as the position.
    @State private var dragTilt: Double = 0

    /// Previous tick's cumulative `value.translation`, used to derive
    /// each tick's motion delta for `dragTilt`. Reset on drag-start.
    @State private var lastDragTranslation: CGSize = .zero

    /// Pending "no motion" decay — if no new `onChanged` fires within
    /// ~80 ms, springs `dragTilt` back to 0. Cancelled on every fresh
    /// tick and on drag-end. Lets the card un-tilt smoothly when the
    /// user holds the mouse still in the middle of a drag.
    @State private var dragTiltDecayWork: DispatchWorkItem? = nil

    /// One-shot under-damped scale pulse on the selection ring whenever
    /// this card transitions into the selection. Drives a 0.96 → 1.04
    /// → 1.0 bounce so picking a card has a perceptible "snap on" beat
    /// (Tier B2).

    init(node: CanvasNode) {
        self.node = node
        let isFresh = Date().timeIntervalSince(node.addedAt) < 1.0
        _appearProgress = State(initialValue: isFresh ? 0 : 1)
    }

    /// In-mode effective size — Archive's Bento level uses
    /// cardinality-aware tiles; other modes use the node's natural
    /// width × renderedHeight.
    private var effectiveSize: CGSize { state.effectiveSize(of: node) }
    /// True while the user is looking at one day's Bento — cards become
    /// click-to-drill targets and drags are disabled (read-only review).
    private var inArchiveBento: Bool {
        guard state.canvasMode == .archive else { return false }
        if case .day = state.archiveLevel { return true }
        return false
    }
    /// `true` whenever this node is being rendered through an effective
    /// size override (Archive Bento tile sizing).
    private var hasSizeOverride: Bool { inArchiveBento }

    /// Small displacement applied to this node while a connected peer
    /// is being dragged elsewhere on the canvas — the "rubber band"
    /// tug. Caps at 6 pt so even far-away peers don't drift far. Eased
    /// in/out by the spring inside `CanvasState.beginDrag` /
    /// `endDrag`'s `withAnimation` blocks.
    private var connectorTug: CGSize {
        guard let draggedID = state.activeDragID,
              draggedID != node.id,
              state.activeDragConnectedIDs.contains(node.id),
              let dragged = state.nodeByID[draggedID]
        else { return .zero }
        // Vector from this node's centre to the dragged node's centre.
        let myCentre = CGPoint(
            x: node.position.x + node.width / 2,
            y: node.position.y + state.renderedHeight(of: node) / 2
        )
        let theirCentre = CGPoint(
            x: dragged.position.x + dragged.width / 2,
            y: dragged.position.y + state.renderedHeight(of: dragged) / 2
        )
        let dx = theirCentre.x - myCentre.x
        let dy = theirCentre.y - myCentre.y
        let len = hypot(dx, dy)
        guard len > 1 else { return .zero }
        // Pull magnitude: stronger for close peers, fades out further
        // away (so peers across the canvas don't twitch). Cap at 6 pt.
        let pull = min(6.0, 800.0 / max(120.0, len))
        return CGSize(width: dx / len * pull, height: dy / len * pull)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ZStack with the card-stack ghosts as the back layer and
            // the head card's full chrome on top. We use a ZStack peer
            // (rather than `.background(stackGhosts)`) because SwiftUI
            // on macOS 13 doesn't reliably propagate `@State` /
            // `@ObservedObject` updates from inside async closures on
            // views rendered through the `.background()` modifier —
            // it treats them as decoration and aggressively prunes
            // their reactive subscriptions. As a ZStack child the
            // ghost view participates in the full SwiftUI lifecycle.
            ZStack(alignment: .topLeading) {
                stackGhosts
                nodeContent
                    .frame(
                        width: hasSizeOverride
                            ? effectiveSize.width
                            : (isTextNode ? nil : node.width),
                        height: hasSizeOverride
                            ? effectiveSize.height
                            : node.height
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: chromeCornerRadius,
                            style: .continuous
                        )
                    )
                    .background(heightProbe)
                    .overlay(selectionRing)
                    .overlay(connectHighlight)
                    .overlay(phoneOriginBadge, alignment: .topLeading)
                    // Inline video trim editor (covers the card while active).
                    // The entry point (scissors) lives in VideoNodeView's
                    // hover control cluster — a SwiftUI `.overlay` here does
                    // not reliably composite above the card's AVPlayerLayer.
                    .overlay { videoTrimOverlay }
                    // Hidden for the whole open+close window so the full-window
                    // hero card (which grows out of / shrinks back onto this
                    // exact spot) never shows a duplicate underneath.
                    .opacity(isHiddenForLightbox ? 0 : 1)
            }
        }
        // Make the whole card bounding rect one continuous hover / hit
        // region (so hover state and taps don't drop out over transparent
        // sub-regions).
        .contentShape(Rectangle())
        // Creation pop (see `appearProgress`): scales 0.85→1 and fades
        // 0→1 when the node is genuinely new; centre-anchored so it grows
        // in place. Driven from `init` + `.onAppear` below — not a
        // `.transition` — so a card re-entering the viewport-cull window
        // never replays it.
        .scaleEffect(0.85 + 0.15 * appearProgress, anchor: .center)
        .opacity(Double(appearProgress))
        // Tier A1: drag-direction tilt. Scaling on hover OR drag is
        // intentionally omitted — both would offset the card from its
        // underlying world rect, breaking the alignment-guide red
        // lines (drawn against world coordinates). Lift is conveyed
        // entirely via the shadow bloom + tilt below.
        // `rejectWiggle` is the read-only-mode reject signal (additive
        // so a wiggle plays through any tilt). `dragTilt` is reset to
        // 0 inside the drag-end `withAnimation` so the card settles
        // flat with the same spring as the position.
        .rotationEffect(.degrees(dragTilt + rejectWiggle), anchor: .center)
        // Tier A1 + B1: extra elevation shadow during drag / hover.
        // Stacks on top of the per-kind `figmaCardStyle` shadow so the
        // card visibly lifts off the canvas without us having to
        // re-plumb shadow state into every card view.
        //
        // The shadow's x is offset opposite the drag tilt (parallax
        // "lit from above" cue) — when the card leans right, its
        // shadow leans left as if a stationary light source above the
        // canvas was casting it. Subtle: at the max 3° tilt the
        // shadow shifts about 3 pt.
        .shadow(
            color: .black.opacity(
                dragInProgress ? 0.22 : (nodeHovering ? 0.10 : 0)
            ),
            radius: dragInProgress ? 18 : (nodeHovering ? 8 : 0),
            x: dragInProgress ? CGFloat(-dragTilt) : 0,
            y: dragInProgress ? 14 : (nodeHovering ? 5 : 0)
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.72),
                   value: dragInProgress)
        .animation(.spring(response: 0.35, dampingFraction: 0.82),
                   value: nodeHovering)
        // Camera scale + pan are applied on the parent (`CanvasView`'s
        // node Group), so each `DraggableNode` only positions itself in
        // world coordinates. `effectivePosition` returns the active
        // mode's layout override when one applies, else the node's
        // persisted position; the SwiftUI implicit animation (driven by
        // `withAnimation` inside enter/exit) makes cards glide between
        // layouts.
        //
        // The `connectorTug` adds a tiny offset toward any currently-
        // dragged peer this node is connected to — gives "rubber band"
        // tactility to connector relationships during drag.
        .offset(
            x: state.effectivePosition(of: node).x + connectorTug.width,
            y: state.effectivePosition(of: node).y + connectorTug.height
        )
        // While trimming this card, suppress its own drag so the timeline
        // handles (subviews) can be dragged without moving the card.
        .gesture(dragGesture, including: isTrimming ? .subviews : .all)
        // Double-click on a stack head opens focus mode (Apple Photos
        // album style). Wired BEFORE the single-tap so SwiftUI's tap
        // coalescer correctly distinguishes single vs double — without
        // this ordering single-tap would steal both events.
        .onTapGesture(count: 2) {
            // While trimming this card, the overlay owns interaction.
            if isTrimming { return }
            // Stack head → focus mode (Apple Photos album style).
            if state.isStackHead(node.id), state.focusedStackID == nil {
                state.enterStackFocus(headID: node.id)
                return
            }
            // Any other card → open the full-screen theater lightbox.
            // Canvas mode only (Archive has its own lightbox); not sections.
            guard state.canvasMode == .canvas, !node.isSection else { return }
            state.openLightbox(node.id)
        }
        .onTapGesture { handleTap() }
        .contextMenu { contextMenu }
        .onHover { nodeHovering = $0 }
        // Creation pop: a freshly-created node mounts with appearProgress
        // at 0 (set in `init`) and springs to 1. Older nodes mount at 1 —
        // the guard skips them, so scrolling a card back into the cull
        // window never replays the pop.
        .onAppear {
            guard appearProgress < 1 else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                appearProgress = 1
            }
        }
    }

    // MARK: - Video trim

    /// The local video URL for `.video` cards, else nil.
    private var videoURL: URL? {
        if case .video(let url, _) = node.kind { return url }
        return nil
    }
    /// True while THIS video card is in inline trim mode.
    private var isTrimming: Bool { state.trimmingCardID == node.id }

    /// The inline trim editor, covering the card while active.
    @ViewBuilder
    private var videoTrimOverlay: some View {
        if isTrimming, let url = videoURL {
            VideoTrimOverlay(
                fileURL: url,
                initialStart: node.trimStart,
                initialEnd: node.trimEnd,
                cornerRadius: chromeCornerRadius,
                onSave: { start, end in
                    state.setTrim(node.id, start: start, end: end)
                    state.trimmingCardID = nil
                },
                onReset: {
                    state.clearTrim(node.id)
                    state.trimmingCardID = nil
                },
                onCancel: { state.trimmingCardID = nil }
            )
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Cut")        { ensureSelected(); state.cutSelection() }
        Button("Copy")       { ensureSelected(); state.copySelection() }
        Button("Paste")      { state.pasteFromPasteboard() }
        Button("Duplicate")  {
            ensureSelected()
            let copies = state.duplicateNodes(state.selectedNodeIDs)
            if !copies.isEmpty { state.selectNodes(copies) }
        }
        Divider()
        Button("Group") {
            ensureSelected()
            state.groupSelection()
        }
        .disabled(state.groupableSelectionCount < 2)
        Button("Ungroup") {
            ensureSelected()
            state.ungroupSelection()
        }
        .disabled(!state.selectionHasGroupedNode)
        Button("Wrap in Section") {
            ensureSelected()
            state.wrapSelectionInSection()
        }
        Divider()
        Button("Bring to Front") {
            ensureSelected()
            state.bringToFront(state.selectedNodeIDs)
        }
        Button("Send to Back") {
            ensureSelected()
            state.sendToBack(state.selectedNodeIDs)
        }
        Divider()
        Button("Delete", role: .destructive) {
            ensureSelected()
            state.deleteSelected()
        }
    }

    /// If the right-clicked node isn't part of the current selection,
    /// promote *just* that node to the selection before the menu action runs.
    private func ensureSelected() {
        if !state.selectedNodeIDs.contains(node.id) {
            state.select(node.id)
        }
    }

    private var isTextNode: Bool {
        if case .text = node.kind { return true }
        return false
    }

    @ViewBuilder
    private var nodeContent: some View {
        switch node.kind {
        case .tweet(let url):
            TweetCardView(
                url: url,
                isLive: state.isLive(node),
                trimStart: node.trimStart,
                trimEnd: node.trimEnd,
                isSelected: state.selectedNodeIDs.contains(node.id),
                isTrimming: isTrimming,
                // Trim only on the canvas, and not while already trimming.
                onTrim: (state.canvasMode == .canvas && !isTrimming)
                    ? { state.trimmingCardID = node.id }
                    : nil,
                onSaveTrim: { start, end in
                    state.setTrim(node.id, start: start, end: end)
                    state.trimmingCardID = nil
                },
                onResetTrim: {
                    state.clearTrim(node.id)
                    state.trimmingCardID = nil
                },
                onCancelTrim: { state.trimmingCardID = nil }
            )

        case .instagram(let url):
            // WKWebView-backed. We can't pause the JS-driven autoplay
            // cleanly from outside, so the lifecycle gate is coarser than
            // for AVPlayer cards: when not "live," `InstagramCardView`
            // unmounts the web view entirely and shows a static poster,
            // freeing the WebKit content process.
            InstagramCardView(url: url, isLive: state.isLive(node))

        case .youtube(let url):
            // Same WKWebView lifecycle as Instagram: live = embedded muted
            // autoplay; not-live = static thumbnail poster, web view torn down.
            YouTubeNodeView(url: url, isLive: state.isLive(node))

        case .text(let content, let fontSize):
            TextNodeView(
                nodeID: node.id,
                content: content,
                fontSize: fontSize,
                isSelected: state.selectedNodeIDs.contains(node.id)
            )

        case .drawing(let stroke):
            DrawingNodeView(
                stroke: stroke,
                size: CGSize(width: node.width, height: node.height ?? 100),
                onDelete: { state.delete(id: node.id) }
            )

        case .image(let data, let filename):
            ImageNodeView(
                data: data,
                filename: filename,
                isLive: state.isLive(node)
            )

        case .video(let fileURL, let filename):
            VideoNodeView(
                fileURL: fileURL,
                filename: filename,
                isLive: state.isLive(node),
                trimStart: node.trimStart,
                trimEnd: node.trimEnd,
                // Offer trim only on the canvas (not in the lightbox), and
                // never while already trimming this card.
                onTrim: (state.canvasMode == .canvas && !isTrimming)
                    ? { state.trimmingCardID = node.id }
                    : nil,
                // Keep the controls (incl. scissors) revealed while selected,
                // so the trim affordance is discoverable without hovering.
                isSelected: state.selectedNodeIDs.contains(node.id)
            )

        case .section(let title, let color):
            SectionNodeView(
                node: node,
                title: title,
                color: color
            )

        case .stickyNote(let content, let color):
            StickyNodeView(
                node: node,
                content: content,
                color: color
            )
        }
    }

    /// Provenance badge for cards that arrived via the iPhone share pipe
    /// (`node.origin == .phone`). A small frosted capsule with the iPhone
    /// glyph, pinned to the card's top-leading corner — enough to read
    /// "this came from my phone" at a glance without crowding the content.
    @ViewBuilder
    private var phoneOriginBadge: some View {
        if node.origin == .phone {
            HStack(spacing: 3) {
                Image(systemName: "iphone")
                    .font(.system(size: 9, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text("iPhone")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            .padding(6)
            .allowsHitTesting(false)
            .help("Added from iPhone")
        }
    }

    /// Apple-style ghost cards drawn behind the head of a `groupID`
    /// stack. Empty view for non-grouped nodes and non-head members —
    /// non-head members are filtered out of `CanvasView.visibleNodes`
    /// entirely, so they never reach this branch anyway.
    /// Each hidden member is passed through to `StackVisualView` so it
    /// can render the member's actual content thumbnail (image data /
    /// video poster / kind-aware placeholder) in the ghost position —
    /// the user sees what's inside the deck at a glance.
    @ViewBuilder
    private var stackGhosts: some View {
        // While the user is in focus mode the deck has been "opened" —
        // every member is laid out in its grid slot. Re-rendering the
        // head's ghost cards here would visually overlap neighbouring
        // grid cells, so we suppress the decoration for the duration.
        if state.focusedStackID == nil,
           let group = node.groupID,
           state.isStackHead(node.id) {
            // Hidden members = every group member except the head, in
            // a stable uuid-ascending order so the ghost arrangement
            // doesn't shuffle between re-renders.
            let hidden = state.nodes
                .filter { $0.groupID == group && $0.id != node.id }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            StackVisualView(
                hiddenMembers: hidden,
                cardSize: CGSize(
                    width: hasSizeOverride ? effectiveSize.width : node.width,
                    height: hasSizeOverride
                        ? effectiveSize.height
                        : (node.height ?? state.renderedHeight(of: node))
                ),
                cornerRadius: chromeCornerRadius,
                groupLabel: state.groupName(forHead: node.id)
            )
        }
    }

    private var heightProbe: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { state.reportMeasuredHeight(geo.size.height, for: node.id) }
                .onChange(of: geo.size.height) { newH in
                    state.reportMeasuredHeight(newH, for: node.id)
                }
        }
    }

    @ViewBuilder
    private var connectHighlight: some View {
        if let pending = state.pendingConnector {
            if pending.sourceID == node.id {
                RoundedRectangle(cornerRadius: chromeCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7),
                                  lineWidth: 2 * chromeInverseZoom)
                    .allowsHitTesting(false)
            } else if pending.hoveredTargetID == node.id {
                RoundedRectangle(cornerRadius: chromeCornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(
                            lineWidth: 2.5 * chromeInverseZoom,
                            dash: [5 * chromeInverseZoom, 4 * chromeInverseZoom]
                        )
                    )
                    .background(
                        RoundedRectangle(cornerRadius: chromeCornerRadius, style: .continuous)
                            .fill(Color.accentColor.opacity(0.06))
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var selectionRing: some View {
        if state.selectedNodeIDs.contains(node.id) {
            ZStack {
                RoundedRectangle(cornerRadius: chromeCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor,
                                  lineWidth: chromeLineWidth * chromeInverseZoom)
                    .allowsHitTesting(false)
                // Four square corner handles when this node is the SOLE
                // selection and a resizable kind (text auto-sizes, excluded).
                if isSingleSelected && isResizableKind {
                    ResizeHandles(
                        node: node,
                        renderedSize: CGSize(
                            width: node.width,
                            height: state.renderedHeight(of: node)
                        )
                    )
                }
            }
        }
    }

    /// Corner radius used by both the selection ring and the connect
    /// highlight, matched to the underlying view's own rounded shape so
    /// the chrome never looks misaligned. Text is tight (Figma-style).
    ///
    /// Tweet / Instagram / Image / Video / Drawing all share the
    /// `figmaCardStyle` 19.375 pt continuous corner radius — using a
    /// tighter radius for the ring made the stroke visibly drift
    /// inside the card edge at the corners.
    private var chromeCornerRadius: CGFloat {
        switch node.kind {
        case .text:       return 2
        case .stickyNote: return StickyNodeView.cornerRadius
        case .section:    return SectionNodeView.cornerRadius
        case .tweet, .instagram, .youtube, .image, .video, .drawing:
            return 19.375
        }
    }

    private var chromeLineWidth: CGFloat {
        if case .text = node.kind { return 1 }
        return 1.5
    }

    /// Reciprocal of the active zoom, used to keep chrome (selection ring,
    /// connect highlight) at a constant *screen* thickness even though
    /// they live inside the parent's `.scaleEffect(zoom)`. Clamped so a
    /// zoom of 0 (theoretically unreachable) doesn't NaN the line width.
    private var chromeInverseZoom: CGFloat {
        let z = state.camera.zoom
        return z > 0.0001 ? 1 / z : 1
    }

    private var isSingleSelected: Bool {
        state.selectedNodeIDs.count == 1 && state.selectedNodeIDs.contains(node.id)
    }

    private var isResizableKind: Bool {
        switch node.kind {
        case .text:                        return false
        case .tweet, .instagram, .youtube,
             .image, .video, .drawing,
             .section, .stickyNote:        return true
        }
    }

    // MARK: - Tap

    private func handleTap() {
        // Archive Bento: tapping a card drills into Lightbox (v3).
        if inArchiveBento {
            state.drillToCard(node.id)
            return
        }
        if NSEvent.modifierFlags.contains(.shift) {
            state.toggleNodeSelection(node.id)
        } else {
            state.select(node.id)
        }
    }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                // Archive Bento is read-only — drags would fight its
                // imposed layout. Communicate "this is a review view"
                // with a tiny wiggle (audit S3) instead of a silent
                // no-op.
                if inArchiveBento {
                    triggerRejectWiggle()
                    return
                }
                if !dragInProgress {
                    initDrag()
                    lastDragTranslation = .zero
                }

                // Delta since the previous tick = instantaneous motion.
                // Using cumulative translation here would leave the
                // card tilted even when the user paused mid-drag with
                // the mouse held down.
                let delta = CGSize(
                    width:  value.translation.width  - lastDragTranslation.width,
                    height: value.translation.height - lastDragTranslation.height
                )
                lastDragTranslation = value.translation

                // Per-tick position update wrapped in a *very tight*
                // interactive spring so the card trails the cursor by
                // ~80 ms — gives the elastic-lag feel that reads as
                // "alive" (matches the Luke Orb reference). The spring
                // also softens snap-to-grid corrections from feeling
                // like jumps.
                withAnimation(.interactiveSpring(
                    response: 0.12,
                    dampingFraction: 0.86,
                    blendDuration: 0.05
                )) {
                    applyTranslation(value.translation)
                    // Tilt is proportional to recent horizontal motion.
                    // Capped at ±3°; the divisor is calibrated so a
                    // brisk drag (~12 pt/tick) saturates the cap.
                    dragTilt = max(-3, min(3, Double(delta.width / 4)))
                }

                // If no new tick arrives within ~80 ms (user paused
                // mid-drag), spring `dragTilt` back to 0 so the card
                // straightens without releasing.
                dragTiltDecayWork?.cancel()
                let decay = DispatchWorkItem {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                        dragTilt = 0
                    }
                }
                dragTiltDecayWork = decay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08,
                                              execute: decay)
            }
            .onEnded { value in
                guard !inArchiveBento else { return }
                // Cancel any pending "you've paused" tilt-decay since
                // we're about to spring everything to zero anyway.
                dragTiltDecayWork?.cancel()
                dragTiltDecayWork = nil
                // Tier A2: velocity-projected throw + spring settle.
                //
                // SwiftUI's `predictedEndLocation` accumulates the last
                // ~150 ms of motion; the difference from the current
                // location is a stable velocity hint on macOS 13+ (no
                // `value.velocity` until macOS 14).
                let v = CGSize(
                    width:  value.predictedEndLocation.x - value.location.x,
                    height: value.predictedEndLocation.y - value.location.y
                )
                let speed = hypot(v.width, v.height)
                let throwOffset: CGSize = speed > 200
                    ? CGSize(
                        width:  max(-100, min(100, v.width  * 0.18)),
                        height: max(-100, min(100, v.height * 0.18))
                      )
                    : .zero
                let finalDelta = CGSize(
                    width:  value.translation.width  + throwOffset.width,
                    height: value.translation.height + throwOffset.height
                )
                // Spring-settle: the final `applyTranslation` writes
                // positions through `@Published nodes`, so the implicit
                // animation propagates to every dragging card. The
                // throw becomes a real overshoot-and-catch; the lift
                // (scaleEffect / shadow / tilt) decays in the same
                // motion since `dragInProgress = false` is inside the
                // animation block too.
                // Tap haptic timed with the spring's onset (NOT its
                // termination) so the user feels the "thud" at the
                // moment they let go, matching the visual commit.
                Haptics.tap()
                withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) {
                    applyTranslation(finalDelta)
                    dragInProgress = false
                    dragTilt = 0
                    state.activeAlignmentGuides = []
                    state.activeSpacingIndicators = []
                    // Release the drag-active broadcast inside the same
                    // animation block so connected nodes spring back
                    // from their tug offset in lockstep with the
                    // dragged card settling.
                    state.endDrag()
                }
                if let snap = undoSnapshot {
                    state.commitUndoable(from: snap)
                }
                draggingIDs = []
                startPositions = [:]
                undoSnapshot = nil
            }
    }

    /// One-shot wiggle: rotate ±2° twice and settle to 0. Triggered
    /// when the user tries to drag in a non-draggable mode (Archive's
    /// read-only Bento).
    private func triggerRejectWiggle() {
        guard rejectWiggle == 0 else { return }   // don't re-trigger mid-wiggle
        withAnimation(.easeInOut(duration: 0.08)) { rejectWiggle = -2 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeInOut(duration: 0.10)) { rejectWiggle = 2 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.easeInOut(duration: 0.10)) { rejectWiggle = 0 }
        }
    }

    /// Decide on the FIRST tick which nodes are moving and snapshot their
    /// starting positions.
    private func initDrag() {
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        let alreadySelected = state.selectedNodeIDs.contains(node.id)

        // 1. Take the undo snapshot BEFORE anything mutates so a possible
        //    Option-drag duplicate + the subsequent move collapse to one entry.
        undoSnapshot = state.snapshotForUndo()

        // 2. Determine the *base set* — nodes we'd move if not duplicating.
        let baseSet: Set<UUID> = alreadySelected
            ? state.selectedNodeIDs
            : [node.id]

        if optionHeld {
            // 3. Option-drag: expand the base set with section contents
            //    *before* duplicating, so each section's contained cards
            //    are duplicated alongside it. Dragging the duplicates as
            //    a group preserves the section→contents relationship; the
            //    originals stay put. (Matches Figma's "Opt-drag a frame
            //    duplicates its contents too" behaviour.)
            //
            //    NB: we deliberately skip the post-hoc containment
            //    expansion below — the copies sit at the originals'
            //    positions, so `nodeIDs(insideWorldRect:)` on a copy's
            //    rect would pick up the *originals* and drag them along
            //    with the duplicate (a real bug).
            let expanded: Set<UUID> = baseSet.reduce(into: baseSet) { acc, id in
                if let rect = state.sectionRect(of: id) {
                    acc.formUnion(state.nodeIDs(insideWorldRect: rect))
                }
            }
            let copies = state.duplicateNodes(expanded)
            draggingIDs = copies.isEmpty ? expanded : copies
            state.selectNodes(draggingIDs)
        } else {
            // 4. Normal drag: move the base set. If we clicked an unselected
            //    node, it replaces the selection.
            draggingIDs = baseSet
            if !alreadySelected { state.select(node.id) }

            // 4b. Section containment: any section in the dragging set
            // carries its contained (non-section) cards along, so
            // dragging a section header moves the section + its cards
            // as a unit. Contained ids piggy-back on the same translation
            // but are NOT added to the selection.
            var contained: Set<UUID> = []
            for id in draggingIDs {
                if let rect = state.sectionRect(of: id) {
                    contained.formUnion(state.nodeIDs(insideWorldRect: rect))
                }
            }
            draggingIDs.formUnion(contained)

            // 4c. Card-stack carry: dragging a stack head must also
            // translate every hidden member of its group, so the
            // members ungroup at the *current* stack location instead
            // of snapping back to their pre-group positions.
            draggingIDs = state.expandedDragSet(from: draggingIDs)
        }

        // 5. Snapshot start positions for the move math.
        startPositions = [:]
        for n in state.nodes where draggingIDs.contains(n.id) {
            startPositions[n.id] = n.position
        }
        dragInProgress = true

        // Broadcast that this node is the active drag representative,
        // and which other nodes are connected to it — so they can
        // apply a small "tug" offset toward the dragged card. Eased
        // in via spring inside CanvasState.beginDrag.
        state.beginDrag(of: node.id)
    }

    private func applyTranslation(_ t: CGSize) {
        let z = state.camera.zoom
        let dx = t.width / z
        let dy = t.height / z

        // Move all dragged nodes by the raw translation first.
        var newPositions: [UUID: CGPoint] = [:]
        for id in draggingIDs {
            guard let start = startPositions[id] else { continue }
            newPositions[id] = CGPoint(x: start.x + dx, y: start.y + dy)
        }

        // Snap + guides driven by ONE representative node (the one this
        // gesture's view was created for). Treat all other dragging nodes
        // as rigid with the representative, so the same delta applies.
        let repID = node.id
        if let repStart = startPositions[repID],
           let repPos = newPositions[repID] {

            let h = state.renderedHeight(of: node)
            let prospective = CGRect(
                x: repPos.x, y: repPos.y,
                width: node.width, height: h
            )

            // "Other rects" = every non-dragging node on the page.
            let others: [CGRect] = state.nodes.compactMap { n in
                guard !draggingIDs.contains(n.id) else { return nil }
                return CGRect(
                    x: n.position.x, y: n.position.y,
                    width: n.width, height: state.renderedHeight(of: n)
                )
            }

            let result = AlignmentEngine.snap(
                draggingRect: prospective,
                otherRects: others,
                zoom: z,
                snapToGrid: state.showGrid
            )

            // Equal-spacing pass — runs on the alignment-snapped rect and
            // only touches an axis the alignment pass left free, so
            // edge-snapping and gap-equalising never fight over the same
            // coordinate.
            let alignmentClaimedX = result.guides.contains { $0.axis == .vertical }
            let alignmentClaimedY = result.guides.contains { $0.axis == .horizontal }
            let spacing = AlignmentEngine.equalSpacing(
                draggingRect: result.rect,
                otherRects: others,
                zoom: z,
                allowX: !alignmentClaimedX,
                allowY: !alignmentClaimedY
            )

            // Apply the combined (align + spacing) delta to every dragged node.
            let snapDX = spacing.rect.origin.x - prospective.origin.x
            let snapDY = spacing.rect.origin.y - prospective.origin.y
            if snapDX != 0 || snapDY != 0 {
                for id in draggingIDs {
                    if let p = newPositions[id] {
                        newPositions[id] = CGPoint(x: p.x + snapDX, y: p.y + snapDY)
                    }
                }
            }
            // Even if no snap fired, repStart silences "unused" warning.
            _ = repStart

            state.activeAlignmentGuides = result.guides
            state.activeSpacingIndicators = spacing.indicators
        }

        for (id, pos) in newPositions {
            state.updatePosition(of: id, to: pos)
        }
    }
}
