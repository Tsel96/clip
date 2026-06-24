import SwiftUI
import AppKit

@main
struct ClipApp: App {
    @StateObject private var state = CanvasState()

    init() {
        setbuf(stdout, nil)   // unbuffered stdout so diagnostics flush immediately
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .aqua)  // force light mode until dark theme is ready
        ClipApp.applyIcon()      // Dock / app-menu icon (SwiftPM has no Info.plist)
        UpdateChecker.shared.start()   // silent self-update (inert in dev builds)
    }

    /// Sets the Dock / app-menu icon from the bundled AppIcon.icns. SwiftPM
    /// executables have no Info.plist `CFBundleIconFile`, so the icon must be
    /// assigned programmatically at startup.
    private static func applyIcon() {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    /// Folder picker for the iPhone share inbox — the iCloud Drive folder
    /// the "Add to Canvas" Shortcut saves links into.
    private func pickSharedInboxFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the iCloud Drive folder your iPhone Shortcut saves links to"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch Folder"
        if panel.runModal() == .OK, let url = panel.url {
            state.setSharedInboxFolder(url)
        }
    }

    /// Debug builds (`swift run`, Xcode ⌘R) are visibly marked in the window
    /// title so it's always obvious whether a dev build or the installed
    /// release copy is on screen. Release builds show plain "CLIP".
    private var windowTitle: String {
        #if DEBUG
        "CLIP · dev"
        #else
        "CLIP"
        #endif
    }

    var body: some Scene {
        WindowGroup(windowTitle) {
            ContentView()
                .environmentObject(state)
                .environmentObject(state.cameraStore)
                .environmentObject(state.smartSelection)
                .frame(minWidth: 800, minHeight: 600)
                .preferredColorScheme(.light)   // force light mode (dark theme not ready)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    // Belt-and-suspenders: pin every window to the light appearance
                    // so nothing renders in (broken) dark mode.
                    NSApp.appearance = NSAppearance(named: .aqua)
                    NSApp.windows.forEach { $0.appearance = NSAppearance(named: .aqua) }
                }
                .onOpenURL { _ in
                    // `clip://` deep links (the website's "Open CLIP" button) just
                    // launch + focus the app. The host/path are reserved for future
                    // routes (e.g. clip://page/<id>); for now any clip:// URL fronts it.
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }
        }
        // No top title bar — the window chrome is removed so the canvas reaches
        // the top edge (traffic lights float over the content).
        .windowStyle(.hiddenTitleBar)
        .commands {
            // File ▸ Add Post…  (⌘N)  — accepts X or Instagram URLs.
            CommandGroup(replacing: .newItem) {
                Button("Add Post…") { state.isAddSheetPresented = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Folder") { state.addFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            // File ▸ iPhone share inbox controls.
            CommandGroup(after: .newItem) {
                Button("Set Shared-Links Folder…") { pickSharedInboxFolder() }
                Button("Check for Shared Links Now") { state.sweepSharedInbox() }
                    .disabled(state.sharedInboxFolderURL == nil)
            }

            // Edit ▸ Undo / Redo — replaces SwiftUI's stock entries.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { state.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!state.canUndo)
                Button("Redo") { state.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!state.canRedo)
            }

            // Edit ▸ Cut / Copy / Paste / Delete.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { state.cutSelection() }
                    .keyboardShortcut("x", modifiers: .command)
                    .disabled(state.selectedNodeIDs.isEmpty)
                Button("Copy") { state.copySelection() }
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(state.selectedNodeIDs.isEmpty)
                Button("Paste") { state.pasteFromPasteboard() }
                    .keyboardShortcut("v", modifiers: .command)
                Divider()
                Button("Delete") {
                    // If a Smart Selection is active and elements are
                    // marked, the cascade-reflow path runs first; only
                    // unmarked-or-no-smart-selection cases fall through
                    // to the standard delete (which itself expands
                    // stack heads into their members — see
                    // `removeNodesAndCascade`).
                    if state.smartSelection.layout != nil,
                       !state.smartSelection.markedIDs.isEmpty {
                        state.smartSelection.deleteMarked()
                    } else {
                        state.deleteSelected()
                    }
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!state.hasSelection)
            }

            // Edit ▸ Find…  (⌘K) — opens the search palette.
            CommandGroup(after: .pasteboard) {
                Button("Find…") { state.isSearchPresented = true }
                    .keyboardShortcut("k", modifiers: .command)
            }

            // Edit ▸ Select All / Duplicate / Bring to Front / Send to Back.
            CommandGroup(after: .pasteboard) {
                Button("Select All") {
                    // If a text editor is focused (sticky / text node / field),
                    // ⌘A selects its TEXT — menu shortcuts fire before the first
                    // responder, so route it manually. Otherwise select all cards.
                    if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                        tv.selectAll(nil)
                    } else {
                        state.selectAll()
                    }
                }
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(state.nodes.isEmpty)
                Button("Duplicate") {
                    if state.smartSelection.layout != nil,
                       !state.smartSelection.markedIDs.isEmpty {
                        // Smart Selection's cascade-duplicate keeps the
                        // matrix shape intact (clone inserts at i+1, tail
                        // shifts forward, row wraps in Grid2D).
                        state.smartSelection.duplicateMarked()
                    } else {
                        // `duplicateNodes` itself expands stack heads
                        // into their members — see its implementation.
                        let copies = state.duplicateNodes(state.selectedNodeIDs)
                        if !copies.isEmpty { state.selectNodes(copies) }
                    }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(state.selectedNodeIDs.isEmpty)
                Button("Tidy Up") {
                    state.smartSelection.tidyUp()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(state.selectedNodeIDs.count < 2)
                Button("Reset Card Sizes") {
                    state.resetAllNodesToNativeSize()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(state.nodes.isEmpty)
                Divider()
                Button("Group") {
                    state.groupSelection()
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(state.groupableSelectionCount < 2)
                Button("Ungroup") {
                    state.ungroupSelection()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!state.selectionHasGroupedNode)
                Divider()
                Button("Bring to Front") { state.bringToFront(state.selectedNodeIDs) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(state.selectedNodeIDs.isEmpty)
                Button("Send to Back") { state.sendToBack(state.selectedNodeIDs) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(state.selectedNodeIDs.isEmpty)
            }

            // View ▸ Mode switching (⌘1 / ⌘2 / ⌘3, Apple-standard for
            // primary section navigation — Photos, Notes, Mail all use
            // bare-digit-Cmd for top-level views).
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Canvas")    { state.setMode(.canvas)    }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Colorform") { state.setMode(.colorform) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Archive")   { state.setMode(.archive)   }
                    .keyboardShortcut("3", modifiers: .command)
            }

            // View ▸ Zoom controls. Bare digits 1-3 are reserved for the
            // mode shortcuts above (Apple convention); zoom-to-fit moved
            // to ⇧⌘0 (matches Figma's `⇧0`) and zoom-to-selection to
            // ⇧⌘1, freeing ⌘1 for "Canvas mode."
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Zoom In")     { state.zoomIn()     }.keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out")    { state.zoomOut()    }.keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { state.resetView() }.keyboardShortcut("0", modifiers: .command)
                Button("Fit All")     { state.zoomToFit() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
                Button("Zoom to Selection") { state.zoomToSelection() }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                    .disabled(state.selectedNodeIDs.isEmpty)
                Divider()
                Button(state.isMinimapDetached ? "Reattach Minimap" : "Detach Minimap") {
                    state.isMinimapDetached.toggle()
                }
            }

            // Tools menu — single-key shortcuts wired up natively.
            CommandMenu("Tools") {
                Button("Select")  { state.toolMode = .select  }
                    .keyboardShortcut("v", modifiers: [])
                Button("Text")    { state.toolMode = .text    }
                    .keyboardShortcut("t", modifiers: [])
                Button("Draw")    { state.toolMode = .draw    }
                    .keyboardShortcut("d", modifiers: [])
                Button("Connect") { state.toolMode = .connect }
                    .keyboardShortcut("c", modifiers: [])

                Divider()
                // Figma-style step-through: N = next card, ⇧N = previous.
                // Selects the card and frames it (zoom-to-selection).
                Button("Next Card") { state.selectNextNode() }
                    .keyboardShortcut("n", modifiers: [])
                    .disabled(state.canvasMode != .canvas)
                Button("Previous Card") { state.selectNextNode(reverse: true) }
                    .keyboardShortcut("n", modifiers: .shift)
                    .disabled(state.canvasMode != .canvas)
                Button("Open Source Link") { state.openSelectedSource() }
                    .keyboardShortcut("o", modifiers: [])
                    .disabled(state.selectedNodeIDs.isEmpty)
            }
        }
    }
}
