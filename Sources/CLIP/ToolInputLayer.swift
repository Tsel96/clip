import SwiftUI
import AppKit

/// Full-canvas-sized layer that handles input for the active tool:
/// • `.draw` — drag freehand strokes; live preview, commit on release
/// • `.text` — click to drop a text node
/// • `.select` — transparent, no-op (clicks fall through to nodes)
struct ToolInputLayer: View {
    @EnvironmentObject var state: CanvasState
    @EnvironmentObject var cameraStore: CameraStore
    @EnvironmentObject var smartSelection: SmartSelectionController
    @State private var liveStrokeScreenPoints: [CGPoint] = []
    @State private var sectionDragStartScreen: CGPoint? = nil
    @State private var sectionDragCurrentScreen: CGPoint? = nil

    /// Selection at the moment the rubber-band drag passed the 4pt
    /// "this is really a marquee" threshold. `nil` means we haven't
    /// started a real marquee yet — a stationary click on empty canvas
    /// must still fall through to the deselect-on-release branch.
    @State private var marqueeBaseSelection: Set<UUID>? = nil

    var body: some View {
        switch state.toolMode {
        case .draw:       drawLayer
        case .text:       textLayer
        case .connect:    connectLayer
        case .section:    sectionLayer
        case .stickyNote: stickyNoteLayer
        case .select:     selectLayer
        }
    }

    // MARK: - Select  (rubber-band + click-empty-to-deselect)

    private var selectLayer: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(rubberBandGesture)

