import SwiftUI
import AppKit
import AVFoundation
import Combine

@MainActor
final class CanvasState: ObservableObject {

    // MARK: - Pages  (per-page state lives inside each Page)

    @Published var pages: [Page]
    @Published var activePageID: UUID { didSet { if activePageID != oldValue { cachedWorldBounds = nil } } }

    /// iPhone → canvas share inbox: watches a user-chosen iCloud Drive
    /// folder for links dropped by the "Add to Canvas" Shortcut.
    let sharedInbox = SharedLinkInbox()
    /// The folder currently being watched (nil until the user picks one),
    /// surfaced for the sidebar status line.
    @Published private(set) var sharedInboxFolderURL: URL?

    /// Transient in-app toast (e.g. "Added a YouTube link from iPhone").
    /// Rendered by `CanvasView`; auto-dismissed by `showToast`.
    @Published var toast: ToastContent?
    private var toastDismissWork: DispatchWorkItem?

    /// The live pan/zoom camera lives on its own `CameraStore` (see that
    /// type) so a pan tick invalidates only the camera-transformed views,
    /// never the node views. `camera` below is a pass-through to it, so
    /// existing `state.camera` call sites are unchanged. Per-page camera
    /// is still persisted: the auto-save pipeline syncs `camera` back into
    /// `pages[activePageIndex].camera`, and `switchTo(pageID:)` swaps it.
    let cameraStore = CameraStore()
    /// Stack-focus mode: when set, holds the `groupID` of the stack
    /// the user double-clicked. Members of that group are temporarily
    /// un-hidden and rendered at `focusPositions[id]` / `focusSizes[id]`
    /// instead of being filtered out by `isHiddenByStack`. Esc /
    /// click-out clears this and the cards spring back into the stack.
    @Published var focusedStackID: UUID? = nil
    /// Per-member target world position while in focus mode. Empty
    /// outside focus mode; populated by `enterStackFocus`. Read by
    /// `effectivePosition` to override the node's stored position.
    @Published var focusPositions: [UUID: CGPoint] = [:]
    /// Per-member target world size while in focus mode. Same
    /// semantics as `focusPositions`. Read by `effectiveSize`.
    @Published var focusSizes: [UUID: CGSize] = [:]
    /// Camera state captured at the moment the user entered focus
    /// mode, so `exitStackFocus` can restore the pan + zoom they had
    /// before. Focus mode resets the live camera to `(0, 0, 1)` so
    /// the grid uses the viewport's natural coords.
    private var focusOriginCamera: Camera? = nil

    /// Figma-style Smart Selection state machine. Owned here so it shares
    /// the canvas lifetime; published as an environment object so the
    /// chrome layer + key monitor can reach it. Lazily wired post-`init`
    /// so the controller can hold an `unowned` reference back here.
    var smartSelection: SmartSelectionController!
    var camera: Camera {
        get { cameraStore.camera }
        set {
            let zoomChanged = abs(newValue.zoom - cameraStore.camera.zoom) > 0.0001
            cameraStore.camera = newValue
            markCameraInteracting()
            if zoomChanged { markZoomInteracting() }
        }
    }

    /// True while the camera is actively moving (pan / zoom / glide). While
    /// set, `isLive` drops every NSView-backed media card (WKWebView /
    /// AVPlayer) to its static SwiftUI poster, so none of those views is
    /// transformed inside the hosting hierarchy — that transform-during-
    /// layout is what re-enters AppKit's constraint engine and trips the
    /// depth-16 recursion guard on macOS 26/27 (EXC_BREAKPOINT in
    /// -[NSView _layoutSubtreeWithOldSize:]). Flips once at gesture start
    /// and once ~0.15 s after it ends — not per pan tick.
    @Published private(set) var isCameraInteracting = false
    private var cameraSettleTimer: Timer?

