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
        // Phase B native connectors (flag-gated off) — draw into the scrolled
        // container so magnification pans/zooms them for free.
        if config.useNativeConnectors {
            let cc = ConnectorOverlayController()
            cc.attach(to: container)
            coordinator.connectorController = cc
        }
        // Native alignment guides (active — the visual half of native snapping).
        let gc = GuideOverlayController()
        gc.attach(to: container)
        coordinator.guideController = gc
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
            host.isSelectMode = { [weak coordinator] in
                guard let c = coordinator?.config else { return true }
                // Draw + connect + hand also pass through → CanvasInputView owns
                // the native stroke / drag-to-connect / grab-pan (the SwiftUI
                // ToolInputLayer's connect used the wrong coord space here).
                return c.isSelectMode() || c.isDrawMode() || c.isConnectMode() || c.isHandMode()
            }
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
        // Live magnify ticks update connector stroke widths (constant on screen)
        // + the inline label editor — the bounds notification lagged the pinch.
        scroll.onZoomChange = { [weak coordinator] in
            coordinator?.pushCameraFromScroll()
            coordinator?.refreshChrome()
        }

        // Escape deselects (keyboard path, always available — no race).
        coordinator.escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            guard event.keyCode == 53,          // Escape
                  let coordinator else { return event }
            // Esc in a sidebar/search/lightbox field belongs to that field.
            // Editing a card's own text on the canvas still ends via Esc.
            if coordinator.config.editingTextNodeID == nil,
               coordinator.shouldIgnoreCanvasKey(event) { return event }
            coordinator.config.onBackgroundClick()
            return nil
        }
        // "C" with a single item selected → Spatial flower color picker at the
        // cursor (works on any node, like Spatial — not just sections).
        coordinator.colorKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            // Typing in a text field: deliver single-key tool shortcuts
            // (V/T/D/C/N/O) as text so they never switch tools mid-word.
            if let coordinator, coordinator.forwardToFocusedTextInput(event) { return nil }
            // Plain 'c' only — never with ⌘/⌥/⌃ (so ⌘C copy etc. still work).
            guard let coordinator, event.keyCode == 8,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  coordinator.config.editingTextNodeID == nil,          // not typing
                  !coordinator.shouldIgnoreCanvasKey(event),           // search, rename, lightbox fields
                  coordinator.colorPicker == nil else { return event }
            let sel = coordinator.config.liveSelection()
            if sel.count == 1, let id = sel.first { coordinator.presentColorPicker(for: id) }
            // Always consume plain 'c' so it can NEVER fall through to the Connect
            // tool's keyboard shortcut (that collision left the canvas stuck in
            // connect mode, making card buttons unclickable). Proper launch =
            // the toolbar color button (next).
            return nil
        }

        // Delete / ⌫ removes the current selection. The SwiftUI menu
        // `.keyboardShortcut(.delete)` goes stale-disabled (commands don't track
        // the @StateObject reliably), so own it natively here — but NEVER steal
        // Delete from a text editor (canvas text edit, search, page rename…).
        coordinator.deleteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            guard let coordinator,
                  event.keyCode == 51 || event.keyCode == 117,      // ⌫ / fwd-delete
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  coordinator.config.editingTextNodeID == nil
            else { return event }
            // A real text field / field-editor has focus → let it handle the key.
            // (A canvas click makes CanvasInputView first responder, so a lingering
            // SwiftUI field-editor no longer blocks Delete on the canvas.)
            if let fr = coordinator.scroll?.window?.firstResponder,
               fr is NSText || (fr as? NSView)?.isKind(of: NSTextView.self) == true {
                return event
            }
            guard !coordinator.config.liveSelection().isEmpty
                    || !coordinator.config.selectedConnectorIDs.isEmpty else { return event }
            coordinator.config.onDelete()
            return nil
        }

        // Start centered on the actual content (not the empty world margin) so
        // pinch-zoom has the cards under the cursor.
        DispatchQueue.main.async { [weak coordinator] in coordinator?.fitContent() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

extension CollectionCanvas.Coordinator {
    /// True when a key event isn't the canvas's to handle: it was typed into a
    /// text field / field editor (search, page rename, lightbox fields), or it
    /// belongs to a different window or sheet. Local monitors see every key in
    /// the app, so canvas shortcuts must check this before consuming one.
    func shouldIgnoreCanvasKey(_ event: NSEvent) -> Bool {
        let canvasWindow = scroll?.window
        if let w = event.window, let canvasWindow, w !== canvasWindow { return true }
        return (event.window ?? canvasWindow)?.firstResponder is NSText
    }

    /// Plain letters that double as menu tool shortcuts (Tools menu).
    private static let toolShortcutLetters: Set<String> = ["v", "t", "d", "c", "n", "o"]

    /// If a text field in the canvas window has focus and `event` is a bare
    /// tool-shortcut letter, hand it straight to the field so the menu
    /// shortcut can't swallow it. Returns true when the event was delivered.
    func forwardToFocusedTextInput(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let chars = event.charactersIgnoringModifiers?.lowercased(),
              Self.toolShortcutLetters.contains(chars),
              let window = scroll?.window, event.window === window,
              let text = window.firstResponder as? NSText
        else { return false }
        text.keyDown(with: event)
        return true
    }
}