            if let rect = state.rubberBandScreenRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.10))
                    .overlay(
                        Rectangle()
                            .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Single-gesture handler that doubles as:
    ///   • a click on empty canvas (no movement) → deselect everything
    ///   • a drag on empty canvas → **live** rubber-band that updates
    ///     selection on every tick, so cards visibly enter the selected
    ///     state as the marquee sweeps over them (Figma-style)
    private var rubberBandGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(CanvasCoords.name))
            .onChanged { value in
                // Safety: a previous Smart Selection drag may have been
                // interrupted (e.g. gesture stolen by a sibling layer).
                // The first tick of every new marquee is the right place
                // to flush any leftover reorder / gutter state so we
                // never compose two visuals on top of each other.
                if state.rubberBandScreenRect == nil {
                    smartSelection.cancelAllDrags()
                }
                let s = value.startLocation
                let c = value.location
                let rect = CGRect(
                    x: min(s.x, c.x),
                    y: min(s.y, c.y),
                    width:  abs(s.x - c.x),
                    height: abs(s.y - c.y)
                )
                state.rubberBandScreenRect = rect

                // Promote this gesture from "maybe a tap" to "actual
                // marquee" the first tick the user has moved beyond
                // the threshold. We snapshot the pre-drag selection so
                // shift-additive marqueeing has a stable base, and so
                // shrinking the rect past a node correctly deselects
                // it (rather than leaving it stuck-on).
                if marqueeBaseSelection == nil,
                   rect.width >= 4 || rect.height >= 4 {
                    marqueeBaseSelection = state.selectedNodeIDs
                }
                if let base = marqueeBaseSelection {
                    let additive = NSEvent.modifierFlags.contains(.shift)
                    state.liveSelectInMarquee(
                        screenRect: rect,
                        base: base,
                        additive: additive
                    )
                }
            }
            .onEnded { _ in
                let rect = state.rubberBandScreenRect ?? .zero
                state.rubberBandScreenRect = nil

                // Stationary click on empty canvas (no real marquee fired)
                // → deselect. Resign whatever was first responder (e.g. a
                // text node's TextField) so its caret stops blinking.
                if marqueeBaseSelection == nil,
                   rect.width < 4, rect.height < 4 {
                    state.deselectAll()
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                // If a marquee did run, its per-tick `liveSelectInMarquee`
                // calls already produced the right final selection — no
                // commit step needed.
                marqueeBaseSelection = nil
            }
    }

    // MARK: - Connect

    private var connectLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(connectGesture)
    }

    private var connectGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(CanvasCoords.name))
            .onChanged { value in
                let world = state.screenToWorld(point: value.location)

                // Initialise on first event by hit-testing the start location.
                if state.pendingConnector == nil {
                    let startWorld = state.screenToWorld(point: value.startLocation)
                    guard let source = state.nodeAt(world: startWorld) else { return }
                    state.pendingConnector = PendingConnector(
                        sourceID: source.id,
                        cursorWorld: world,
                        hoveredTargetID: nil
                    )
                }

                state.pendingConnector?.cursorWorld = world
                let hovered = state.nodeAt(world: world)
                let hoveredID: UUID? = (hovered?.id == state.pendingConnector?.sourceID) ? nil : hovered?.id
                state.pendingConnector?.hoveredTargetID = hoveredID
            }
            .onEnded { _ in
                if let p = state.pendingConnector,
                   let targetID = p.hoveredTargetID {
                    state.addConnector(from: p.sourceID, to: targetID)
                }
                state.pendingConnector = nil
            }
    }

    // MARK: - Draw

    private var drawLayer: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(drawGesture)

            // Live stroke preview while the gesture is active.
            if liveStrokeScreenPoints.count >= 2 {
                PathMath.smoothPath(through: liveStrokeScreenPoints)
                    .stroke(
                        state.drawColor.swiftUIColor,
                        style: StrokeStyle(
                            // World-units * camera-zoom = screen pixels, so the
                            // live preview matches what the committed node will
                            // look like after rendering.
                            lineWidth: state.drawWidth * cameraStore.camera.zoom,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(CanvasCoords.name))
            .onChanged { value in
                liveStrokeScreenPoints.append(value.location)
            }
            .onEnded { _ in
                state.commitStroke(screenPoints: liveStrokeScreenPoints)
                liveStrokeScreenPoints = []
            }
    }

    // MARK: - Text

    private var textLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .named(CanvasCoords.name)) { location in
                let world = state.screenToWorld(point: location)
                state.addText(at: world)
            }
    }

    // MARK: - Sticky note

    /// Click anywhere to drop a 200×200 sticky and immediately edit it.
    private var stickyNoteLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .named(CanvasCoords.name)) { location in
                let world = state.screenToWorld(point: location)
                state.addStickyNote(at: world)
            }
    }

    // MARK: - Section

    /// Drag-to-create a section frame. Shows a live rubber-band rectangle
    /// while the drag is in flight, mirroring the select-mode marquee.
    private var sectionLayer: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(sectionGesture)

            if let preview = sectionRubberBandRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.06))
                    .overlay(
                        Rectangle()
                            .strokeBorder(
                                Color.accentColor.opacity(0.7),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                    )
                    .frame(width: preview.width, height: preview.height)
                    .position(x: preview.midX, y: preview.midY)
                    .allowsHitTesting(false)
                    .transaction { $0.animation = nil }   // no fade during drag
            }
        }
    }

    /// Screen-space rect for the live section rubber-band, clamped to the
    /// same minimum that `addSection` enforces — so the preview always
    /// matches the committed result.
    private var sectionRubberBandRect: CGRect? {
        guard let s = sectionDragStartScreen, let c = sectionDragCurrentScreen
        else { return nil }
        let drawn = CGRect(
            x: min(s.x, c.x), y: min(s.y, c.y),
            width:  abs(s.x - c.x),
            height: abs(s.y - c.y)
        )
        // Don't show feedback for a fingertip tap — it would flash a
        // dashed minimum-sized box at the cursor.
        guard drawn.width > 4 || drawn.height > 4 else { return nil }

        let z = cameraStore.camera.zoom
        let minScreen = CGSize(
            width:  CanvasNode.Kind.section(title: "", color: .slate).minSize.width  * z,
            height: CanvasNode.Kind.section(title: "", color: .slate).minSize.height * z
        )
        let w = max(minScreen.width,  drawn.width)
        let h = max(minScreen.height, drawn.height)
        // Anchor growth at the cursor so the preview grows away from the
        // start point (the natural drag direction), not from the centre.
        let originX = s.x <= c.x ? drawn.minX : drawn.maxX - w
        let originY = s.y <= c.y ? drawn.minY : drawn.maxY - h
        return CGRect(x: originX, y: originY, width: w, height: h)
    }

    private var sectionGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(CanvasCoords.name))
            .onChanged { value in
                if sectionDragStartScreen == nil {
                    sectionDragStartScreen = value.startLocation
                }
                sectionDragCurrentScreen = value.location
            }
            .onEnded { value in
                defer {
                    sectionDragStartScreen = nil
                    sectionDragCurrentScreen = nil
                }
                let start = value.startLocation
                let end   = value.location
                let dx = abs(start.x - end.x)
                let dy = abs(start.y - end.y)
                // Tap with no movement: drop a default-sized section
                // centred on the click point.
                let world1 = state.screenToWorld(point: start)
                let world2 = state.screenToWorld(point: end)
                let rect: CGRect
                if dx < 4 && dy < 4 {
                    let size = CGSize(width: 360, height: 240)
                    rect = CGRect(
                        x: world1.x - size.width / 2,
                        y: world1.y - size.height / 2,
                        width: size.width, height: size.height
                    )
                } else {
                    rect = CGRect(
                        x: min(world1.x, world2.x),
                        y: min(world1.y, world2.y),
                        width:  abs(world1.x - world2.x),
                        height: abs(world1.y - world2.y)
                    )
                }
                state.addSection(rect: rect)
            }
    }
}