    /// Mark the camera as moving and (re)arm the settle timer. Default
    /// runloop mode is deliberate: the timer cannot fire during
    /// `.eventTracking`, so the flag stays true for the whole gesture and
    /// clears only once the runloop returns to `.default` (gesture ended).
    private func markCameraInteracting() {
        if !isCameraInteracting { isCameraInteracting = true }
        cameraSettleTimer?.invalidate()
        cameraSettleTimer = Timer.scheduledTimer(
            withTimeInterval: 0.15, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.isCameraInteracting = false }
        }
    }

    /// True only while the *zoom* is actively changing (not pan). Drives
    /// dropping `AVPlayerLayer`-backed video cards to their poster *during a
    /// zoom*: SwiftUI's `.scaleEffect` renders the live player black, and an
    /// NSView-backed player composites above any SwiftUI cover, so the only
    /// reliable fix is to unmount it for the duration of the zoom. Scoped to
    /// zoom (pan leaves video live, as the team intends). Same `.default`-mode
    /// settle-timer trick as `isCameraInteracting`.
    @Published private(set) var isZoomInteracting = false
    private var zoomSettleTimer: Timer?

    private func markZoomInteracting() {
        if !isZoomInteracting { isZoomInteracting = true }
        zoomSettleTimer?.invalidate()
        zoomSettleTimer = Timer.scheduledTimer(
            withTimeInterval: 0.2, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.isZoomInteracting = false }
        }
    }

    /// Bumped whenever `camera.zoom` changes (never on pan). Node views
    /// observe `CanvasState`, so this is how their semantic-zoom gate
    /// (`isLive`) re-evaluates on zoom without re-rendering on every pan
    /// tick. Maintained by the `cameraStore` subscription (`setupZoomWatch`).
    @Published var zoomEpoch: Int = 0
    private var lastObservedZoom: CGFloat = 1
    private var cameraCancellable: AnyCancellable?

    /// O(1) lookup index over `nodes`. Maintained as a side-effect of the
    /// `nodes` setter so callers can read `state.nodeByID[id]` instead of
    /// `state.nodes.first(where: { $0.id == id })`. Not `@Published` —
    /// it's a derived cache, so it doesn't fire its own observer storm;
    /// reactive views still re-render because the underlying `nodes`
    /// mutation already publishes `$pages`.
    private(set) var nodeByID: [UUID: CanvasNode] = [:]

    init() {
        // Restore from disk, falling back to a single empty "Page 1".
        if let snapshot = CanvasStore.load(), !snapshot.pages.isEmpty {
            // Sections are being retired in favour of folders — drop any that
            // were saved so they disappear from the canvas (the cards they
            // visually contained stay, since containment was spatial).
            self.pages = snapshot.pages.map { page in
                var p = page
                p.nodes = p.nodes.filter { if case .section = $0.kind { return false }; return true }
                return p
            }
            self.activePageID =
                snapshot.pages.contains(where: { $0.id == snapshot.activePageID })
                ? snapshot.activePageID
                : snapshot.pages[0].id
        } else {
            let firstPage = Page(name: "Page 1")
            self.pages = [firstPage]
            self.activePageID = firstPage.id
        }
        // Migrate any nodes loaded from a pre-`addedAt` snapshot (their
        // decoded value is `Date.distantPast`). We rewrite to synthetic
        // ascending dates so chronology is preserved — newer array index
        // = newer timestamp, anchored just before "now."
        Self.migrateAddedAtSentinels(in: &self.pages)
        // Rename/pin the iPhone inbox page if it was created under an older
        // name, and float pinned pages to the top.
        Self.migrateIncomingPage(in: &self.pages)
        // Hydrate the live camera + index from the just-loaded active page.
        let activeIdx = self.pages.firstIndex(where: { $0.id == self.activePageID }) ?? 0
        self.camera = self.pages[activeIdx].camera
        self.nodeByID = Dictionary(
            uniqueKeysWithValues: self.pages[activeIdx].nodes.map { ($0.id, $0) }
        )
        // Restore user prefs (last view mode).
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.k_lastViewMode),
           let mode = CanvasMode(rawValue: raw),
           mode.isViewMode, mode != .colorform {
            self.lastViewMode = mode
        }
        // Restore the *exact* mode the user was in at quit (Canvas is
        // the default if nothing saved; Colorform / Archive
        // are re-entered after the viewport has measured itself — see
        // `CanvasView.restoreLastViewModeIfNeeded`).
        if let raw = defaults.string(forKey: Self.k_canvasMode),
           let mode = CanvasMode(rawValue: raw) {
            self.pendingRestoredMode = mode
        }
        setupAutoSave()
        setupPrefsAutoSave()
        setupZoomWatch()
        setupTerminationFlush()
        // Wire the Smart Selection controller after everything else so
        // its Combine subscriptions on `$selectedNodeIDs` / `$pages` /
        // `$canvasMode` see the fully-hydrated state.
        self.smartSelection = SmartSelectionController(state: self)
        // Pre-warm every video card's first-frame poster into the
        // process-wide `VideoPosterStore` cache so subsequent off-viewport
        // uses (card-stack ghosts, semantic-zoom resting state) render
        // their thumbnails instantly with no flash of the black fallback.
        // Decode is utility priority + cached, so this never blocks UI.
        prewarmVideoPosters()
        // iPhone → canvas share inbox: route arrivals to the Incoming page,
        // then resume watching the previously-chosen folder (if any).
        sharedInbox.onURL = { [weak self] url in self?.ingestSharedURL(url) }
        restoreSharedInboxFolder()
    }

    /// Async-decode every local video node's first-frame poster on
    /// launch. The `VideoPosterStore` cache makes this idempotent —
    /// subsequent groupings, semantic-zoom transitions, and Smart
    /// Selection ghost views all hit the warm cache and paint covers
    /// in the same frame they appear.
    private func prewarmVideoPosters() {
        var urls: Set<URL> = []
        for page in pages {
            for node in page.nodes {
                if case .video(let url, _) = node.kind {
                    urls.insert(url)
                }
            }
        }
        for url in urls {
            Task { @MainActor in
                await GhostThumbnailStore.shared.preload(videoAt: url)
            }
        }
    }

    /// Set on launch from the persisted `k_canvasMode`. Read once by
    /// `CanvasView` after the GeometryReader has measured the viewport
    /// (modes that re-layout need a real size), then cleared.
    var pendingRestoredMode: CanvasMode? = nil

    private static let k_lastViewMode         = "view.lastMode"
    /// The exact `canvasMode` the user was in at quit time — including
    /// Canvas itself, unlike `lastViewMode` which only tracked view modes
    /// for cross-mode "exit back to" purposes.
    private static let k_canvasMode           = "view.canvasMode"

    /// Walk every loaded node; for any whose `addedAt` is the sentinel
    /// `Date.distantPast` (meaning the snapshot pre-dated the field),
    /// rewrite to a synthetic timestamp keyed off the node's array
    /// position. Older index = older timestamp; the newest pre-existing
    /// node lands ~1 ms before `Date.now`.
    private static func migrateAddedAtSentinels(in pages: inout [Page]) {
        let now = Date()
        for pIdx in pages.indices {
            let count = pages[pIdx].nodes.count
            for nIdx in pages[pIdx].nodes.indices {
                guard pages[pIdx].nodes[nIdx].addedAt == .distantPast else { continue }
                let offset = TimeInterval(count - nIdx - 1) * -0.001
                pages[pIdx].nodes[nIdx].addedAt = now.addingTimeInterval(offset)
            }
        }
    }

    /// Persist `lastViewMode` to `UserDefaults` whenever it changes.
    /// Cheap (just a string write), no debounce.
    private var prefsCancellables: Set<AnyCancellable> = []
    private func setupPrefsAutoSave() {
        $lastViewMode
            .dropFirst()
            .sink { mode in
                if let raw = mode?.rawValue {
                    UserDefaults.standard.set(raw, forKey: Self.k_lastViewMode)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.k_lastViewMode)
                }
            }
            .store(in: &prefsCancellables)
        // Persist the *actual* current mode so the next launch reopens
        // the user exactly where they left off (Canvas / Archive
        // / Colorform). Colorform is allowed here — the launch-time
        // restoration in `CanvasView.restoreLastViewModeIfNeeded` does
        // the async re-entry.
        $canvasMode
            .dropFirst()
            .sink { mode in
                UserDefaults.standard.set(mode.rawValue, forKey: Self.k_canvasMode)
            }
            .store(in: &prefsCancellables)
    }

    // MARK: - Auto-persistence

    private var autoSaveCancellable: AnyCancellable?

    /// Combine pipeline: any mutation to `pages`, `activePageID`, or the
    /// live `camera` schedules a debounced (~0.5 s) atomic write to
    /// `~/Library/Application Support`. Silent, no Save dialog — the
    /// canvas is restored on the next launch.
    private func setupAutoSave() {
        autoSaveCancellable = Publishers
            .CombineLatest3($pages, $activePageID, cameraStore.$camera)
            .dropFirst()                              // skip the initial value
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.saveToDisk() }
            }
    }

    /// Watch the camera store; bump `zoomEpoch` only when the *zoom*
    /// changes (panning leaves it untouched), so node views re-evaluate
    /// `isLive` on zoom without re-rendering on every pan tick.
    /// When true (native NSCollectionView canvas active), don't bump
    /// `zoomEpoch` on zoom: the native cards are always-live and positioned by
    /// the collection layout, so a zoom must NOT re-render them (that re-render
    /// — swapping poster↔live — is the card-blink at gesture boundaries). The
    /// minimap / zoom readout still update because they observe `cameraStore`
    /// directly, not `zoomEpoch`.
    var suppressZoomEpoch = false

    private func setupZoomWatch() {
        lastObservedZoom = cameraStore.camera.zoom
        cameraCancellable = cameraStore.$camera
            .sink { [weak self] cam in
                guard let self, cam.zoom != self.lastObservedZoom else { return }
                self.lastObservedZoom = cam.zoom
                if !self.suppressZoomEpoch { self.zoomEpoch &+= 1 }
            }
    }

    /// The full document as it should hit disk: the live camera is flushed
    /// into a LOCAL copy of `pages` — mutating `self.pages` here would fire
    /// `$pages` and re-trigger the debounced save in an infinite loop.
    private var snapshotForDisk: CanvasSnapshot {
        var pagesForDisk = pages
        if let activeIdx = pagesForDisk.firstIndex(where: { $0.id == activePageID }) {
            pagesForDisk[activeIdx].camera = camera
        }
        return CanvasSnapshot(pages: pagesForDisk, activePageID: activePageID)
    }

    @MainActor
    private func saveToDisk() {
        // Snapshot construction is a cheap copy-on-write value copy; the
        // expensive part (JSON encode of every page, including embedded
        // image bytes, plus the disk write) happens on `CanvasStore`'s
        // background queue so it can never hitch an interaction.
        CanvasStore.saveAsync(snapshotForDisk)
    }

    /// Last-chance synchronous write at quit. The auto-save is debounced
    /// (0.5 s) and encodes on a background queue, so without this a
    /// mutation made just before ⌘Q could miss the disk.
    private func setupTerminationFlush() {
        terminationCancellable = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                CanvasStore.saveSync(self.snapshotForDisk)
            }
    }

    private var terminationCancellable: AnyCancellable?

    /// Index of the currently active page in `pages`. Falls back to 0 if the
    /// active id has somehow gone stale (shouldn't happen, but defensive).
    private var activePageIndex: Int {
        pages.firstIndex(where: { $0.id == activePageID }) ?? 0
    }

    /// The current page, useful for places that want everything at once.
    var activePage: Page {
        get { pages[activePageIndex] }
        set { pages[activePageIndex] = newValue }
    }

    /// Computed forwards into the active page so all existing call sites
    /// (`state.nodes.append(...)`, `state.connectors`) keep working unchanged.
    /// Mutating these triggers `$pages` because Swift performs a
    /// get-mutate-set cycle on the array element, which counts as a
    /// mutation of `pages` itself.
    ///
    /// The `nodes` setter also rebuilds `nodeByID` so connector routing
    /// and hit-testing get O(1) lookups for free.
    var nodes: [CanvasNode] {
        get {
            guard pages.indices.contains(activePageIndex) else { return [] }
            return pages[activePageIndex].nodes
        }
        set {
            guard pages.indices.contains(activePageIndex) else { return }
            pages[activePageIndex].nodes = newValue
            nodeByID = Dictionary(uniqueKeysWithValues: newValue.map { ($0.id, $0) })
            // Keep Archive's per-day cache fresh whenever the doc
            // mutates while the user is viewing the calendar.
            if canvasMode == .archive {
                setArchiveDays(ArchiveEngine.daysWithContent(from: newValue))
            }
        }
    }

    var connectors: [Connector] {
        get {
            guard pages.indices.contains(activePageIndex) else { return [] }
            return pages[activePageIndex].connectors
        }
        set {
            guard pages.indices.contains(activePageIndex) else { return }
            pages[activePageIndex].connectors = newValue
        }
    }

    // MARK: - Page management

    /// Append a new page named "Page N" and switch to it.
    func addPage() {
        let new = Page(name: "Page \(pages.count + 1)")
        pages.append(new)
        switchTo(pageID: new.id)
    }

    func renamePage(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[idx].name = trimmed
    }

    /// Page whose deletion is awaiting user confirmation (sidebar shows a
    /// confirmation dialog while non-nil). Deleting a page destroys every
    /// card on it, so it must never be a single silent click.
    @Published var pageAwaitingDeletion: Page? = nil

    /// One-shot backup of the most recently deleted page so ⌘Z can bring
    /// it back. Cleared as soon as any other undoable mutation lands —
    /// page restoration is only offered while it is the latest action.
    private var deletedPageBackup: (page: Page, index: Int)? = nil

    /// First step of page deletion: validate, then ask. The actual removal
    /// happens in `confirmDeletePage()` once the user confirms.
    func requestDeletePage(_ id: UUID) {
        guard pages.count > 1 else {
            alert = AlertContent(
                title: "Can't delete the last page",
                message: "A document must always have at least one page."
            )
            return
        }
        guard let page = pages.first(where: { $0.id == id }) else { return }
        pageAwaitingDeletion = page
    }

    /// Second step: actually remove the page, keeping a backup so the
    /// deletion is undoable (⌘Z restores the page and its cards).
    func confirmDeletePage() {
        guard let page = pageAwaitingDeletion else { return }
        pageAwaitingDeletion = nil
        guard pages.count > 1,
              let idx = pages.firstIndex(where: { $0.id == page.id }) else { return }
        deletedPageBackup = (pages[idx], idx)
        let wasActive = (page.id == activePageID)
        pages.remove(at: idx)
        if wasActive {
            // Prefer the page that was previously above it; fall back to first.
            let newIdx = max(0, idx - 1)
            switchTo(pageID: pages[newIdx].id)
        }
        showToast("Deleted “\(page.name)” — ⌘Z to undo", systemImage: "trash")
    }

    /// Restore the most recently deleted page. Returns false when there is
    /// nothing to restore (the caller falls through to normal page undo).
    private func restoreDeletedPageIfPending() -> Bool {
        guard let backup = deletedPageBackup else { return false }
        deletedPageBackup = nil
        pages.insert(backup.page, at: min(backup.index, pages.count))
        switchTo(pageID: backup.page.id)
        return true
    }

    /// Switch the active page. Clears selection because the previously
    /// selected ids belong to a different page's node set. Also exits
    /// Colorform mode since clusters / bulbs are per-page. The outgoing
    /// page's live camera is flushed into its `Page.camera` so it's
    /// restored when the user comes back.
    func switchTo(pageID: UUID) {
        guard pages.contains(where: { $0.id == pageID }) else { return }
        if canvasMode == .colorform { exitColorform() }
        // Persist outgoing page's live camera (if the page still exists —
        // `deletePage` calls switchTo after removing the page, so we look
        // it up explicitly by id rather than via `activePageIndex`).
        if let outIdx = pages.firstIndex(where: { $0.id == activePageID }) {
            pages[outIdx].camera = camera
        }
        activePageID = pageID
        // Hydrate the live camera + node index from the incoming page.
        if let inIdx = pages.firstIndex(where: { $0.id == pageID }) {
            camera = pages[inIdx].camera
            nodeByID = Dictionary(
                uniqueKeysWithValues: pages[inIdx].nodes.map { ($0.id, $0) }
            )
        }
        selectedNodeIDs = []
        selectedConnectorIDs = []
        pendingFocusNodeID = nil
        pendingConnector = nil
        rubberBandScreenRect = nil
    }

    // MARK: - Undo / redo

    /// One stack per page so switching pages preserves history.
    @Published private(set) var undoStacks: [UUID: UndoStack] = [:]

    var canUndo: Bool {
        deletedPageBackup != nil || (undoStacks[activePageID]?.canUndo ?? false)
    }
    var canRedo: Bool { undoStacks[activePageID]?.canRedo ?? false }

    private var currentSnapshot: PageSnapshot {
        PageSnapshot(nodes: nodes, connectors: connectors)
    }

    /// Re-entrancy guard. While > 0, nested `withUndoable` calls just run
    /// the mutation without pushing — so e.g. `deleteSelected` (which calls
    /// `delete(id:)` per node) yields exactly one undo entry, not N.
    private var undoDepth = 0

    /// Wrap any state mutation that should be undoable. Snapshots the page
    /// *before* the mutation; if the mutation actually changed something,
    /// pushes that snapshot onto the active page's undo stack.
    func withUndoable(_ mutation: () -> Void) {
        if undoDepth > 0 { mutation(); return }
        undoDepth += 1
        let before = currentSnapshot
        mutation()
        let after = currentSnapshot
        undoDepth -= 1
        guard before != after else { return }
        deletedPageBackup = nil
        undoStacks[activePageID, default: UndoStack()].push(before)
    }

    /// Explicit snapshot for multi-tick interactions (e.g. drag): capture
    /// the page at gesture-start, run the gesture without `withUndoable`,
    /// then on gesture-end call `commitUndoable(from:)` with that snapshot.
    func snapshotForUndo() -> PageSnapshot { currentSnapshot }

    /// Commit an explicit snapshot — used by drag-style gestures so that
    /// 60 tick-by-tick position updates collapse into one undo entry.
    func commitUndoable(from before: PageSnapshot) {
        let after = currentSnapshot
        guard before != after else { return }
        deletedPageBackup = nil
        undoStacks[activePageID, default: UndoStack()].push(before)
    }

    func undo() {
        // A just-deleted page is the most recent action — restore it first.
        if restoreDeletedPageIfPending() { return }
        var stack = undoStacks[activePageID] ?? UndoStack()
        guard let restored = stack.popUndo(current: currentSnapshot) else { return }
        applySnapshot(restored)
        undoStacks[activePageID] = stack
        // Reset transient interaction state that might reference vanished nodes.
        selectedNodeIDs.formIntersection(Set(nodes.map(\.id)))
        selectedConnectorIDs.formIntersection(Set(connectors.map(\.id)))
        pendingConnector = nil
    }

    func redo() {
        var stack = undoStacks[activePageID] ?? UndoStack()
        guard let restored = stack.popRedo(current: currentSnapshot) else { return }
        applySnapshot(restored)
        undoStacks[activePageID] = stack
        selectedNodeIDs.formIntersection(Set(nodes.map(\.id)))
        selectedConnectorIDs.formIntersection(Set(connectors.map(\.id)))
        pendingConnector = nil
    }

    private func applySnapshot(_ s: PageSnapshot) {
        guard pages.indices.contains(activePageIndex) else { return }
        pages[activePageIndex].nodes = s.nodes
        pages[activePageIndex].connectors = s.connectors
        // Keep the lookup index in sync with the restored snapshot —
        // direct-write bypasses our `nodes` setter.
        nodeByID = Dictionary(uniqueKeysWithValues: s.nodes.map { ($0.id, $0) })
    }

    // MARK: - Document-global state

    /// Multi-selection. Singular `selectedNodeID` / `selectedConnectorID`
    /// computed properties return one element of these for code paths that
    /// don't care about multi-select semantics yet.
    @Published var selectedNodeIDs: Set<UUID> = []
    @Published var selectedConnectorIDs: Set<UUID> = []
    @Published var viewportSize: CGSize = .zero

    /// App appearance (light / dark / follow-system). Persisted across launches.
    /// Drives `preferredColorScheme` + the resolved `ClipTheme` injected at the
    /// root, so the whole UI flips with a single toggle.
    @Published var themeMode: ThemeMode =
        ThemeMode(rawValue: UserDefaults.standard.string(forKey: "clip.themeMode") ?? "") ?? .dark
    {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: "clip.themeMode") }
    }

    var selectedNodeID: UUID? { selectedNodeIDs.first }
    var selectedConnectorID: UUID? { selectedConnectorIDs.first }
    var hasSelection: Bool { !selectedNodeIDs.isEmpty || !selectedConnectorIDs.isEmpty }

    /// In-flight rubber-band rectangle (in canvas/screen coordinates).
    @Published var rubberBandScreenRect: CGRect? = nil

    /// Live alignment guides while a node is being dragged. Rendered by
    /// `CanvasView` as 1pt red lines over the canvas.
    @Published var activeAlignmentGuides: [AlignmentGuide] = []
    /// Pink equal-gap measurement segments shown while dragging.
    @Published var activeSpacingIndicators: [SpacingIndicator] = []

    /// Snapshot of the resized node's frame at drag-start. Lives on
    /// `CanvasState` (rather than `@State` inside `ResizeHandles`) because
    /// any of 8 handle views could be the one driving the drag, and the
    /// state needs to outlive their per-handle scope.
    var activeResizeStart: CGRect? = nil
    /// Page snapshot taken at resize-start so the whole resize collapses
    /// to one undo entry on `commitUndoable(from:)`.
    var activeResizeUndoSnapshot: PageSnapshot? = nil

    /// Whether the minimap has been popped out into its own NSPanel.
    @Published var isMinimapDetached: Bool = false {
        didSet {
            // Sync the floating window with the flag. If something else flips
            // the bool back (e.g. NSWindowDelegate.windowWillClose), the
            // controller hides itself first, then we just set the flag — so
            // calling `hide()` again is a no-op.
            if isMinimapDetached {
                minimapWindowController.show(state: self)
            } else {
                minimapWindowController.hide()
            }
        }
    }
    private lazy var minimapWindowController = MinimapWindowController()

    func detachMinimap() { isMinimapDetached = true }
    func attachMinimap() { isMinimapDetached = false }

    @Published var toolMode: ToolMode = .select
    @Published var drawColor: StrokeColor = .blue
    @Published var drawWidth: CGFloat = 3

    // MARK: - Colorform mode (transient — not persisted)

    /// `.canvas` = normal infinite canvas. `.colorform` = cards regrouped
    /// by dominant color into spatial clusters, with soft "color bulbs"
    /// fading in at low zoom. Never written to disk: the app always opens
    /// in `.canvas`.
    @Published var canvasMode: CanvasMode = .canvas
    /// Dominant color per node, populated asynchronously when entering
    /// Colorform. Empty in `.canvas` mode.
    @Published var dominantColors: [UUID: RGB] = [:]
    /// Spatial override applied to nodes in `.colorform` mode — keys missing
    /// fall through to the node's persisted `position`. Cleared on exit,
    /// so the underlying canvas layout is never touched.
    @Published var colorformPositions: [UUID: CGPoint] = [:]
    /// Bulbs rendered by `ColorformLayer`. Sized to enclose their cluster.
    @Published var colorBulbs: [ColorBulb] = []
    /// True while `enterColorform()` is fetching colors (so the UI can
    /// show a subtle activity indicator if it wants to).
    @Published var isComputingColorform: Bool = false
    /// Camera snapshot taken at the moment we entered Colorform, so we
    /// can restore the user's exact viewport on exit. Per-page (Colorform
    /// is page-scoped).
    private var preColorformCamera: Camera? = nil

    /// Last *view* mode (Archive — never Colorform, which is too expensive
    /// to recompute on cold launch). Restored after the snapshot loads so
    /// the user re-opens in the view they left in. Persisted (UserDefaults).
    @Published var lastViewMode: CanvasMode? = nil

    // MARK: - Archive mode state

    /// Sub-level within Archive: Calendar → (drill) → Day → (drill) → Card.
    @Published var archiveLevel: ArchiveLevel = .calendar
    /// Local-time day → ids of nodes added that day. Computed lazily
    /// when needed (on enter + when `nodes` mutates while in Archive).
    @Published var archiveDays: [Date: [UUID]] = [:]
    /// Reverse of `archiveDays`: node id → the day it lives in. Used by
    /// `popArchiveLevel`, `lightboxNavigate`, and the breadcrumb so
    /// they can look up the parent day in O(1) instead of walking the
    /// archiveDays dictionary on every navigation event.
    private(set) var cardToDay: [UUID: Date] = [:]
    /// Per-card position override active in the Bento level. Keyed by
    /// node id; populated by `bentoLayout`. Cleared on level pop.
    @Published var archivePositions: [UUID: CGPoint] = [:]
    /// Per-card size override active in the Bento level. Same lifecycle
    /// as `archivePositions`.
    @Published var archiveSizes: [UUID: CGSize] = [:]
    /// Camera snapshot taken on entry so `exitArchive` can restore the
    /// user's exact viewport from the canvas they left.
    private var preArchiveCamera: Camera? = nil

    /// Whether the connectors layer is rendered. Toggled from the
    /// bottom-right floating control bar.
    @Published var showConnectors: Bool = true
    /// Whether the dot grid is rendered.
    @Published var showGrid: Bool = true
    /// When true, every video-bearing card (local video, video tweets,
    /// Instagram) is forced to its static preview frame and its player
    /// torn down. Toggled from the bottom-right floating control bar.
    @Published var videosShowPreviewOnly: Bool = false

    /// id of a freshly placed editable node (text or sticky) that should
    /// auto-focus its editor on appear. Cleared once consumed.
    @Published var pendingFocusNodeID: UUID? = nil

    /// id of the text node currently in inline edit. While set, that one card's
    /// hosted content stays hit-testable so its TextField receives keys/caret
    /// clicks; the canvas input layer (CanvasInputView) steps aside for it.
    @Published var editingTextNodeID: UUID? = nil

    /// ids of freshly added image nodes that should play the wavefront
    /// reveal once when they appear. Cleared by the node view once consumed.
    @Published var pendingRevealNodeIDs: Set<UUID> = []

    /// In-flight drag-to-connect (live preview line).
    @Published var pendingConnector: PendingConnector? = nil

    /// id of the node currently being dragged (representative node of
    /// a multi-drag, set when the gesture begins). Lets every other
    /// node react — connected nodes tug toward it, future polish can
    /// add focus dimming / shadow casting. Nil when no drag in flight.
    @Published var activeDragID: UUID? = nil
    /// Set of node ids connected to `activeDragID` via a connector.
    /// Recomputed when `activeDragID` is set so per-card tug math is
    /// O(1) instead of scanning every connector per render.
    @Published var activeDragConnectedIDs: Set<UUID> = []

    /// Cached rendered heights, keyed by node id, reported by the node views.
    /// Used so connectors can hit the correct edge of an auto-sized card.
    @Published var measuredHeights: [UUID: CGFloat] = [:]
    /// Staging for height-probe reports. `reportMeasuredHeight` is called
    /// from inside a SwiftUI layout pass (a GeometryReader background);
    /// writing the @Published `measuredHeights` there *synchronously* can
    /// re-enter layout and, on macOS 26/27, trip AppKit's recursion trap
    /// (EXC_BREAKPOINT in `_layoutSubtreeWithOldSize` — seen when exiting
    /// Archive/Colorform, where many auto-height cards re-measure at once
    /// during the transition). Reports are buffered and flushed once on the
    /// next main-actor turn, outside the current layout pass.
    private var pendingHeights: [UUID: CGFloat] = [:]
    private var heightFlushScheduled = false

    @Published var isAddSheetPresented = false
    @Published var isSearchPresented = false

    /// Which sidebar tab is showing: the page list or the flat Outline of
    /// every card across pages.
    enum SidebarTab: Hashable { case pages, outline }
    @Published var sidebarTab: SidebarTab = .pages
    @Published var alert: AlertContent? = nil

    // Figma-equivalent range: ~2% to 1600%. Lets you frame a large board
    // at a glance (2%) and inspect pixel-level detail (1600%).
    static let minZoom: CGFloat = 0.02
    static let maxZoom: CGFloat = 16.0

    struct AlertContent: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    // MARK: - Tweet creation

    func addTweet(url: String, at worldPoint: CGPoint? = nil,
                  origin: CanvasNode.Origin = .local) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // The regex is the validator — it tolerates tracking params,
        // /statuses/ paths, and other human-real URL shapes that the
        // cruder substring check would reject.
        guard TweetService.extractTweetID(from: trimmed) != nil else {
            alert = AlertContent(
                title: "Not an X / Twitter URL",
                message: "Paste a link that points at a single tweet, e.g. https://x.com/user/status/123…"
            )
            return
        }

        let cardWidth: CGFloat = 360
        let centre = worldPoint ?? screenToWorld(point: viewportCentre)
        let jitter: CGFloat = worldPoint == nil ? CGFloat.random(in: -40...40) : 0
        let position = CGPoint(
            x: centre.x - cardWidth / 2 + jitter,
            y: centre.y - 120 + jitter
        )

        var node = CanvasNode.tweet(url: trimmed, position: position, width: cardWidth)
        node.origin = origin
        withUndoable { nodes.append(node) }
        pendingRevealNodeIDs.insert(node.id)
    }

    func pasteFromClipboard() {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            alert = AlertContent(title: "Clipboard is empty",
                                  message: "Copy a post link first, then press ⌘V.")
            return
        }
        addPostFromURL(text)
    }

    /// Decides whether the pasted URL is a tweet, an Instagram post, or
    /// something we can't handle yet, and routes accordingly.
    func addPostFromURL(_ url: String, at worldPoint: CGPoint? = nil,
                        origin: CanvasNode.Origin = .local) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // Route by what the real parsers can extract, not by substring
        // sniffing — the machine sweats so a /statuses/ path or a link
        // full of tracking params still lands as a card.
        if TweetService.extractTweetID(from: trimmed) != nil
            || TweetService.isLikelyTweetURL(trimmed) {
            addTweet(url: trimmed, at: worldPoint, origin: origin)
        } else if InstagramService.parse(trimmed) != nil
            || InstagramService.isLikelyInstagramURL(trimmed) {
            addInstagram(url: trimmed, at: worldPoint, origin: origin)
        } else if YouTubeService.videoID(from: trimmed) != nil
            || YouTubeService.isLikelyYouTubeURL(trimmed) {
            addYouTube(url: trimmed, at: worldPoint, origin: origin)
        } else {
            // Any other http(s) link becomes a rendered web-clip card
            // instead of a dead-end alert.
            addWebClip(url: trimmed, at: worldPoint, origin: origin)
        }
    }

    /// Add a web-clip card for an arbitrary http(s) URL. Non-web strings
    /// (no scheme) get a gentle alert rather than a broken card.
    func addWebClip(url: String, at worldPoint: CGPoint? = nil,
                    origin: CanvasNode.Origin = .local) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            alert = AlertContent(
                title: "Not a link",
                message: "Paste a web address (starting with http:// or https://), an X / Instagram / YouTube post, or drop a file."
            )
            return
        }
        let cardWidth: CGFloat = 480, cardHeight: CGFloat = 320
        let centre = worldPoint ?? screenToWorld(point: viewportCentre)
        let jitter: CGFloat = worldPoint == nil ? CGFloat.random(in: -40...40) : 0
        let position = CGPoint(x: centre.x - cardWidth / 2 + jitter,
                               y: centre.y - cardHeight / 2 + jitter)
        var node = CanvasNode.webclip(url: trimmed, position: position,
                                      width: cardWidth, height: cardHeight)
        node.origin = origin
        withUndoable { nodes.append(node) }
        pendingRevealNodeIDs.insert(node.id)
    }

    // MARK: - Local file imports
    //
    // Limits intentionally mirror Figma's:
    //   • Images:   ≤ 4 MB                and ≤ 4096 × 4096 px
    //   • Videos:   ≤ 100 MB, ≤ 4 minutes, and ≤ 4096 × 4096 px

    static let maxImageBytes: Int64 = 4 * 1024 * 1024
    static let maxImagePixelDim: Int = 4096

    static let maxVideoBytes: Int64 = 100 * 1024 * 1024
    static let maxVideoDurationSeconds: Double = 240
    static let maxVideoPixelDim: CGFloat = 4096

    enum LocalImportError: LocalizedError {
        case unsupportedType
        case readFailed
        case oversizedImage(Int64)
        case oversizedVideo(Int64)
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .unsupportedType:
                return "Only images (PNG, JPEG, HEIC, GIF, WebP, TIFF) and videos (MP4, MOV, M4V) are supported."
            case .readFailed:
                return "Couldn't read the file."
            case .oversizedImage(let limit):
                return "Image is too large. Maximum is \(byteString(limit))."
            case .oversizedVideo(let limit):
                return "Video is too large. Maximum is \(byteString(limit))."
            case .invalidImage:
                return "That file isn't a valid image."
            }
        }

        private func byteString(_ b: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
        }
    }

    /// Add an image from local disk.
    ///   • Rejects files larger than `maxImageBytes` (4 MB).
    ///   • Rejects images whose intrinsic pixel dimensions exceed
    ///     `maxImagePixelDim` (4096 px) on either axis.
    /// Caps the on-canvas width/height at 600pt while preserving aspect ratio.
    func addImage(data: Data, filename: String, at worldPoint: CGPoint? = nil) {
        guard data.count <= Self.maxImageBytes else {
            alert = AlertContent(
                title: "Image too large",
                message: "Images can be up to \(byteString(Self.maxImageBytes))."
            )
            return
        }
        guard let image = NSImage(data: data),
              image.size.width > 0,
              image.size.height > 0 else {
            alert = AlertContent(title: "Invalid image",
                                  message: LocalImportError.invalidImage.errorDescription ?? "")
            return
        }

        // Pixel-dimension check uses the underlying bitmap, not the
        // point-based `image.size` (which can be scaled for HiDPI).
        let pixelsWide = image.representations.first?.pixelsWide ?? Int(image.size.width)
        let pixelsHigh = image.representations.first?.pixelsHigh ?? Int(image.size.height)
        if pixelsWide > Self.maxImagePixelDim || pixelsHigh > Self.maxImagePixelDim {
            alert = AlertContent(
                title: "Image too large",
                message: "Images can be up to \(Self.maxImagePixelDim) × \(Self.maxImagePixelDim) px."
            )
            return
        }

        let cardSize = fitInto(maxDim: 600, naturalSize: image.size)
        let centre = worldPoint ?? screenToWorld(point: viewportCentre)
        let position = CGPoint(
            x: centre.x - cardSize.width  / 2,
            y: centre.y - cardSize.height / 2
        )
        let node = CanvasNode.image(data: data, filename: filename,
                                    position: position, size: cardSize)
        withUndoable {
            nodes.append(node)
        }
        // Mark it so its view plays the wavefront reveal once on appear.
        pendingRevealNodeIDs.insert(node.id)
    }

    /// Add a local video by URL. Lets AVPlayer stream from disk (no decode
    /// into memory). Enforces Figma-style limits:
    ///   • file size ≤ `maxVideoBytes` (100 MB)
    ///   • duration  ≤ `maxVideoDurationSeconds` (4 minutes)
    ///   • each axis ≤ `maxVideoPixelDim` (4096 px)
    func addVideo(fileURL: URL, at worldPoint: CGPoint? = nil) {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= Self.maxVideoBytes else {
            alert = AlertContent(
                title: "Video too large",
                message: "Videos can be up to \(byteString(Self.maxVideoBytes))."
            )
            return
        }

        let asset = AVURLAsset(url: fileURL)
        let duration = CMTimeGetSeconds(asset.duration)
        if duration.isFinite, duration > Self.maxVideoDurationSeconds {
            alert = AlertContent(
                title: "Video too long",
                message: "Videos can be up to \(Int(Self.maxVideoDurationSeconds / 60)) minutes."
            )
            return
        }

        if let track = asset.tracks(withMediaType: .video).first {
            let raw = track.naturalSize.applying(track.preferredTransform)
            let w = abs(raw.width), h = abs(raw.height)
            if w > Self.maxVideoPixelDim || h > Self.maxVideoPixelDim {
                alert = AlertContent(
                    title: "Video resolution too high",
                    message: "Videos can be up to \(Int(Self.maxVideoPixelDim)) × \(Int(Self.maxVideoPixelDim)) px."
                )
                return
            }
        }

        let cardWidth: CGFloat = 480
        let cardHeight: CGFloat = 270
        let centre = worldPoint ?? screenToWorld(point: viewportCentre)
        let position = CGPoint(
            x: centre.x - cardWidth  / 2,
            y: centre.y - cardHeight / 2
        )
        withUndoable {
            nodes.append(.video(fileURL: fileURL,
                                filename: fileURL.lastPathComponent,
                                position: position,
                                size: CGSize(width: cardWidth, height: cardHeight)))
        }
    }

    private func byteString(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func fitInto(maxDim: CGFloat, naturalSize: CGSize) -> CGSize {
        let w = naturalSize.width, h = naturalSize.height
        let scale = min(1, min(maxDim / w, maxDim / h))
        return CGSize(width: w * scale, height: h * scale)
    }

    /// Add an Instagram post / reel / TV node to the canvas.
    func addInstagram(url: String, at worldPoint: CGPoint? = nil,
                      origin: CanvasNode.Origin = .local) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard InstagramService.isLikelyInstagramURL(trimmed),
              InstagramService.parse(trimmed) != nil else {
            alert = AlertContent(
                title: "Not an Instagram URL",
                message: "Paste a link that points at a post or reel, " +
                         "e.g. https://www.instagram.com/p/ABC123/"
            )
            return
        }

        let cardWidth: CGFloat = 360
        let cardHeight = InstagramService.defaultCardHeight(for: trimmed)
        let centre = worldPoint ?? screenToWorld(point: viewportCentre)
        let jitter: CGFloat = worldPoint == nil ? CGFloat.random(in: -40...40) : 0
        let position = CGPoint(
            x: centre.x - cardWidth / 2 + jitter,
            y: centre.y - cardHeight / 2 + jitter
        )

        var node = CanvasNode.instagram(url: trimmed,
                                        position: position,
                                        width: cardWidth,
                                        height: cardHeight)
        node.origin = origin
        withUndoable { nodes.append(node) }
        pendingRevealNodeIDs.insert(node.id)
    }

    func addYouTube(url: String, at worldPoint: CGPoint? = nil,
                    origin: CanvasNode.Origin = .local) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard YouTubeService.isLikelyYouTubeURL(trimmed),
              YouTubeService.videoID(from: trimmed) != nil else {
            alert = AlertContent(
                title: "Not a YouTube URL",
                message: "Paste a link to a YouTube video, e.g. " +
                         "https://youtube.com/watch?v=… or https://youtu.be/…"
            )
            return
        }

        let cardWidth: CGFloat = 360
        let cardHeight = YouTubeService.defaultCardHeight(forWidth: cardWidth)
        let centre = worldPoint ?? screenToWorld(point: viewportCentre)
        let jitter: CGFloat = worldPoint == nil ? CGFloat.random(in: -40...40) : 0
        let position = CGPoint(
            x: centre.x - cardWidth / 2 + jitter,
            y: centre.y - cardHeight / 2 + jitter
        )

        let node = CanvasNode(position: position, width: cardWidth,
                              height: cardHeight, kind: .youtube(url: trimmed),
                              origin: origin)
        withUndoable { nodes.append(node) }
        pendingRevealNodeIDs.insert(node.id)
    }

    // MARK: - iPhone share inbox

    static let incomingPageName = "from my iPhone"
    /// Earlier names this page shipped under — migrated to `incomingPageName`
    /// on load so existing documents pick up the rename + pin.
    static let legacyIncomingPageNames: Set<String> = ["📥 Incoming", "Incoming"]

    /// True when the iPhone inbox page is the active page and still has no
    /// cards — drives the "Send references from your iPhone" empty state.
    var isInboxEmpty: Bool {
        activePage.name == Self.incomingPageName && activePage.nodes.isEmpty
    }
    /// Presents the "set up iPhone sharing" how-to guide sheet.
    @Published var isInboxGuidePresented = false
    private static let k_inboxBookmark = "share.inboxFolderBookmark"

    /// Point the inbox at an iCloud Drive folder (chosen via the folder
    /// picker). Persisted as a bookmark so it survives relaunches.
    func setSharedInboxFolder(_ url: URL) {
        if let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: Self.k_inboxBookmark)
        }
        sharedInboxFolderURL = url
        sharedInbox.start(folderURL: url)
    }

    /// Resolve a previously-chosen inbox folder on launch and start watching.
    private func restoreSharedInboxFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.k_inboxBookmark) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 bookmarkDataIsStale: &stale) else { return }
        sharedInboxFolderURL = url
        sharedInbox.start(folderURL: url)
    }

    /// Sweep the inbox folder once — call on app foreground / launch so
    /// links that arrived while the app was closed get drained.
    func sweepSharedInbox() { sharedInbox.sweepNow() }

    /// Ingest one shared URL from the phone as a card on the "Incoming"
    /// page, badged `.phone`. Unsupported URLs are silently ignored.
    func ingestSharedURL(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardWidth: CGFloat = 360
        var made: CanvasNode?
        if TweetService.isLikelyTweetURL(trimmed), TweetService.extractTweetID(from: trimmed) != nil {
            made = CanvasNode.tweet(url: trimmed, position: .zero, width: cardWidth)
        } else if InstagramService.isLikelyInstagramURL(trimmed), InstagramService.parse(trimmed) != nil {
            made = CanvasNode.instagram(url: trimmed, position: .zero, width: cardWidth,
                                        height: InstagramService.defaultCardHeight(for: trimmed))
        } else if YouTubeService.isLikelyYouTubeURL(trimmed), YouTubeService.videoID(from: trimmed) != nil {
            made = CanvasNode(position: .zero, width: cardWidth,
                              height: YouTubeService.defaultCardHeight(forWidth: cardWidth),
                              kind: .youtube(url: trimmed))
        } else if let u = URL(string: trimmed),
                  let scheme = u.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" {
            // Any other shared link lands as a web-clip card.
            made = CanvasNode.webclip(url: trimmed, position: .zero, width: cardWidth, height: 320)
        }
        guard var node = made else { return }
        node.origin = .phone

        let idx = ensureIncomingPageIndex()
        let slot = pages[idx].nodes.count
        node.position = Self.inboxTilePosition(slot: slot, cardWidth: cardWidth)
        pages[idx].nodes.append(node)
        // Keep the live node index in sync if Incoming is the active page.
        if pages[idx].id == activePageID { nodeByID[node.id] = node }

        let label: String
        switch node.kind {
        case .youtube:   label = "Added a YouTube link from iPhone"
        case .tweet:     label = "Added an X post from iPhone"
        case .instagram: label = "Added an Instagram post from iPhone"
        default:         label = "Added a link from iPhone"
        }
        showToast(label, systemImage: "iphone")
    }

    /// Show a transient toast that auto-dismisses after a few seconds.
    /// A new toast cancels the previous one's dismissal timer.
    func showToast(_ text: String, systemImage: String) {
        toastDismissWork?.cancel()
        withAnimation(.spring(response: 0.40, dampingFraction: 0.82)) {
            toast = ToastContent(text: text, systemImage: systemImage)
        }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: work)
    }

    /// Jump to the Incoming page (from the share toast). No-op if it doesn't
    /// exist yet.
    func goToIncomingPage() {
        toastDismissWork?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = nil }
        if let p = pages.first(where: { $0.name == Self.incomingPageName }) {
            switchTo(pageID: p.id)
        }
    }

    private func ensureIncomingPageIndex() -> Int {
        if let i = pages.firstIndex(where: { $0.name == Self.incomingPageName }) { return i }
        // Create the iPhone inbox pinned so it sits at the top of the sidebar.
        pages.insert(Page(name: Self.incomingPageName, pinned: true), at: 0)
        return 0
    }

    /// One-time migration: an inbox page created under an older name gets
    /// renamed to `incomingPageName`, pinned, and floated to the top. Static
    /// so it can run during `init` before `self` is fully formed.
    private static func migrateIncomingPage(in pages: inout [Page]) {
        if let i = pages.firstIndex(where: { legacyIncomingPageNames.contains($0.name) }) {
            pages[i].name = incomingPageName
            pages[i].pinned = true
        }
        pages = pinnedFirst(pages)
    }

    /// Stable order that floats pinned pages to the top while preserving the
    /// relative order within each group.
    private static func pinnedFirst(_ pages: [Page]) -> [Page] {
        pages.enumerated().sorted { a, b in
            if a.element.pinned != b.element.pinned { return a.element.pinned }
            return a.offset < b.offset
        }.map { $0.element }
    }

    /// Re-float pinned pages to the top (after a pin toggle or rename).
    func sortPagesByPinned() {
        let ordered = Self.pinnedFirst(pages)
        if !ordered.elementsEqual(pages, by: { $0.id == $1.id }) { pages = ordered }
    }

    /// Toggle a page's pinned state and re-float. The active page is tracked
    /// by id, so reordering never loses the user's place.
    func togglePin(_ id: UUID) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[i].pinned.toggle()
        sortPagesByPinned()
    }

    /// Simple 3-column grid so a burst of shares doesn't pile on one spot.
    private static func inboxTilePosition(slot: Int, cardWidth: CGFloat) -> CGPoint {
        let columns = 3
        let gap: CGFloat = 32
        let col = slot % columns
        let row = slot / columns
        return CGPoint(x: 80 + CGFloat(col) * (cardWidth + gap),
                       y: 80 + CGFloat(row) * (420 + gap))
    }

    // MARK: - Keyboard card navigation (N / ⇧N) + open source

    /// Select and frame the next (or previous) card, Figma-style. Cards are
    /// visited in spatial reading order — top-to-bottom, then left-to-right
    /// — and the camera animates to frame each via `zoomToSelection`. Wraps
    /// around at the ends. Sections are skipped (they're containers, not
    /// cards). Canvas-mode only.
    func selectNextNode(reverse: Bool = false) {
        guard canvasMode == .canvas else { return }
        let ordered = activePage.nodes
            .filter { !$0.isSection }
            .sorted { a, b in
                if abs(a.position.y - b.position.y) > 1 { return a.position.y < b.position.y }
                return a.position.x < b.position.x
            }
        guard !ordered.isEmpty else { return }

        let currentID = selectedNodeIDs.count == 1 ? selectedNodeIDs.first : nil
        let currentIdx = currentID.flatMap { id in ordered.firstIndex(where: { $0.id == id }) }
        let nextIdx: Int
        if let i = currentIdx {
            nextIdx = reverse ? (i - 1 + ordered.count) % ordered.count
                              : (i + 1) % ordered.count
        } else {
            nextIdx = reverse ? ordered.count - 1 : 0
        }
        select(ordered[nextIdx].id)
        zoomToSelection()
    }

    /// Open the source URL(s) of the selected card(s) — tweet / Instagram /
    /// YouTube — in the default browser. Toasts if the selection has no link.
    func openSelectedSource() {
        let urls: [URL] = selectedNodeIDs.compactMap { id -> URL? in
            guard let node = nodeByID[id] else { return nil }
            let s: String?
            switch node.kind {
            case .tweet(let u), .instagram(let u), .youtube(let u): s = u
            default: s = nil
            }
            return s.flatMap { URL(string: $0) }
        }
        guard !urls.isEmpty else {
            showToast("No source link on the selected card", systemImage: "link.slash")
            return
        }
        for url in urls.prefix(12) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Card lightbox (double-click theater view + details inspector)

    /// Set for the WHOLE lightbox session — from open, through the close
    /// animation, until it fully finishes. The on-canvas card hides exactly
    /// while this == its id, so the source is hidden the entire time the hero
    /// is on screen (Apple Photos: the thumbnail reappears only when the
    /// dismiss completes — never a duplicate mid-flight).
    @Published var lightboxCardID: UUID?

    /// True while the lightbox is animating CLOSED (still mounted). The view
    /// watches this to run the shrink, then calls `finalizeLightboxClose`.
    @Published var lightboxClosing = false

    /// The video card currently in inline trim mode (exclusive). While set,
    /// `DraggableNode` suppresses that card's drag so the timeline handles can
    /// be dragged without moving the card.
    @Published var trimmingCardID: UUID?

    /// The on-screen (window-global) rect of the card the lightbox was opened
    /// from — origin/destination of the grow/shrink. matchedGeometryEffect
    /// can't animate across the split-view→overlay boundary here, so we measure
    /// the rect ourselves and drive an explicit transform. Plain stored values
    /// (read during layout, not observed) so they never trigger re-renders.
    var lightboxSourceRect: CGRect?
    /// Window-global frame of the canvas camera container (the ZStack the
    /// camera offset is relative to); written by `CanvasView`.
    var canvasViewFrame: CGRect = .zero

    /// Window-global rect of a node as it currently appears on the canvas,
    /// accounting for the live camera (pan + zoom).
    func screenRect(of node: CanvasNode) -> CGRect? {
        guard canvasViewFrame != .zero else { return nil }
        let z = camera.zoom
        let p = effectivePosition(of: node)
        return CGRect(x: canvasViewFrame.minX + p.x * z + camera.x,
                      y: canvasViewFrame.minY + p.y * z + camera.y,
                      width: node.width * z,
                      height: renderedHeight(of: node) * z)
    }

    /// Single spring the view uses to drive the grow/shrink progress. Smooth,
    /// barely-damped (Photos-like, minimal bounce). Quick fade under Reduce
    /// Motion. `lightboxCloseDuration` must cover its visual settle.
    private var lightboxReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    var lightboxHeroAnimation: Animation {
        lightboxReduceMotion ? .easeOut(duration: 0.16)
                             : .spring(response: 0.40, dampingFraction: 0.9)
    }
    /// How long to keep the layer mounted after a close is requested, before
    /// finalizing (≈ the spring's visual settle). Kept short under Reduce Motion.
    var lightboxCloseDuration: TimeInterval { lightboxReduceMotion ? 0.18 : 0.5 }

    /// Active-page cards in spatial reading order — drives lightbox ← →
    /// navigation and the "i / N" counter. Sections are excluded.
    var lightboxOrder: [UUID] {
        activePage.nodes
            .filter { !$0.isSection }
            .sorted { a, b in
                if abs(a.position.y - b.position.y) > 1 { return a.position.y < b.position.y }
                return a.position.x < b.position.x
            }
            .map(\.id)
    }

    /// Bumped on every open so the hero view re-drives its grow animation
    /// even when the layer never unmounted — reopening during the closing
    /// shrink used to leave the hero with stale progress/landed state
    /// (and on macOS 27 the re-entrant hero could trip AppKit's
    /// layout-recursion trap).
    @Published private(set) var lightboxGeneration = 0

    func openLightbox(_ id: UUID) {
        guard let node = nodeByID[id] else { return }
        // The hero grows out of the card's measured on-screen rect — stop
        // any camera coast/glide so the measurement (and the later shrink
        // target) stays truthful while the hero animates.
        cancelPanInertia()
        // Measure the card's on-screen rect now; the hero grows out of it.
        // The grow itself is animated by the view (progress 0→1).
        lightboxSourceRect = screenRect(of: node)
        lightboxClosing = false
        lightboxCardID = id
        lightboxGeneration &+= 1
    }

    /// Begin the close. The card stays mounted (and the on-canvas original
    /// stays hidden) while the view shrinks it; `finalizeLightboxClose` then
    /// unmounts it — so the original reappears exactly as the hero vanishes.
    func closeLightbox() {
        guard lightboxCardID != nil, !lightboxClosing else { return }
        lightboxClosing = true
    }

    /// Called by the view once the shrink animation has run its course.
    func finalizeLightboxClose() {
        guard lightboxClosing else { return }   // a reopen during close cancels it
        lightboxCardID = nil
        lightboxClosing = false
    }

    /// Step prev (-1) / next (+1) through `lightboxOrder`, wrapping around.
    func lightboxStep(_ delta: Int) {
        let order = lightboxOrder
        guard !order.isEmpty, let cur = lightboxCardID,
              let i = order.firstIndex(of: cur) else { return }
        let n = order.count
        lightboxCardID = order[((i + delta) % n + n) % n]
    }

    /// 1-based index + total for the lightbox counter ("2 / 7").
    var lightboxPosition: (index: Int, total: Int)? {
        let order = lightboxOrder
        guard let cur = lightboxCardID, let i = order.firstIndex(of: cur) else { return nil }
        return (i + 1, order.count)
    }

    // Inspector field edits — mutate the node in place; `$pages` autosaves.
    func setNodeName(_ id: UUID, _ value: String) {
        updateNode(id) { $0.name = value.isEmpty ? nil : value }
    }
    func setNodeNote(_ id: UUID, _ value: String) {
        updateNode(id) { $0.note = value.isEmpty ? nil : value }
    }
    func setNodeLinkURL(_ id: UUID, _ value: String) {
        updateNode(id) { $0.linkURL = value.isEmpty ? nil : value }
    }

    // MARK: - Video trim (non-destructive)

    /// Set the loop range (seconds) for a video card; the player loops only
    /// `[start, end]`. Autosaves via `$pages`. Undoable — ⌘Z restores the
    /// previous range like every other card mutation.
    func setTrim(_ id: UUID, start: Double, end: Double) {
        withUndoable {
            updateNode(id) { $0.trimStart = start; $0.trimEnd = end }
        }
    }
    /// Clear the trim — the card loops the full clip again. Undoable.
    func clearTrim(_ id: UUID) {
        withUndoable {
            updateNode(id) { $0.trimStart = nil; $0.trimEnd = nil }
        }
    }

    private func updateNode(_ id: UUID, _ mutate: (inout CanvasNode) -> Void) {
        guard let idx = activePage.nodes.firstIndex(where: { $0.id == id }) else { return }
        var n = activePage.nodes[idx]
        mutate(&n)
        pages[activePageIndex].nodes[idx] = n
        nodeByID[id] = n
    }

    // MARK: - Lightbox inspector: source URL, page, tags, prompt

    /// Effective source link for a node — the embedded post URL, or the
    /// manually-entered `linkURL`.
    func sourceURL(of node: CanvasNode) -> String? {
        switch node.kind {
        case .tweet(let u), .instagram(let u), .youtube(let u): return u
        default: return node.linkURL
        }
    }

    /// Name of the page that contains this card (cards live on one page).
    func pageName(forCard id: UUID) -> String? {
        pages.first(where: { $0.nodes.contains(where: { $0.id == id }) })?.name
    }

    func setNodeImagePrompt(_ id: UUID, _ value: String) {
        updateNode(id) { $0.imagePrompt = value.isEmpty ? nil : value }
    }

    func addTag(_ id: UUID, _ raw: String) {
        let t = Self.normalizeTag(raw)
        guard !t.isEmpty else { return }
        updateNode(id) { if !$0.tags.contains(t) { $0.tags.append(t) } }
    }

    func removeTag(_ id: UUID, _ tag: String) {
        updateNode(id) { $0.tags.removeAll { $0 == tag } }
    }

    /// Heuristic auto-tagger (no AI): derives tags from kind, source
    /// domain, dominant color, and aspect; dedup-merges into `node.tags`.
    func autoTag(_ id: UUID) {
        guard let node = nodeByID[id] else { return }
        var derived: [String] = []
        switch node.kind {
        case .image:      derived.append("image")
        case .video:      derived.append("video")
        case .tweet:      derived += ["tweet", "x"]
        case .instagram:  derived.append("instagram")
        case .youtube:    derived += ["youtube", "video"]
        case .webclip:    derived += ["web", "link"]
        case .text:       derived.append("text")
        case .stickyNote: derived.append("note")
        case .drawing:    derived.append("drawing")
        case .section:    break
        case .folder:     derived.append("folder")
        }
        if let host = sourceURL(of: node).flatMap({ URL(string: $0)?.host })?
            .replacingOccurrences(of: "www.", with: ""),
           !["x.com", "twitter.com", "youtube.com", "youtu.be", "instagram.com"].contains(host) {
            derived.append(String(host.split(separator: ".").first ?? Substring(host)))
        }
        if case .image = node.kind,
           let c = PaletteExtractor.colors(for: node, count: 4).first {
            derived.append(PaletteExtractor.colorName(c))
        }
        let h = renderedHeight(of: node)
        if node.width > 1, h > 1 {
            let r = node.width / h
            derived.append(r > 1.2 ? "landscape" : (r < 0.83 ? "portrait" : "square"))
        }
        updateNode(id) { n in
            for t in derived.map(Self.normalizeTag) where !t.isEmpty && !n.tags.contains(t) {
                n.tags.append(t)
            }
        }
    }

    private static func normalizeTag(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Heuristic image-prompt synthesis (no AI) from kind + colors +
    /// orientation + source/name/text.
    func generatePrompt(for node: CanvasNode) -> String {
        let aspect: String = {
            let h = renderedHeight(of: node)
            guard node.width > 1, h > 1 else { return "square" }
            let r = node.width / h
            return r > 1.2 ? "landscape" : (r < 0.83 ? "portrait" : "square")
        }()
        switch node.kind {
        case .image:
            let names = uniqueOrdered(PaletteExtractor.colors(for: node, count: 4)
                                        .map(PaletteExtractor.colorName))
            let palette = names.isEmpty ? "" : " in \(listPhrase(names)) tones"
            let subject = (node.name?.isEmpty == false) ? node.name! : "an abstract composition"
            return "A \(aspect) image of \(subject)\(palette), high detail, soft natural light."
        case .tweet(let u):
            let handle = URL(string: u)?.path.split(separator: "/").first
                .map { "@\($0)" } ?? "a user"
            return "Screenshot of an X post by \(handle), clean UI, crisp legible typography."
        case .instagram:
            return "An Instagram post, square crop, vibrant social-media aesthetic."
        case .youtube:
            return "A YouTube thumbnail, bold focal subject, high contrast, punchy color."
        case .webclip:
            return "A web page screenshot, clean readable layout, informative content."
        case .video:
            return "A \(aspect) video still, cinematic lighting, gentle natural motion."
        case .text(let content, _):
            return "Editorial typographic layout featuring: \u{201C}\(content.prefix(60))\u{201D}."
        case .stickyNote(let content, _):
            return "A handwritten sticky note reading: \u{201C}\(content.prefix(60))\u{201D}."
        case .drawing:
            return "A loose freehand ink sketch, minimal expressive line art."
        case .section:
            return "A labeled grouping frame."
        case .folder:
            return "A folder holding a set of saved items."
        }
    }

    private func uniqueOrdered(_ arr: [String]) -> [String] {
        var seen = Set<String>(); return arr.filter { seen.insert($0).inserted }
    }
    private func listPhrase(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }

    // MARK: - Text creation / editing

    /// Create a text node at the given world position and put it straight into
    /// edit mode. If `worldPoint` is nil, place at viewport centre.
    @discardableResult
    func addText(at worldPoint: CGPoint? = nil) -> UUID {
        let position = worldPoint ?? {
            let c = screenToWorld(point: viewportCentre)
            return CGPoint(x: c.x - 120, y: c.y - 14)
        }()
        let node = CanvasNode.text(content: "", position: position)
        withUndoable { nodes.append(node) }
        pendingFocusNodeID = node.id
        select(node.id)
        toolMode = .select
        return node.id
    }

    func updateText(id: UUID, content: String) {
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
            if case .text(_, let fontSize) = nodes[idx].kind {
                nodes[idx].kind = .text(content: content, fontSize: fontSize)
            }
        }
        if pendingFocusNodeID == id { pendingFocusNodeID = nil }
    }

    // MARK: - Sticky notes

    /// Create a 200×200 sticky at the given world point (or viewport
    /// centre when `nil`) and immediately auto-focus its editor — same
    /// pattern as `addText`.
    @discardableResult
    func addStickyNote(at worldPoint: CGPoint? = nil) -> UUID {
        let size = CGSize(width: 200, height: 200)
        let position: CGPoint = {
            if let p = worldPoint {
                return CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2)
            }
            let c = screenToWorld(point: viewportCentre)
            return CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
        }()
        let node = CanvasNode.stickyNote(position: position, size: size)
        withUndoable { nodes.append(node) }
        pendingFocusNodeID = node.id
        select(node.id)
        toolMode = .select
        return node.id
    }

    func setStickyContent(id: UUID, to content: String) {
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
            if case .stickyNote(_, let color) = nodes[idx].kind {
                nodes[idx].kind = .stickyNote(content: content, color: color)
            }
        }
    }

    func setStickyColor(id: UUID, to color: StickyColor) {
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
            if case .stickyNote(let content, _) = nodes[idx].kind {
                nodes[idx].kind = .stickyNote(content: content, color: color)
            }
        }
    }

    // MARK: - Sections

    /// Create a section frame covering the given world rect. Returns its
    /// id so callers can put the title field straight into edit mode.
    ///
    /// Sections always render below cards (enforced by `CanvasView`'s
    /// sections-first / cards-second render pass). Within the section
    /// sub-array, normal array order = z-order, so appending puts the
    /// new section on top of older sections — matching Figma's "newest
    /// frame on top" convention.
    @discardableResult
    func addSection(rect: CGRect, title: String = "", color: SectionColor = .slate) -> UUID {
        let node = CanvasNode.section(title: title, color: color, rect: rect)
        withUndoable { nodes.append(node) }
        select(node.id)
        toolMode = .select
        return node.id
    }

    // MARK: - Card-stack grouping (⌘G / ⌘⇧G)

    /// Animated collapse: every non-head member spring-glides to the
    /// head's position with a small per-card stagger, then the
    /// `groupID` assignment lands and the stack visual takes over.
    /// One undo entry covers the full sequence so ⌘Z restores every
    /// original position in a single hop.
    ///
    /// The "head" of the group — the only member that renders on the
    /// canvas once the animation completes — is the node with the
    /// smallest UUID string within the set. Non-head members stay in
    /// `nodes` (so undo + Codable + drag-translation continue to work)
    /// but are hidden from rendering by `isHiddenByStack(_:)` once
    /// their `groupID` is set.
    @discardableResult
    func groupSelection() -> UUID? {
        // Ignore sections + already-grouped nodes; require at least two
        // candidates for a group to make sense.
        let candidates = selectedNodeIDs.compactMap { id -> CanvasNode? in
            guard let n = nodeByID[id], !n.isSection, n.groupID == nil else { return nil }
            return n
        }
        guard candidates.count >= 2 else { return nil }
        showToast("Grouped \(candidates.count) cards", systemImage: "square.stack.3d.up")
        let newGroupID = UUID()
        let head = candidates.min { $0.id.uuidString < $1.id.uuidString }!
        let headPos = head.position
        // Non-head members ordered by initial distance from the head:
        // closer cards arrive first, far cards trail. Makes the deck
        // assemble visibly rather than teleport.
        let movers = candidates
            .filter { $0.id != head.id }
            .sorted { lhs, rhs in
                let dl = hypot(lhs.position.x - headPos.x, lhs.position.y - headPos.y)
                let dr = hypot(rhs.position.x - headPos.x, rhs.position.y - headPos.y)
                return dl < dr
            }

        let before = snapshotForUndo()
        // Stage 1 — spring-glide each non-head member to the head's
        // position, with a 30ms stagger per index. Members remain
        // visible during this phase (their `groupID` is still nil),
        // so the user sees the cards physically converge.
        let stagger: Double = 0.03
        let springResponse: Double = 0.55
        let springDamping: Double = 0.82
        for (i, mover) in movers.enumerated() {
            let delay = Double(i) * stagger
            withAnimation(
                .spring(response: springResponse,
                        dampingFraction: springDamping)
                    .delay(delay)
            ) {
                self.updatePosition(of: mover.id, to: headPos)
            }
        }
        // Stage 2 — once the longest stagger + spring is done, stamp
        // the `groupID` on every member. The non-head ones now disappear
        // (filtered out of `visibleNodes`) and the head's StackVisualView
        // ghost layer takes over. Single undoable wraps stage 1 + 2 via
        // the snapshot captured before stage 1.
        let totalDuration = Double(max(0, movers.count - 1)) * stagger + springResponse
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration) { [weak self] in
            guard let self else { return }
            for c in candidates {
                self.mutateNode(c.id) { node in
                    node.groupID = newGroupID
                }
            }
            // Threshold haptic — the deck has just *formed*.
            Haptics.threshold()
            self.commitUndoable(from: before)
        }
        // Selection should immediately track the visible representative
        // (the head) — the stack-classifier and Smart Selection both
        // observe `selectedNodeIDs` and need to react before stage 2.
        select(head.id)
        return newGroupID
    }

    /// Animated eruption: clear every member's `groupID` first (so they
    /// re-appear at the head's position — they all share `headPos` while
    /// grouped), then spring-fly outward to a fan formation with a
    /// staggered cascade. The deck "explodes" outward last-in-first-out.
    /// One undo entry covers the full sequence.
    func ungroupSelection() {
        // Collect every distinct group implicated by the current selection.
        var groups = Set<UUID>()
        for id in selectedNodeIDs {
            if let g = nodeByID[id]?.groupID { groups.insert(g) }
        }
        guard !groups.isEmpty else { return }
        showToast(
            groups.count == 1 ? "Ungrouped stack" : "Ungrouped \(groups.count) stacks",
            systemImage: "square.stack.3d.down.right"
        )

        let before = snapshotForUndo()
        var released = Set<UUID>()
        // Stage 0 — collect per-group member lists + fan targets *before*
        // mutating anything, so the per-card stagger uses the correct
        // pre-mutation member ordering.
        struct FanPlan {
            let id: UUID
            let target: CGPoint
        }
        var plans: [FanPlan] = []
        let step: CGFloat = 32   // a bit wider than the old 24pt for a snappier fan
        for group in groups {
            let members = nodes
                .filter { $0.groupID == group }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            guard let head = members.first else { continue }
            let anchor = head.position
            for (i, m) in members.enumerated() {
                if m.id == head.id {
                    plans.append(FanPlan(id: m.id, target: anchor))
                } else {
                    plans.append(FanPlan(
                        id: m.id,
                        target: CGPoint(
                            x: anchor.x + CGFloat(i) * step,
                            y: anchor.y + CGFloat(i) * step
                        )
                    ))
                }
                released.insert(m.id)
            }
        }

        // Stage 1 — clear every `groupID` synchronously. Hidden members
        // become visible again at the head's stacked-up position. This
        // is the "explosion start" frame; from here the spring carries
        // each card outward.
        for plan in plans {
            mutateNode(plan.id) { node in
                node.groupID = nil
            }
        }

        // Stage 2 — staggered spring outward. Closer-to-head cards (low
        // index) fire first; outer cards trail. Feels like the deck
        // erupts last-in-first-out.
        let stagger: Double = 0.03
        let springResponse: Double = 0.55
        let springDamping: Double = 0.82
        for (i, plan) in plans.enumerated() {
            withAnimation(
                .spring(response: springResponse,
                        dampingFraction: springDamping)
                    .delay(Double(i) * stagger)
            ) {
                self.updatePosition(of: plan.id, to: plan.target)
            }
        }

        // Stage 3 — finalize: commit undo + threshold haptic on settle.
        let totalDuration = Double(max(0, plans.count - 1)) * stagger + springResponse
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration) { [weak self] in
            guard let self else { return }
            Haptics.threshold()
            self.commitUndoable(from: before)
        }

        // Selection updates immediately so the chrome reflects the new
        // member set (the loose cards) without waiting for stage 3.
        selectNodes(released)
    }

    /// Is this node the head of its stack (smallest UUID in the group)?
    /// Non-grouped nodes return false.
    func isStackHead(_ id: UUID) -> Bool {
        guard let node = nodeByID[id], node.groupID != nil else { return false }
        return stackMembers(of: id).first == id
    }

    /// Is this node hidden from rendering because it's a non-head
    /// member of a stack? Non-grouped nodes return false.
    /// **Focus-mode exception**: while the user is browsing a stack
    /// in focus mode, every member of THAT stack is rendered (at
    /// their `focusPositions` grid slots), so non-head members of
    /// the focused stack are un-hidden.
    func isHiddenByStack(_ id: UUID) -> Bool {
        guard let node = nodeByID[id], let group = node.groupID else { return false }
        if focusedStackID != nil, focusedStackID == group {
            return false
        }
        return !isStackHead(id)
    }

    /// Number of nodes in the current selection that are eligible for
    /// `groupSelection()` (i.e. non-section, not already grouped).
    /// `Edit ▸ Group (⌘G)` is enabled when this is ≥ 2.
    var groupableSelectionCount: Int {
        selectedNodeIDs.reduce(0) { acc, id in
            guard let n = nodeByID[id], !n.isSection, n.groupID == nil else { return acc }
            return acc + 1
        }
    }

    /// True if any node in the current selection belongs to a card-stack.
    /// `Edit ▸ Ungroup (⌘⇧G)` is enabled when this is true.
    var selectionHasGroupedNode: Bool {
        selectedNodeIDs.contains { nodeByID[$0]?.groupID != nil }
    }

    /// Apple-style auto-derived group name for the stack whose head
    /// is `headID`. Mirrors how Photos / Files surface collections —
    /// "N photos" when all members share a kind, "N items" for mixed
    /// stacks. Returns `nil` for non-stack nodes so callers can gate
    /// their label rendering with one optional check.
    func groupName(forHead headID: UUID) -> String? {
        guard isStackHead(headID) else { return nil }
        let memberIDs = stackMembers(of: headID)
        guard !memberIDs.isEmpty else { return nil }
        let members = memberIDs.compactMap { nodeByID[$0] }
        let count = members.count
        // Single-kind detection — if every member matches one of the
        // major content categories, we use a content-specific noun.
        let allVideos    = members.allSatisfy { if case .video    = $0.kind { return true }; return false }
        let allImages    = members.allSatisfy { if case .image    = $0.kind { return true }; return false }
        let allTweets    = members.allSatisfy { if case .tweet    = $0.kind { return true }; return false }
        let allInsta     = members.allSatisfy { if case .instagram = $0.kind { return true }; return false }
        let allText      = members.allSatisfy { if case .text     = $0.kind { return true }; return false }
        let allStickies  = members.allSatisfy { if case .stickyNote = $0.kind { return true }; return false }
        let allDrawings  = members.allSatisfy { if case .drawing  = $0.kind { return true }; return false }
        let label: String
        switch true {
        case allVideos:   label = count == 1 ? "Video"   : "\(count) Videos"
        case allImages:   label = count == 1 ? "Photo"   : "\(count) Photos"
        case allTweets:   label = count == 1 ? "Tweet"   : "\(count) Tweets"
        case allInsta:    label = count == 1 ? "Post"    : "\(count) Posts"
        case allText:     label = count == 1 ? "Note"    : "\(count) Notes"
        case allStickies: label = count == 1 ? "Sticky"  : "\(count) Stickies"
        case allDrawings: label = count == 1 ? "Sketch"  : "\(count) Sketches"
        default:          label = count == 1 ? "Item"    : "\(count) Items"
        }
        return label
    }

    /// Every member of the stack the given node belongs to, in head-first
    /// (uuid-ascending) order. Returns `[]` for non-grouped nodes.
    func stackMembers(of id: UUID) -> [UUID] {
        guard let node = nodeByID[id], let group = node.groupID else { return [] }
        return nodes
            .filter { $0.groupID == group }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// Expand a selection set to include every member of any card-stack
    /// referenced (by the head OR a hidden member) in the input. Used by:
    ///   • `DraggableNode.applyTranslation` — so the whole stack drags
    ///     together when the head moves.
    ///   • `removeNodesAndCascade` — so deleting a stack takes its hidden
    ///     members with it, not orphaning them with a dangling `groupID`.
    ///   • `duplicateNodes` — so duplicating a stack clones every member.
    /// The expansion is one-shot: once a group is included, the resulting
    /// set is closed under "share groupID."
    func expandedDragSet(from selection: Set<UUID>) -> Set<UUID> {
        var out = selection
        var seenGroups = Set<UUID>()
        for id in selection {
            guard let groupID = nodeByID[id]?.groupID,
                  !seenGroups.contains(groupID) else { continue }
            seenGroups.insert(groupID)
            for member in nodes where member.groupID == groupID {
                out.insert(member.id)
            }
        }
        return out
    }

    // MARK: - Stack focus mode (double-click on a stack)

    /// Enter focus mode for the stack that `headID` belongs to.
    /// Computes a Photos-style grid layout (via `StackFocusEngine`),
    /// snapshots the camera so exit can restore it, and animates
    /// every member from the stack's anchor position out to its
    /// computed grid slot. No-op if the node isn't a stack head.
    func enterStackFocus(headID: UUID) {
        guard let head = nodeByID[headID],
              let groupID = head.groupID,
              isStackHead(headID) else { return }
        let members = stackMembers(of: headID)
        guard members.count >= 2 else { return }

        // Focus choreographs the camera — stop any coast/glide first,
        // and snapshot the *resting* camera for the exit restore.
        cancelPanInertia()
        focusOriginCamera = cameraStore.camera

        // Compute the grid layout in viewport coords. The viewport's
        // natural canvas-space size is the world-space rectangle the
        // user sees at zoom 1.0 — we'll animate the camera to that
        // zoom so the grid uses real world coords directly.
        let layout = StackFocusEngine.layout(
            memberIDs: members,
            state: self,
            viewportSize: viewportSize
        )

        // Wrap the geometry mutations + camera reset in one spring so
        // every member visibly springs from its stack-anchor position
        // out to its grid slot in a single coordinated animation.
        withAnimation(Motion.structure) {
            self.focusedStackID = groupID
            self.focusPositions = layout.positions
            self.focusSizes     = layout.sizes
            // Camera to neutral so the focus chrome can position
            // itself in raw viewport coords without zoom skew.
            self.cameraStore.camera = Camera(x: 0, y: 0, zoom: 1.0)
        }
        // Tap haptic — focus engaged.
        Haptics.tap()
    }

    /// Exit focus mode. Cards spring back toward the stack head's
    /// anchor position (so they re-pile into the deck), the camera
    /// restores its pre-focus state, and the overlay chrome dismisses.
    func exitStackFocus() {
        guard focusedStackID != nil else { return }
        cancelPanInertia()   // the restore owns the camera from here
        let restoreCamera = focusOriginCamera ?? cameraStore.camera
        // Animate the dismissal — same spring as entry for symmetry.
        withAnimation(Motion.structure) {
            self.focusedStackID = nil
            self.focusPositions = [:]
            self.focusSizes = [:]
            self.cameraStore.camera = restoreCamera
        }
        focusOriginCamera = nil
        Haptics.tap()
    }

    /// Wrap the current selection in a new section that geographically
    /// contains every selected node. The section "owns" them via the
    /// existing spatial-containment model: dragging the header moves
    /// them as a unit, deleting it cascade-deletes them. One undo entry.
    @discardableResult
    func wrapSelectionInSection(color: SectionColor = .slate) -> UUID? {
        guard !selectedNodeIDs.isEmpty,
              let bounds = boundingRect(of: selectedNodeIDs) else { return nil }
        // Side padding gives the section a visible margin around the
        // contents; header overhead reserves room above for the 28pt
        // title bar so it doesn't crowd the topmost cards.
        let sidePadding: CGFloat = 32
        let headerOverhead: CGFloat = 48
        let rect = CGRect(
            x: bounds.minX - sidePadding,
            y: bounds.minY - headerOverhead,
            width:  bounds.width  + sidePadding * 2,
            height: bounds.height + headerOverhead + sidePadding
        )
        return addSection(rect: rect, color: color)
    }

    func setSectionTitle(id: UUID, to title: String) {
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
            if case .section(_, let color) = nodes[idx].kind {
                nodes[idx].kind = .section(title: title, color: color)
            }
        }
    }

    func setSectionColor(id: UUID, to color: SectionColor) {
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
            if case .section(let title, _) = nodes[idx].kind {
                nodes[idx].kind = .section(title: title, color: color)
            }
        }
    }

    /// World rect of a section node by id, or nil if not a section.
    func sectionRect(of id: UUID) -> CGRect? {
        guard let n = nodeByID[id], n.isSection else { return nil }
        return CGRect(x: n.position.x, y: n.position.y,
                      width: n.width,
                      height: n.height ?? renderedHeight(of: n))
    }

    /// IDs of non-section nodes whose centre lies within the given world
    /// rect. Used so dragging or deleting a section also moves/deletes
    /// its contents as a unit.
    func nodeIDs(insideWorldRect rect: CGRect) -> Set<UUID> {
        var hits: Set<UUID> = []
        for n in nodes where !n.isSection {
            let h = renderedHeight(of: n)
            let cx = n.position.x + n.width / 2
            let cy = n.position.y + h / 2
            if rect.contains(CGPoint(x: cx, y: cy)) {
                hits.insert(n.id)
            }
        }
        return hits
    }

    // MARK: - Drawing

    /// Convert a screen-space stroke into a drawing node (in world coords).
    func commitStroke(screenPoints: [CGPoint]) {
        guard screenPoints.count >= 2 else { return }
        let world = screenPoints.map { screenToWorld(point: $0) }
        let simplified = PathMath.simplify(world, epsilon: 1.5)
        let pad = drawWidth + 4
        let bounds = PathMath.paddedBounds(of: simplified, pad: pad)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let local = simplified.map { CGPoint(x: $0.x - bounds.minX,
                                              y: $0.y - bounds.minY) }
        let stroke = DrawingStroke(points: local, color: drawColor, width: drawWidth)

        withUndoable {
            nodes.append(.drawing(stroke: stroke,
                                  position: bounds.origin,
                                  size: bounds.size))
        }
    }

    // MARK: - Selection / deletion

    /// Select exactly one node (or clear if nil). Always clears connector selection.
    func select(_ id: UUID?) {
        selectedNodeIDs = id.map { [$0] } ?? []
        selectedConnectorIDs = []
    }

    /// Reveal a node from anywhere (⌘K search, Outline list): switch to its
    /// page if needed, then centre + select it. When a page switch happens
    /// the center/select runs on the next main-actor turn, after `switchTo`
    /// has rebuilt `nodeByID` and cleared the old selection.
    func jumpToNode(_ nodeID: UUID, onPage pageID: UUID) {
        if pageID != activePageID {
            if canvasMode != .canvas { setMode(.canvas) }
            switchTo(pageID: pageID)
            Task { @MainActor in self.frameAndSelect(nodeID) }
        } else {
            if canvasMode != .canvas { setMode(.canvas) }
            frameAndSelect(nodeID)
        }
    }

    private func frameAndSelect(_ nodeID: UUID) {
        guard let n = nodeByID[nodeID] else { return }
        let centre = CGPoint(x: n.position.x + n.width / 2,
                             y: n.position.y + renderedHeight(of: n) / 2)
        centerCamera(on: centre)
        select(nodeID)
    }

    /// Replace selection with the given set of node ids.
    func selectNodes(_ ids: Set<UUID>) {
        selectedNodeIDs = ids
        selectedConnectorIDs = []
    }

    /// Toggle a node in/out of the current selection (Shift+click semantics).
    func toggleNodeSelection(_ id: UUID) {
        if selectedNodeIDs.contains(id) {
            selectedNodeIDs.remove(id)
        } else {
            selectedNodeIDs.insert(id)
            selectedConnectorIDs = []
        }
    }

    /// Select exactly one connector (or clear). Always clears node selection.
    func selectConnector(_ id: UUID?) {
        selectedConnectorIDs = id.map { [$0] } ?? []
        selectedNodeIDs = []
    }

    func toggleConnectorSelection(_ id: UUID) {
        if selectedConnectorIDs.contains(id) {
            selectedConnectorIDs.remove(id)
        } else {
            selectedConnectorIDs.insert(id)
            selectedNodeIDs = []
        }
    }

    func deselectAll() {
        selectedNodeIDs = []
        selectedConnectorIDs = []
    }

    func selectAll() {
        selectedNodeIDs = Set(nodes.map { $0.id })
        selectedConnectorIDs = []
    }

    /// Convert a screen-space rectangle to world coords and select every
    /// node whose rectangle intersects it. Used at the end of a marquee
    /// drag (or any one-shot call site); the live in-flight version is
    /// `liveSelectInMarquee(screenRect:base:additive:)`.
    func selectNodesIn(screenRect: CGRect, additive: Bool) {
        let hits = nodeIDs(intersectingScreenRect: screenRect)
        if additive {
            selectedNodeIDs.formUnion(hits)
        } else {
            selectedNodeIDs = hits
            selectedConnectorIDs = []
        }
    }

    /// Live (per-tick) marquee selection. `base` is the user's selection
    /// at the moment the drag began; on every tick the result is either
    /// `base ∪ hits` (shift held) or just `hits` (no modifier) — so
    /// shrinking the marquee past a node correctly deselects it.
    func liveSelectInMarquee(screenRect: CGRect,
                             base: Set<UUID>,
                             additive: Bool) {
        let hits = nodeIDs(intersectingScreenRect: screenRect)
        selectedNodeIDs = additive ? base.union(hits) : hits
        selectedConnectorIDs = []
    }

    /// Find every node whose world rect intersects the given screen-space
    /// rect. Single source of truth for marquee hit-tests.
    private func nodeIDs(intersectingScreenRect rect: CGRect) -> Set<UUID> {
        let z = camera.zoom
        guard z > 0 else { return [] }
        let world = CGRect(
            x: (rect.minX - camera.x) / z,
            y: (rect.minY - camera.y) / z,
            width:  rect.width  / z,
            height: rect.height / z
        )
        return Set(nodes.compactMap { node in
            let r = CGRect(x: node.position.x, y: node.position.y,
                           width: node.width, height: renderedHeight(of: node))
            return world.intersects(r) ? node.id : nil
        })
    }

    func delete(id: UUID) {
        removeNodesAndCascade([id], extraConnectorIDs: [])
    }

    func deleteConnector(id: UUID) {
        withUndoable {
            connectors.removeAll { $0.id == id }
        }
        selectedConnectorIDs.remove(id)
    }

    /// Remove every selected node and connector in one pass — coalesced
    /// into a single undo entry via re-entrant `withUndoable`.
    func deleteSelected() {
        removeNodesAndCascade(selectedNodeIDs, extraConnectorIDs: selectedConnectorIDs)
    }

    /// Single removal pipeline used by `delete(id:)` and `deleteSelected`.
    /// Expands the seed set with any contents of selected sections, every
    /// member of a referenced card-stack, drops dangling connectors, and
    /// clears transient per-node state — all in one undo entry.
    private func removeNodesAndCascade(_ seed: Set<UUID>,
                                       extraConnectorIDs: Set<UUID>) {
        guard !seed.isEmpty || !extraConnectorIDs.isEmpty else { return }

        // Compute the full deletion set up front so we don't re-traverse
        // for each id (and don't risk order-dependent behaviour).
        var allIDs = seed
        for id in seed {
            if let rect = sectionRect(of: id) {
                allIDs.formUnion(nodeIDs(insideWorldRect: rect))
            }
        }
        // Any card-stack head (or member) in the seed brings its entire
        // group along — deleting a stack must take its hidden members
        // with it, otherwise they become orphaned with a dangling
        // `groupID` and stay invisible forever.
        allIDs.formUnion(expandedDragSet(from: allIDs))

        let removedCount = nodes.lazy.filter { allIDs.contains($0.id) }.count
        withUndoable {
            nodes.removeAll { allIDs.contains($0.id) }
            connectors.removeAll { c in
                allIDs.contains(c.sourceID)
                || allIDs.contains(c.targetID)
                || extraConnectorIDs.contains(c.id)
            }
        }

        for cid in allIDs {
            measuredHeights.removeValue(forKey: cid)
            selectedNodeIDs.remove(cid)
            if pendingFocusNodeID == cid { pendingFocusNodeID = nil }
        }
        selectedConnectorIDs.subtract(extraConnectorIDs)

        // Deletion leaves no visible trace where the cards were — confirm
        // it happened (and remind that it's reversible).
        if removedCount > 0 {
            showToast(
                removedCount == 1
                    ? "Deleted 1 card — ⌘Z to undo"
                    : "Deleted \(removedCount) cards — ⌘Z to undo",
                systemImage: "trash"
            )
        }
    }

    // Kept for backward-compat with menu wiring.
    func deleteSelectedNode() { deleteSelected() }

    // MARK: - Drag-active broadcast

    /// Called by `DraggableNode.initDrag` to publish "this node is
    /// being dragged" + which other nodes are connected to it. Used
    /// by `DraggableNode` to apply a small tug offset on its
    /// connected peers while the drag is active.
    func beginDrag(of id: UUID) {
        let connected: Set<UUID> = connectors.reduce(into: []) { acc, c in
            if c.sourceID == id { acc.insert(c.targetID) }
            if c.targetID == id { acc.insert(c.sourceID) }
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            activeDragID = id
            activeDragConnectedIDs = connected
        }
    }

    /// Mirror of `beginDrag(of:)` — called from `DraggableNode`'s
    /// drag-end (inside the same `withAnimation` block as the position
    /// spring so the tug releases in lockstep with the position).
    func endDrag() {
        activeDragID = nil
        activeDragConnectedIDs = []
    }

    // MARK: - Connectors

    /// Append a directed arrow from `source` to `target`, deduping if it
    /// already exists in either direction.
    func addConnector(from source: UUID, to target: UUID) {
        guard source != target else { return }
        let exists = connectors.contains {
            ($0.sourceID == source && $0.targetID == target) ||
            ($0.sourceID == target && $0.targetID == source)
        }
        guard !exists else { return }
        withUndoable {
            connectors.append(Connector(sourceID: source, targetID: target))
        }
        // Threshold haptic — the connector "landed" on a target node.
        Haptics.threshold()
    }

    /// Top-most node that contains the given world point, ignoring drawing
    /// nodes (they have non-rectangular hit shapes that look wrong as
    /// connector targets).
    func nodeAt(world point: CGPoint) -> CanvasNode? {
        for node in nodes.reversed() {
            if case .drawing = node.kind { continue }
            let h = renderedHeight(of: node)
            let rect = CGRect(x: node.position.x, y: node.position.y,
                              width: node.width, height: h)
            if rect.contains(point) { return node }
        }
        return nil
    }

    /// Best-known rendered height of a node — uses the explicit field for
    /// drawings, the live measurement for tweet/text, otherwise a default.
    func renderedHeight(of node: CanvasNode) -> CGFloat {
        if let h = node.height { return h }
        if let h = measuredHeights[node.id] { return h }
        switch node.kind {
        case .tweet:      return 220
        case .instagram:  return 540
        case .text:       return 56
        case .drawing:    return 100
        case .image:      return 360
        case .video:      return 270
        case .youtube:    return 203
        case .webclip:    return 320
        case .section:    return 200
        case .stickyNote: return 200
        case .folder:     return 224
        }
    }

    func reportMeasuredHeight(_ height: CGFloat, for id: UUID) {
        guard height > 0 else { return }
        // Skip sub-pixel jitter up front so a stable layout never schedules
        // a flush at all.
        guard abs((measuredHeights[id] ?? -1) - height) > 0.5 else { return }
        pendingHeights[id] = height
        guard !heightFlushScheduled else { return }
        heightFlushScheduled = true
        // Defer the @Published write off the current layout pass.
        // DispatchQueue.main.async is required here rather than
        // Task { @MainActor in }: on macOS 27 beta, CA::Transaction::flush
        // can drain Swift Concurrency tasks mid-layout, so the Task-based
        // deferral fires while _layoutSubtreeWithOldSize is still on the
        // stack, writing measuredHeights re-enters layout, and AppKit's
        // recursion guard trips at depth 16. DispatchQueue.main.async
        // always defers to the NEXT main queue drain (after the display
        // callback has returned to the runloop), breaking the cycle.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.flushMeasuredHeights() }
        }
    }

    /// Apply buffered height reports in one batch (one `objectWillChange`),
    /// on a fresh main-actor turn so it can't recurse into the layout pass
    /// that produced them.
    private func flushMeasuredHeights() {
        heightFlushScheduled = false
        guard !pendingHeights.isEmpty else { return }
        for (id, h) in pendingHeights {
            if abs((measuredHeights[id] ?? -1) - h) > 0.5 {
                measuredHeights[id] = h
            }
        }
        pendingHeights.removeAll(keepingCapacity: true)
    }

    // MARK: - Mode dispatch

    /// Unified entry point for changing modes. Handles exiting the
    /// current mode and entering the new one with the correct ordering
    /// + async dispatch for modes that need it.
    func setMode(_ mode: CanvasMode) {
        guard mode != canvasMode else { return }
        // Mode transitions choreograph the camera themselves — coasting
        // or gliding must hand it over first.
        cancelPanInertia()
        // Exit whatever's active first so its transient state clears
        // before the next entry routine begins publishing.
        switch canvasMode {
        case .canvas:     break
        case .colorform:  exitColorform()
        case .archive:    exitArchive()
        }
        switch mode {
        case .canvas:     break    // already restored by exit above
        case .colorform:  Task { await enterColorform() }
        case .archive:    enterArchive()
        }
        // Remember the last *view* mode so a relaunch can restore it.
        // Colorform is intentionally excluded — it's too expensive to
        // recompute on cold start.
        if mode.isViewMode, mode != .colorform {
            lastViewMode = mode
        }
    }

    // MARK: - Mode-aware rendering

    /// Position used for rendering this node — accounts for any active
    /// mode's transient re-layout overlay. Falls through to
    /// `node.position` when no override applies.
    func effectivePosition(of node: CanvasNode) -> CGPoint {
        // Stack focus mode lives *inside* canvas mode (it's a transient
        // sub-state, not a top-level CanvasMode). Its override wins when
        // the node belongs to the currently-focused stack — the head
        // and every member fly into the focus grid.
        if focusedStackID != nil, let p = focusPositions[node.id] {
            return p
        }
        switch canvasMode {
        case .colorform:
            if let p = colorformPositions[node.id] { return p }
        case .archive:
            if let p = archivePositions[node.id] { return p }
        case .canvas:
            break
        }
        return node.position
    }

    /// Switch into Colorform mode: extract dominant colors for every node,
    /// cluster them, and compute new spatial positions. Non-destructive —
    /// underlying node positions are unchanged. The synchronous mode flip
    /// (so the switcher's pill animates immediately) and the eventual
    /// position publication are both wrapped in `withAnimation`, so the
    /// switcher's tab slide and the card re-flow each get spring physics.
    func enterColorform() async {
        guard canvasMode != .colorform else { return }
        let pageAtStart = activePageID
        // Snapshot the camera *before* mode flip so we can restore it
        // verbatim on exit.
        preColorformCamera = camera
        // Snap the mode + spinner immediately so the UI feels responsive
        // while we go off to extract colors.
        withAnimation(.smooth(duration: 0.35)) {
            canvasMode = .colorform
            isComputingColorform = true
        }
        await refreshDominantColors()
        guard activePageID == pageAtStart, canvasMode == .colorform else {
            isComputingColorform = false
            return
        }
        let clusters = ColorformEngine.cluster(dominantColors)
        let sizes = Dictionary(uniqueKeysWithValues: nodes.map {
            ($0.id, CGSize(width: $0.width, height: renderedHeight(of: $0)))
        })
        let result = ColorformEngine.layout(clusters: clusters, nodeSizes: sizes)
        let framedCamera = cameraFraming(bulbs: result.bulbs)
        withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) {
            colorformPositions = result.positions
            colorBulbs = result.bulbs
            if let cam = framedCamera { camera = cam }
        }
        isComputingColorform = false
    }

    /// Drop the Colorform overlay and return to normal canvas rendering.
    /// Underlying node positions and the user's prior camera are both
    /// restored, so leaving Colorform feels truly non-destructive.
    func exitColorform() {
        guard canvasMode == .colorform else { return }
        let restored = preColorformCamera
        withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) {
            canvasMode = .canvas
            colorformPositions = [:]
            colorBulbs = []
            if let cam = restored { camera = cam }
        }
        dominantColors = [:]
        isComputingColorform = false
        preColorformCamera = nil
    }

    /// Effective display size of a node when in a mode that re-flows
    /// or re-sizes cards. Archive's Bento level lays them out
    /// per-cardinality with explicit sizes. Falls through to natural
    /// size when no override applies.
    func effectiveSize(of node: CanvasNode) -> CGSize {
        // Stack focus mode wins over every other override — its bento
        // grid sets per-member explicit sizes that text caps + aspect-
        // preserves images/videos.
        if focusedStackID != nil, let s = focusSizes[node.id] {
            return s
        }
        // Bento layout: explicit per-card size.
        if canvasMode == .archive, let s = archiveSizes[node.id] {
            return s
        }
        return CGSize(width: node.width, height: renderedHeight(of: node))
    }

    // MARK: - Archive mode

    /// Switch into Archive at the top level (Calendar). Computes the
    /// per-day cache once on entry; further mutations to `nodes` while
    /// in Archive call `refreshArchiveDays()` to keep it fresh.
    func enterArchive() {
        guard canvasMode != .archive else { return }
        preArchiveCamera = camera
        let days = ArchiveEngine.daysWithContent(from: nodes)
        // Archive's calendar layer is positioned in screen coords, not
        // world coords, so we don't need the camera. Park it at neutral
        // values so any leak-through has predictable behaviour.
        let neutral = Camera(x: 0, y: 0, zoom: 1.0)
        withAnimation(Motion.structure) {
            canvasMode = .archive
            archiveLevel = .calendar
            setArchiveDays(days)
            camera = neutral
        }
    }

    /// Set `archiveDays` and the matching reverse `cardToDay` index in
    /// one place — every other entry point routes through here so the
    /// two stay in sync.
    private func setArchiveDays(_ days: [Date: [UUID]]) {
        archiveDays = days
        var reverse: [UUID: Date] = [:]
        reverse.reserveCapacity(days.values.reduce(0) { $0 + $1.count })
        for (day, ids) in days {
            for id in ids { reverse[id] = day }
        }
        cardToDay = reverse
    }

    /// Pop one level up: card → day, day → calendar, calendar → exit
    /// Archive. Used by the breadcrumb and Esc handler.
    func popArchiveLevel() {
        switch archiveLevel {
        case .card(let cardID):
            withAnimation(Motion.structure) {
                // O(1) reverse lookup: which day owns this card?
                if let dayForCard = cardToDay[cardID] {
                    archiveLevel = .day(dayForCard)
                } else {
                    archiveLevel = .calendar
                }
            }
        case .day:
            withAnimation(Motion.structure) {
                archiveLevel = .calendar
                archivePositions = [:]
                archiveSizes = [:]
            }
        case .calendar:
            setMode(.canvas)
        }
    }

    /// Drill from Calendar into a specific day's Bento. Computes the
    /// cardinality-aware layout and publishes positions + sizes so the
    /// rendered cards smoothly glide into the magazine grid.
    func drillToDay(_ day: Date) {
        let normalized = Calendar.current.startOfDay(for: day)
        guard let ids = archiveDays[normalized], !ids.isEmpty else { return }
        let (positions, sizes) = ArchiveEngine.bentoLayout(
            cardIDs: ids,
            naturalSizes: ids.reduce(into: [UUID: CGSize]()) { dict, id in
                if let n = nodeByID[id] {
                    dict[id] = CGSize(width: n.width, height: renderedHeight(of: n))
                }
            },
            viewportSize: viewportSize.width > 0
                ? viewportSize
                : CGSize(width: 1200, height: 800)
        )
        withAnimation(Motion.structure) {
            archiveLevel = .day(normalized)
            archivePositions = positions
            archiveSizes = sizes
        }
    }

    /// Drill from Bento into a single card's Lightbox. Computes a
    /// centered, per-kind size for the focused card and merges it into
    /// `archivePositions` / `archiveSizes` so the existing card view
    /// glides from its bento slot to the lightbox center.
    func drillToCard(_ id: UUID) {
        guard let node = nodeByID[id] else { return }
        let viewport = viewportSize.width > 0
            ? viewportSize
            : CGSize(width: 1200, height: 800)
        let (positions, sizes) = ArchiveEngine.lightboxLayout(
            for: node,
            renderedHeight: renderedHeight(of: node),
            viewportSize: viewport
        )
        withAnimation(Motion.structure) {
            archiveLevel = .card(id)
            // Replace overrides with just the focused card's layout —
            // the rest of the day's cards aren't rendered in lightbox.
            archivePositions = positions
            archiveSizes = sizes
        }
    }

    /// Lightbox keyboard nav. `←/→` walk cards chronologically (within
    /// day, then across days at the boundaries). `↑/↓` jump to the
    /// next non-empty day's first card — skipping past empty days so
    /// the user never iterates through a calendar void.
    enum LightboxNav { case previousCard, nextCard, previousDay, nextDay }

    func lightboxNavigate(_ direction: LightboxNav) {
        guard case .card(let currentID) = archiveLevel else { return }
        // O(1) reverse lookup of the current card's day, then read its
        // ordered card list directly.
        guard let currentDay = cardToDay[currentID],
              let cardsInDay = archiveDays[currentDay]
        else { return }
        let currentIdx = cardsInDay.firstIndex(of: currentID) ?? 0

        let target: UUID?
        switch direction {
        case .previousCard:
            if currentIdx > 0 {
                target = cardsInDay[currentIdx - 1]
            } else if let prev = previousNonEmptyDay(from: currentDay) {
                target = archiveDays[prev]?.last
            } else {
                target = nil
            }
        case .nextCard:
            if currentIdx < cardsInDay.count - 1 {
                target = cardsInDay[currentIdx + 1]
            } else if let next = nextNonEmptyDay(from: currentDay) {
                target = archiveDays[next]?.first
            } else {
                target = nil
            }
        case .previousDay:
            target = previousNonEmptyDay(from: currentDay).flatMap { archiveDays[$0]?.first }
        case .nextDay:
            target = nextNonEmptyDay(from: currentDay).flatMap { archiveDays[$0]?.first }
        }

        if let t = target, t != currentID {
            drillToCard(t)
        }
    }

    private func previousNonEmptyDay(from day: Date) -> Date? {
        archiveDays.keys
            .filter { $0 < day && (archiveDays[$0]?.isEmpty == false) }
            .sorted().last
    }

    private func nextNonEmptyDay(from day: Date) -> Date? {
        archiveDays.keys
            .filter { $0 > day && (archiveDays[$0]?.isEmpty == false) }
            .sorted().first
    }

    /// Recompute the per-day cache. Called whenever `nodes` mutates
    /// while in Archive mode (so adding/removing a card refreshes the
    /// calendar heat without leaving the mode).
    func refreshArchiveDays() {
        guard canvasMode == .archive else { return }
        let days = ArchiveEngine.daysWithContent(from: nodes)
        withAnimation(.smooth(duration: 0.3)) { setArchiveDays(days) }
    }

    /// Restore the pre-Archive camera and clear transient state.
    func exitArchive() {
        guard canvasMode == .archive else { return }
        let restored = preArchiveCamera
        withAnimation(Motion.structure) {
            canvasMode = .canvas
            archiveLevel = .calendar
            setArchiveDays([:])
            archivePositions = [:]
            archiveSizes = [:]
            if let cam = restored { camera = cam }
        }
        preArchiveCamera = nil
    }

    /// Camera that frames every bulb in the layout with comfortable
    /// padding. Returns `nil` if there are no bulbs or the viewport
    /// hasn't been measured yet (initial launch races).
    private func cameraFraming(bulbs: [ColorBulb]) -> Camera? {
        guard !bulbs.isEmpty, viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        // Frame the seed constellation with a comfortable cream margin
        // around it (matches the reference). `ColorformLayer` clips the
        // Voronoi cells to (seed bbox + 420pt halo); we frame the camera
        // a bit larger again so the cream canvas shows around the cells.
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for b in bulbs {
            minX = min(minX, b.center.x); minY = min(minY, b.center.y)
            maxX = max(maxX, b.center.x); maxY = max(maxY, b.center.y)
        }
        let pad: CGFloat = 620        // cell halo (420) + cream gutter (~200)
        let worldW = max(1, (maxX - minX) + pad * 2)
        let worldH = max(1, (maxY - minY) + pad * 2)
        let z = min(
            min(viewportSize.width / worldW, viewportSize.height / worldH),
            1.2
        )
        let zoom = max(Self.minZoom, min(Self.maxZoom, z))
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        return Camera(
            x: viewportSize.width / 2 - centerX * zoom,
            y: viewportSize.height / 2 - centerY * zoom,
            zoom: zoom
        )
    }

    /// Background-extract dominant colors for every node on the active
    /// page. Falls back to a content-derived hue on failure (see
    /// `ColorExtraction.extract`).
    private func refreshDominantColors() async {
        let snapshot = nodes
        var results: [UUID: RGB] = [:]
        await withTaskGroup(of: (UUID, RGB).self) { group in
            for node in snapshot {
                group.addTask { (node.id, await ColorExtraction.extract(for: node)) }
            }
            for await pair in group { results[pair.0] = pair.1 }
        }
        // Only adopt results if the user is still in Colorform on the same page.
        guard canvasMode == .colorform else { return }
        dominantColors = results
    }

    // MARK: - Camera

    func zoomIn()    { glideCamera(to: cameraZooming(by: 1.25, around: viewportCentre)) }
    func zoomOut()   { glideCamera(to: cameraZooming(by: 1 / 1.25, around: viewportCentre)) }
    func resetView() { glideCamera(to: Camera()) }

    /// Pure target computation for a zoom step about a screen anchor —
    /// shared by the instant (pinch) and gliding (buttons/⌘±) paths.
    private func cameraZooming(by factor: CGFloat, around screenPoint: CGPoint) -> Camera {
        let oldZoom = camera.zoom
        let newZoom = max(Self.minZoom, min(Self.maxZoom, oldZoom * factor))
        guard newZoom != oldZoom else { return camera }
        let worldX = (screenPoint.x - camera.x) / oldZoom
        let worldY = (screenPoint.y - camera.y) / oldZoom
        return Camera(
            x: screenPoint.x - worldX * newZoom,
            y: screenPoint.y - worldY * newZoom,
            zoom: newZoom
        )
    }

    func zoom(by factor: CGFloat, around screenPoint: CGPoint) {
        // Direct gesture — it owns the camera now; kill any glide.
        cancelCameraGlide()
        camera = cameraZooming(by: factor, around: screenPoint)
    }

    func pan(deltaX: CGFloat, deltaY: CGFloat) {
        camera.x += deltaX
        camera.y += deltaY
    }

    // MARK: - Camera glide (continuous navigation)
    //
    // Discrete navigation moves (zoom buttons, ⌘0/fit, minimap jumps)
    // animate the camera VALUE with a spring driver instead of snapping —
    // so every observer (node layer, dot grid, minimap, zoom dial) moves
    // in lockstep. Retargeting mid-flight keeps the current velocity
    // (pressing ⌘+ repeatedly chains into one continuous accelerating
    // move), and any direct gesture cancels the glide and takes over —
    // motion never blocks input.

    private var cameraGlideTimer: Timer?
    private var glideTarget: Camera?
    private var glideVelocity: (x: CGFloat, y: CGFloat, zoom: CGFloat) = (0, 0, 0)

    func glideCamera(to target: Camera) {
        // macOS 26/27 beta (26A5353q): the 60 Hz Timer this method used to
        // schedule mutated the @Published `camera` every tick, and that
        // per-tick write re-entered AppKit's constraint-based layout until
        // it tripped the depth-16 recursion guard (EXC_BREAKPOINT in
        // -[NSView _layoutSubtreeWithOldSize:]). Any continuous camera
        // animation is therefore unsafe on this OS, so navigation jumps
        // straight to the target — exactly the pre-motion-system behavior
        // (and what Reduce Motion already did). No autonomous layout loop.
        cancelPanInertia()
        camera = target
    }

    func cancelCameraGlide() {
        cameraGlideTimer?.invalidate()
        cameraGlideTimer = nil
        glideTarget = nil
        glideVelocity = (0, 0, 0)
    }

    // MARK: - Pan-with-inertia (trackpad / mouse-wheel scroll)

    /// Ring buffer of recent (delta, timestamp) tuples used to derive
    /// scroll velocity at end-of-gesture. Entries older than ~100 ms
    /// are pruned on every push so velocity reflects the last burst
    /// of motion, not the whole pan.
    private var recentPanDeltas: [(delta: CGPoint, at: Date)] = []
    private var panIdleTimer: Timer?
    private var panInertiaTimer: Timer?

    /// Apply a pan delta and track velocity for end-of-gesture
    /// inertia. After ~80 ms of no further `panWithInertia` calls (the
    /// user has stopped scrolling, or macOS's natural trackpad
    /// momentum has finished), we synthesise a soft decay so the
    /// camera coasts to a stop instead of stopping dead. For trackpad
    /// momentum (events arrive at ~60 Hz), the idle timer never trips
    /// until momentum is done — so we don't double-apply.
    func panWithInertia(deltaX: CGFloat, deltaY: CGFloat) {
        cancelPanInertia()
        // Apply immediately — the inertia only kicks in *after* idle.
        pan(deltaX: deltaX, deltaY: deltaY)
        // Record + prune.
        let now = Date()
        recentPanDeltas.append((CGPoint(x: deltaX, y: deltaY), now))
        let cutoff = now.addingTimeInterval(-0.10)
        recentPanDeltas.removeAll { $0.at < cutoff }
        // Re-arm the idle timer.
        panIdleTimer?.invalidate()
        panIdleTimer = Timer.scheduledTimer(
            withTimeInterval: 0.08, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.startPanInertiaIfNeeded() }
        }
    }

    /// Cancel ALL autonomous camera motion — inertia coasting and any
    /// navigation glide. Called whenever a new pan tick arrives or the
    /// user starts a different gesture (zoom, drag, mode switch): direct
    /// input always seizes the camera mid-flight.
    func cancelPanInertia() {
        cancelInertiaOnly()
        cancelCameraGlide()
    }

    /// Inertia/idle teardown without touching a glide — used by
    /// `glideCamera` itself, which replaces coasting but IS the glide.
    private func cancelInertiaOnly() {
        panIdleTimer?.invalidate()
        panIdleTimer = nil
        panInertiaTimer?.invalidate()
        panInertiaTimer = nil
    }

    /// Compute residual velocity from the last ~100 ms of pan deltas;
    /// if it's above a perceptible threshold, kick off a 60 Hz decay
    /// loop. The decay exponent (0.92 / tick) gives a ~250 ms tail-off
    /// — enough to feel inertial without overshooting the user's
    /// intent.
    private func startPanInertiaIfNeeded() {
        // Disabled on macOS 26/27 beta: the inertia decay ran a 60 Hz
        // Timer that mutated the @Published `camera` each tick, the same
        // continuous-layout driver that trips AppKit's depth-16 recursion
        // guard. Scrolling still pans directly (see `panWithInertia`);
        // only the autonomous coast after release is removed.
        if #available(macOS 26.0, *) {
            recentPanDeltas.removeAll(keepingCapacity: true)
            return
        }
        let deltas = recentPanDeltas
        recentPanDeltas.removeAll(keepingCapacity: true)
        guard !deltas.isEmpty else { return }
        // Velocity = average delta per tick over the buffer window.
        let total = deltas.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.delta.x, y: $0.y + $1.delta.y)
        }
        let count = CGFloat(deltas.count)
        var velocity = CGPoint(x: total.x / count, y: total.y / count)
        // Skip if too slow to bother — avoids "stalling" at end of a
        // deliberate slow drag.
        guard hypot(velocity.x, velocity.y) > 1.5 else { return }
        // Tune the kickoff so it feels like a continuation, not an
        // extra shove.
        velocity.x *= 1.6
        velocity.y *= 1.6
        // `.common` mode so the coast keeps ticking during `.eventTracking`
        // (a follow-on trackpad gesture) instead of stalling in `.default`.
        let inertiaTimer = Timer(
            timeInterval: 1.0 / 60.0, repeats: true
        ) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            velocity.x *= 0.92
            velocity.y *= 0.92
            if hypot(velocity.x, velocity.y) < 0.4 {
                timer.invalidate()
                Task { @MainActor in self.panInertiaTimer = nil }
                return
            }
            let vx = velocity.x, vy = velocity.y
            Task { @MainActor in self.pan(deltaX: vx, deltaY: vy) }
        }
        RunLoop.main.add(inertiaTimer, forMode: .common)
        panInertiaTimer = inertiaTimer
    }

    /// Frame all nodes within the viewport. If empty, just resets.
    func zoomToFit() {
        guard !nodes.isEmpty,
              let rect = boundingRect(of: Set(nodes.map(\.id))) else {
            resetView(); return
        }
        frameRect(rect, padding: 80)
    }

    /// Frame the bounding rect of the current selection; falls through to
    /// `zoomToFit` when nothing is selected so the keyboard shortcut never
    /// feels broken.
    func zoomToSelection() {
        guard !selectedNodeIDs.isEmpty,
              let rect = boundingRect(of: selectedNodeIDs) else {
            zoomToFit(); return
        }
        frameRect(rect, padding: 80)
    }

    /// Bounding rectangle of the given node ids in WORLD coordinates.
    /// Returns nil if no matching nodes exist on the active page.
    func boundingRect(of ids: Set<UUID>) -> CGRect? {
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var found = false
        for n in nodes where ids.contains(n.id) {
            minX = min(minX, n.position.x)
            minY = min(minY, n.position.y)
            maxX = max(maxX, n.position.x + n.width)
            maxY = max(maxY, n.position.y + renderedHeight(of: n))
            found = true
        }
        guard found else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Cache backing `stableWorldBounds` — reset on page switch.
    private var cachedWorldBounds: CGRect?

    /// The scrollable canvas extent. Unlike the raw content bounding box this is
    /// GROWS-ONLY: it never shrinks or shifts while the content still fits inside
    /// it. That is what makes a *select-all* drag visibly move the cards — a
    /// content-following box would shift by the same delta as the nodes, leaving
    /// every node's position RELATIVE to the box unchanged (so nothing appears to
    /// move, even though the model positions did change). It expands only when a
    /// node is dragged/created outside the current margin.
    func stableWorldBounds() -> CGRect {
        let margin: CGFloat = 6000
        guard let content = boundingRect(of: Set(nodes.map(\.id))),
              content.width > 0, content.height > 0 else {
            return cachedWorldBounds ?? CGRect(x: -margin, y: -margin, width: 2 * margin, height: 2 * margin)
        }
        if let cached = cachedWorldBounds, cached.contains(content) { return cached }
        let next = (cachedWorldBounds ?? .null).union(content.insetBy(dx: -margin, dy: -margin))
        cachedWorldBounds = next
        return next
    }

    /// Drop the cached extent (call on page switch so a new page isn't anchored
    /// to the previous page's far-flung bounds).
    func resetWorldBoundsCache() { cachedWorldBounds = nil }

    /// Glide the camera to frame the given world rect with `padding`
    /// extra breathing room on each side. Capped to zoom 1.5× max so a
    /// single small card doesn't get magnified into a blur.
    func frameRect(_ rect: CGRect, padding: CGFloat) {
        let worldW = max(1, rect.width + padding * 2)
        let worldH = max(1, rect.height + padding * 2)
        let raw = min(viewportSize.width / worldW, viewportSize.height / worldH)
        let z = max(Self.minZoom, min(Self.maxZoom, min(raw, 1.5)))
        glideCamera(to: Camera(
            x: viewportSize.width / 2 - rect.midX * z,
            y: viewportSize.height / 2 - rect.midY * z,
            zoom: z
        ))
    }

    /// Glide the camera to an exact zoom value, recentred on the viewport
    /// centre so the user's eye doesn't lose its place.
    func setZoom(_ z: CGFloat) {
        let target = max(Self.minZoom, min(Self.maxZoom, z))
        guard camera.zoom > 0 else { camera.zoom = target; return }
        glideCamera(to: cameraZooming(by: target / camera.zoom, around: viewportCentre))
    }

    /// Glide the camera so the given world point sits at the viewport
    /// centre (current zoom). Click-drag in the minimap retargets this
    /// every tick — the glide's preserved velocity turns that into a
    /// smooth pursuit of the cursor.
    func centerCamera(on worldPoint: CGPoint) {
        glideCamera(to: Camera(
            x: viewportSize.width / 2 - worldPoint.x * camera.zoom,
            y: viewportSize.height / 2 - worldPoint.y * camera.zoom,
            zoom: camera.zoom
        ))
    }

    // MARK: - Coordinate helpers

    var viewportCentre: CGPoint {
        let size = viewportSize == .zero ? CGSize(width: 1000, height: 700) : viewportSize
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    func screenToWorld(point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - camera.x) / camera.zoom,
            y: (point.y - camera.y) / camera.zoom
        )
    }

    /// World-space rectangle currently visible on screen. Single source of
    /// truth for viewport-culling decisions — the minimap, the semantic-
    /// zoom playback gate, and any future "is this card on screen?" query
    /// all derive from here.
    var visibleWorldRect: CGRect {
        let size = viewportSize == .zero ? CGSize(width: 1000, height: 700) : viewportSize
        guard camera.zoom > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let z = camera.zoom
        return CGRect(
            x: -camera.x / z,
            y: -camera.y / z,
            width:  size.width  / z,
            height: size.height / z
        )
    }

    // MARK: - Semantic-zoom render gate
    //
    // From the thesis (ch. 5 — Významové přibližování / ch. 6 — Inteligentní
    // správa viditelného prostoru): heavy media is STATIC at low zoom and
    // comes alive only once a card crosses a defined breakpoint AND
    // remains inside the viewport. The resting state protects both the
    // user's cognitive centre of attention and machine performance — for
    // videos that means the AVPlayer is fully unmounted (no decoder
    // threads, no GPU texture, no looper); for images it means we skip
    // the full-resolution Image render and draw a lightweight placeholder.
    // Dozens of media cards can coexist because at most a handful are
    // actually decoding / compositing at any one moment.

    /// Minimum on-screen height (in pt) below which a media-bearing card
    /// falls back to a static placeholder. Picked so a card that's
    /// clearly a peripheral thumbnail (~ icon-sized) stays cheap, but a
    /// card the user has zoomed in on renders fully without hesitation.
    static let livePlaybackMinScreenSide: CGFloat = 120

    /// Below this projected on-screen size (pt), a card drops to its
    /// level-of-detail proxy (see `DraggableNode.isTiny`): content + position
    /// only, no per-card chrome/gestures. Keeps deep zoom-out cheap when the
    /// whole board is on screen and culling can't help.
    static let lodMinScreenSide: CGFloat = 14

    /// The card's smaller side projected through the current camera zoom.
    func projectedScreenSide(of node: CanvasNode) -> CGFloat {
        min(node.width, renderedHeight(of: node)) * camera.zoom
    }

    /// Whether the given node should render its heavy content. True iff
    /// (a) the node intersects the viewport and (b) its projected screen
    /// size meets the breakpoint. Non-media kinds always return true —
    /// there's nothing to gate (text, sticky, section, drawing all render
    /// cheaply at any size).
    func isLive(_ node: CanvasNode) -> Bool {
        // While the lightbox is open, force EVERY canvas card to its static
        // poster — no WKWebViews/players composite behind the hero spin, so
        // the animation stays buttery (and the dimmed grid is cheap to draw).
        if lightboxCardID != nil { return false }
        // The card being trimmed hands playback to the trim overlay's own
        // seekable player, so tear down its background loop player.
        if trimmingCardID == node.id { return false }
        switch node.kind {
        case .video, .tweet, .instagram, .image, .youtube, .webclip:
            break               // gated below
        default:
            return true
        }
        // NOTE: media is intentionally NOT suppressed during a pan. The
        // pan-crash culprit was the minimap's `.glassEffect` re-laying out
        // every tick (an AppKit constraint view), not the media cards — a
        // build with media fully suppressed during pan still crashed until
        // the glass was removed. SwiftUI `.scaleEffect`/`.offset` transform
        // the media layers without an AppKit constraint pass, so live
        // players during a pan are safe; suppressing them only made cards
        // blink (poster<->live) on every pan. `isCameraInteracting` now
        // gates only the minimap glass (see LiquidGlassMinimap).
        // "Show video previews only" — force every video-bearing kind to
        // its resting (poster) state regardless of zoom / viewport. Images
        // are left to the normal gate below: isLive controls an image's
        // actual pixels and an image has no playback to stop.
        if videosShowPreviewOnly {
            switch node.kind {
            case .video, .tweet, .instagram, .youtube: return false
            default: break
            }
        }
        let screenSide = min(node.width, renderedHeight(of: node)) * camera.zoom
        guard screenSide >= Self.livePlaybackMinScreenSide else { return false }
        let nodeRect = CGRect(
            x: node.position.x, y: node.position.y,
            width: node.width, height: renderedHeight(of: node)
        )
        return visibleWorldRect.intersects(nodeRect)
    }

    // MARK: - Node mutation

    /// Fast in-place single-node mutation for hot-path field writes
    /// (drag, resize). Bypasses the `nodes` computed setter — so it does
    /// NOT rebuild the whole `nodeByID` index or the archive-days cache
    /// on every tick — and patches `nodeByID` for just the one key.
    /// Structural edits (add / delete / reorder) still go through the
    /// `nodes` setter, which rebuilds the index wholesale.
    private func mutateNode(_ id: UUID, _ transform: (inout CanvasNode) -> Void) {
        let pageIdx = activePageIndex
        guard pages.indices.contains(pageIdx),
              let nodeIdx = pages[pageIdx].nodes.firstIndex(where: { $0.id == id })
        else { return }
        var node = pages[pageIdx].nodes[nodeIdx]
        transform(&node)
        nodeByID[id] = node
        pages[pageIdx].nodes[nodeIdx] = node
    }

    func updatePosition(of id: UUID, to position: CGPoint) {
        mutateNode(id) { $0.position = position }
    }

    /// Resize a node. Width is always written; height is written for any
    /// node kind that has a fixed height (everything except auto-sizing
    /// tweets / text — those keep nil so they continue auto-sizing).
    /// Caller passes a frame; we clamp to the kind's `minSize`.
    func resize(id: UUID, frame: CGRect) {
        mutateNode(id) { node in
            let minSize = node.kind.minSize
            node.position = CGPoint(x: frame.minX, y: frame.minY)
            node.width = max(minSize.width, frame.width)
            switch node.kind {
            case .text:
                // Text auto-sizes; never write an explicit height.
                break
            default:
                node.height = max(minSize.height, frame.height)
            }
        }
    }

    /// A media card (tweet) resolved its real media aspect asynchronously —
    /// snap the node's height to it so the aspect-fit card fills its frame
    /// instead of leaving a gray gap around it. Routed through `resize` so it
    /// persists + re-lays out (not a separate undoable action). Idempotent:
    /// no-ops once the height already matches, so it can't fight a user's
    /// aspect-locked resize.
    func snapMediaAspect(_ id: UUID, aspect: CGFloat) {
        guard aspect > 0.01, let n = nodeByID[id] else { return }
        let target = (n.width / aspect).rounded()
        guard abs((n.height ?? -1) - target) > 1 else { return }
        resize(id: id, frame: CGRect(x: n.position.x, y: n.position.y,
                                     width: n.width, height: target))
    }

    /// Insert a copy of `id` at the same position with a fresh UUID.
    /// Used by Option-drag and ⌘D duplicate.
    @discardableResult
    func duplicateNode(_ id: UUID) -> UUID? {
        guard let original = nodeByID[id] else { return nil }
        let copy = CanvasNode(
            position: original.position,
            width: original.width,
            height: original.height,
            kind: original.kind
        )
        withUndoable { nodes.append(copy) }
        return copy.id
    }

    // MARK: - Pasteboard / cut / copy / paste / Z-order

    /// Custom pasteboard type used to cut & paste nodes (+ their internal
    /// connectors) between operations. Plain-text URL paste still works
    /// via `pasteFromClipboard()` — the two layers don't conflict.
    static let nodePasteboardType =
        NSPasteboard.PasteboardType("com.embeddedvideocanvas.nodes")

    /// Codable payload written to the pasteboard.
    private struct NodeClipboard: Codable {
        var nodes: [CanvasNode]
        var connectors: [Connector]
    }

    /// Copy the current selection onto the pasteboard. Connectors are
    /// included only if BOTH endpoints are inside the selected set.
    func copySelection() {
        guard !selectedNodeIDs.isEmpty else { return }
        let selectedNodes = nodes.filter { selectedNodeIDs.contains($0.id) }
        let internalConnectors = connectors.filter {
            selectedNodeIDs.contains($0.sourceID) && selectedNodeIDs.contains($0.targetID)
        }
        guard let data = try? JSONEncoder().encode(
            NodeClipboard(nodes: selectedNodes, connectors: internalConnectors)
        ) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.nodePasteboardType)
    }

    /// Copy + delete.
    func cutSelection() {
        copySelection()
        deleteSelected()
    }

    /// Paste from the pasteboard.
    ///   • If the pasteboard contains our node payload → insert those nodes
    ///     (with fresh UUIDs) onto the current page, slightly offset.
    ///   • Otherwise → fall through to the existing URL-paste flow.
    func pasteFromPasteboard() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.nodePasteboardType),
           let payload = try? JSONDecoder().decode(NodeClipboard.self, from: data) {
            paste(payload: payload)
        } else {
            pasteFromClipboard()
        }
    }

    private func paste(payload: NodeClipboard) {
        // Rewrite every UUID so pasted nodes don't collide with existing ones
        // (and so connector endpoints can be remapped to the new ids).
        var idMap: [UUID: UUID] = [:]
        for n in payload.nodes { idMap[n.id] = UUID() }
        let offset: CGFloat = 24
        let newNodes: [CanvasNode] = payload.nodes.map { n in
            CanvasNode(
                id: idMap[n.id] ?? UUID(),
                position: CGPoint(x: n.position.x + offset, y: n.position.y + offset),
                width: n.width,
                height: n.height,
                kind: n.kind
            )
        }
        let newConnectors: [Connector] = payload.connectors.compactMap { c in
            guard let s = idMap[c.sourceID], let t = idMap[c.targetID] else { return nil }
            return Connector(sourceID: s, targetID: t)
        }
        withUndoable {
            nodes.append(contentsOf: newNodes)
            connectors.append(contentsOf: newConnectors)
        }
        selectedNodeIDs = Set(newNodes.map(\.id))
        selectedConnectorIDs = []
    }

    /// Move the given node ids to the END of the array (front in z-order
    /// because we render via `ForEach` and later items paint on top).
    func bringToFront(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        withUndoable {
            let moving = nodes.filter { ids.contains($0.id) }
            let rest   = nodes.filter { !ids.contains($0.id) }
            nodes = rest + moving
        }
    }

    /// Move the given node ids to the START of the array (back in z-order).
    func sendToBack(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        withUndoable {
            let moving = nodes.filter { ids.contains($0.id) }
            let rest   = nodes.filter { !ids.contains($0.id) }
            nodes = moving + rest
        }
    }

    // MARK: - Duplicate (continued)

    /// Duplicate every given node id; returns the set of new copies.
    /// One undo entry covers the whole batch via re-entrant `withUndoable`.
    ///
    /// Card-stack semantics: each duplicated group gets a fresh `groupID`
    /// shared by all of its copies, so the result is a new stack that
    /// can be moved + ungrouped independently of its source. Sections
    /// are duplicated as-is — their members are copied via the seed
    /// expansion (`expandedDragSet`) and continue to render at their
    /// duplicated positions.
    @discardableResult
    func duplicateNodes(_ ids: Set<UUID>) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        // Expand so a stack head pulls its hidden members; without this
        // a stack duplicate would clone the head only, orphaning the
        // (now uncloned) members under a still-shared groupID.
        let expanded = expandedDragSet(from: ids)
        // One fresh groupID per original group, so duplicates form an
        // independent new stack instead of merging into the original.
        var freshGroupForOriginal: [UUID: UUID] = [:]
        var copies: Set<UUID> = []
        withUndoable {
            for original in nodes where expanded.contains(original.id) {
                let newGroupID: UUID? = {
                    guard let originalGroup = original.groupID else { return nil }
                    if let existing = freshGroupForOriginal[originalGroup] {
                        return existing
                    }
                    let fresh = UUID()
                    freshGroupForOriginal[originalGroup] = fresh
                    return fresh
                }()
                let copy = CanvasNode(
                    position: original.position,
                    width: original.width,
                    height: original.height,
                    kind: original.kind,
                    groupID: newGroupID
                )
                nodes.append(copy)
                copies.insert(copy.id)
            }
        }
        return copies
    }
}
