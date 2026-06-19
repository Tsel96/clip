import AppKit
import SwiftUI

/// The unified native canvas view (Spatial's `Canvas/CanvasView.swift`). Owns
/// the engine subtree built from a `CanvasConfig`:
///
///     CenterZoomScrollView (cursor-anchored magnify)
///       └─ FlippedContainer (content coords)
///            ├─ WideCollectionView + CanvasWorldLayout   (cards)
///            ├─ PassthroughHostingView(overlay)          (world-space connectors/selection)
///            └─ CanvasInputView                          (sole owner of all pointer input)
///
/// Phase A hosts only the scroll (the chrome pills + minimap island move in here
/// in A5, collapsing the SwiftUI `CanvasView` ZStack). Mounted by the
/// `CollectionCanvas` bridge; the `Coordinator` — held *weakly* by its
/// collaborators and by the event monitors — performs all state→view sync, so
/// this view stays a thin container.
final class CLIPCanvasView: NSView {
    let coordinator: CollectionCanvas.Coordinator
    /// The scrolled engine, filling this view. A5 adds chrome/minimap above it.
    private(set) weak var scroll: NSScrollView?

    init(config: CanvasConfig, coordinator: CollectionCanvas.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)

        let layout = CanvasWorldLayout()

        let collection = WideCollectionView()
        collection.contentWidth = config.worldBounds.size.width
        collection.collectionViewLayout = layout
        collection.isSelectable = false
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.register(HostingCollectionItem.self,
                            forItemWithIdentifier: CollectionCanvas.Coordinator.itemID)
        collection.dataSource = coordinator
        // ALL pointer interaction is owned by a single CanvasInputView (added
        // below) — the collection + its items are now purely visual.

        let scroll = CenterZoomScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = config.minZoom
        scroll.maxMagnification = config.maxZoom
        scroll.usesPredominantAxisScrolling = false
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .allowed

        // The document is a flipped container holding the collection (cards)
        // plus a world-space overlay (connectors/selection) on top. Both live in
        // content coordinates, so the scroll view's magnification scales them
        // together — connectors pan/zoom with the cards.
        let container = FlippedContainer()
        container.frame = CGRect(origin: .zero, size: config.worldBounds.size)
        collection.frame = container.bounds
        collection.autoresizingMask = [.width, .height]
        container.addSubview(collection)

        // The overlay already carries its content-coordinate camera (injected by
        // the caller, which knows worldBounds on the main actor).
        let overlayHost = PassthroughHostingView(
            rootView: AnyView(config.overlay.allowsHitTesting(false)))
        overlayHost.frame = container.bounds
        overlayHost.autoresizingMask = [.width, .height]
        container.addSubview(overlayHost, positioned: .above, relativeTo: collection)

        // The single input owner, layered ABOVE everything in the document so no
        // other view competes for clicks (Spatial's CanvasContentView model).
        let input = CanvasInputView(frame: container.bounds)
        input.autoresizingMask = [.width, .height]
        input.coordinator = coordinator
        container.addSubview(input, positioned: .above, relativeTo: overlayHost)
        coordinator.inputView = input

        scroll.documentView = container
        coordinator.container = container
        coordinator.overlayHost = overlayHost
        coordinator.scroll = scroll
        coordinator.collection = collection
        coordinator.layout = layout
        coordinator.apply(config)

        // Host the scroll, filling this container view.
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
        self.scroll = scroll

        // --- Screen-space islands (native shell collapse) ---
        // BEHIND the scroll: dot-grid spotlight + empty-state. Click-transparent
        // and visually behind the (transparent) scroll, so the grid shows
        // through the gaps between cards.
        if let behind = config.behindOverlay {
            let host = PassthroughHostingView(rootView: behind)
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host, positioned: .below, relativeTo: scroll)
        }
        // ABOVE the scroll: tool-input + smart-selection + alignment/spacing
        // guides. In select mode it's click-through → CanvasInputView owns the
        // click; in a tool mode it captures so ToolInputLayer draws.
        if let above = config.aboveOverlay {
            let host = ToolOverlayHostingView(rootView: above)
            host.isSelectMode = { [weak coordinator] in coordinator?.config.isSelectMode() ?? true }
            host.scrollRef = scroll
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host, positioned: .above, relativeTo: scroll)
        }

        scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main
        ) { [weak coordinator] _ in
            // Sync the camera in real time so the minimap / zoom readout track
            // live. The native cards are decoupled from the camera (frozen card
            // camera + suppressZoomEpoch), so this never re-renders them — the
            // reason it's safe to sync mid-gesture now without the blink.
            coordinator?.pushCameraFromScroll()
            // Keep native chrome (section outline + selection ring) a constant
            // on-screen width while zooming — cheap CALayer updates, no re-render.
            coordinator?.refreshChrome()
        }

        // Escape deselects (keyboard path, always available — no race).
        coordinator.escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            if event.keyCode == 53 {            // Escape
                coordinator?.config.onBackgroundClick()
                return nil
            }
            return event
        }
        // "C" with a single section selected → radial color picker at the cursor.
        coordinator.colorKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            // Plain 'c' only — never with ⌘/⌥/⌃ (so ⌘C copy etc. still work).
            guard let coordinator, event.keyCode == 8,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  coordinator.config.editingTextNodeID == nil,          // not typing
                  coordinator.colorPicker == nil else { return event }
            let sel = coordinator.config.liveSelection()
            guard sel.count == 1, let id = sel.first,
                  let node = coordinator.config.nodes.first(where: { $0.id == id }),
                  node.isSection else { return event }
            coordinator.presentColorPicker(for: id)
            return nil
        }

        // Start centered on the actual content (not the empty world margin) so
        // pinch-zoom has the cards under the cursor.
        DispatchQueue.main.async { [weak coordinator] in coordinator?.fitContent() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
