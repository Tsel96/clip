import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: CanvasState
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @Environment(\.colorScheme) private var systemScheme

    /// The appearance actually in effect — the forced mode, or the system's
    /// when following. Used to pick the matching `ClipTheme` to inject.
    private var effectiveScheme: ColorScheme {
        switch state.themeMode {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return systemScheme
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PagesSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
        } detail: {
            CanvasView()
                // Soft floor only. A hard 720 here exceeded (window − sidebar)
                // at small sizes, so the split view shoved the sidebar off the
                // window's left edge (its labels clipped on the leading side).
                // 480 always leaves room for the sidebar's 180–280.
                // Fill under the hidden title bar so no blank strip shows at the
                // top (traffic lights float over the sidebar, not the canvas).
                .ignoresSafeArea(.container, edges: .top)
                .frame(minWidth: 480, minHeight: 480)
                .toolbar { toolbarContent }
                .sheet(isPresented: $state.isAddSheetPresented) {
                    AddToCanvasSheet(
                        initialURL: bestPasteboardCandidate(),
                        onAddURL:   { state.addPostFromURL($0) },
                        onAddImage: { data, name in state.addImage(data: data, filename: name) },
                        onAddVideo: { url in state.addVideo(fileURL: url) }
                    )
                }
                .alert(item: $state.alert) { item in
                    Alert(
                        title: Text(item.title),
                        message: Text(item.message),
                        dismissButton: .default(Text("OK"))
                    )
                }
                // ⌘K search palette — centred floating sheet.
                .sheet(isPresented: $state.isSearchPresented) {
                    SearchPalette()
                        .padding(.vertical, 80)
                }
                // "Set up iPhone sharing" how-to, opened from the inbox
                // empty state.
                .sheet(isPresented: $state.isInboxGuidePresented) {
                    InboxSetupGuide()
                }
        }
        // Drain any links the iPhone Shortcut dropped while the app was in
        // the background / closed.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            state.sweepSharedInbox()
        }
        // Full-window card lightbox — overlays the whole split view (covers
        // the sidebar); the window toolbar is hidden while it's open, so no
        // top/left panels show through.
        .overlay {
            // Fully-native detail view (Spatial CanvasTransition*); the open/close
            // gate lives inside the native CardDetailView, driven by state.
            NativeDetailHost()
                .ignoresSafeArea()
                .allowsHitTesting(state.lightboxCardID != nil)
                .zIndex(100)
        }
        // Top window toolbar removed entirely (user request): no sidebar toggle,
        // title, add/paste, or appearance bar. Add = ⌘N, paste = ⌘V.
        .toolbar(.hidden, for: .windowToolbar)
        // Drive the whole app's appearance + inject the matching ClipTheme so
        // every chrome surface reads one source of truth.
        .preferredColorScheme(state.themeMode.colorScheme)
        .environment(\.clipTheme, ClipTheme.resolve(effectiveScheme))
        // App-wide default typeface: ONY Semimono. Views that set an explicit
        // font still win; everything else inherits the technical mono look.
        // (No global .tint — the references keep chrome monochrome; the brand
        // yellow is applied deliberately, not to every control.)
        .font(.clip(13))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Native segmented tool picker. The Canvas / Colorform mode
        // switcher lives as a floating pill at the top of the canvas
        // (see `CanvasModeSwitcher`) rather than in the toolbar so it
        // reads more like Claude / Linear / Notion's tab strip.
        // Tool picker moved OUT of the window toolbar into the bottom-center
        // yellow tool palette (Figma 51:12692 / NativeCanvasToolPalette).

        // Draw-mode-only color & width controls.
        if state.toolMode == .draw {
            ToolbarItem(placement: .principal) {
                DrawOptionsToolbar()
            }
        }

        // Add post (X or Instagram).
        ToolbarItem(placement: .primaryAction) {
            Button {
                state.isAddSheetPresented = true
            } label: {
                Label("Add Post", systemImage: "plus")
            }
            .help("Add an X / Twitter or Instagram post by URL  (⌘N)")
            .accessibilityIdentifier("toolbar.addPost")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                state.pasteFromClipboard()
            } label: {
                Label("Paste Post", systemImage: "doc.on.clipboard")
            }
            .help("Paste an X or Instagram URL from the clipboard  (⌘V)")
            .accessibilityIdentifier("toolbar.paste")
        }

        // Appearance toggle — light / dark / follow-system.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Appearance", selection: $state.themeMode) {
                    Label("Light",  systemImage: "sun.max").tag(ThemeMode.light)
                    Label("Dark",   systemImage: "moon").tag(ThemeMode.dark)
                    Label("System", systemImage: "circle.lefthalf.filled").tag(ThemeMode.system)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Appearance", systemImage: state.themeMode.symbol)
            }
            .help("Appearance — light, dark, or follow system")
            .accessibilityIdentifier("toolbar.appearance")
        }

        // Zoom controls now live as a Freeform-style floating pill in the
        // bottom-left corner (see ZoomControlsPill in CanvasFloatingControls).
        // Menu shortcuts ⌘+ / ⌘− / ⌘0 / ⌘1 still work via the View menu.
    }

    private func bestPasteboardCandidate() -> String {
        guard let s = NSPasteboard.general.string(forType: .string) else { return "" }
        if TweetService.isLikelyTweetURL(s) { return s }
        if InstagramService.isLikelyInstagramURL(s) { return s }
        if YouTubeService.isLikelyYouTubeURL(s) { return s }
        return ""
    }
}

// MARK: - Draw options bar (color swatches + width)

struct DrawOptionsToolbar: View {
    @EnvironmentObject var state: CanvasState

    var body: some View {
        HStack(spacing: 10) {
            ForEach(StrokeColor.palette, id: \.self) { color in
                Button {
                    state.drawColor = color
                } label: {
                    Circle()
                        .fill(color.swiftUIColor)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    state.drawColor == color ? Color.primary : .clear,
                                    lineWidth: 2
                                )
                                .padding(-3)
                        )
                }
                .buttonStyle(.hover)
                .help("Draw color")
            }

            Divider().frame(height: 16)

            Stepper(value: $state.drawWidth, in: 1...12, step: 1) {
                Text("\(Int(state.drawWidth)) px")
                    .font(.system(.callout, design: .monospaced))
                    .frame(minWidth: 38)
            }
            .help("Stroke width")
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Add to Canvas sheet (Link OR Upload)

struct AddToCanvasSheet: View {
    let initialURL: String
    let onAddURL: (String) -> Void
    let onAddImage: (Data, String) -> Void
    let onAddVideo: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case link = "Link"
        case upload = "From Computer"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .link

    // Link-mode state.
    @State private var url: String = ""

    // Upload-mode state.
    @State private var pickedURL: URL? = nil
    @State private var pickedData: Data? = nil    // populated for images only
    @State private var pickedSizeBytes: Int64 = 0
    @State private var pickedKind: PickedKind? = nil
    @State private var pickError: String? = nil

    enum PickedKind { case image, video }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to canvas").font(.headline)

            Picker("Source", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch mode {
                case .link:   linkSection
                case .upload: uploadSection
                }
            }

            Divider()

            HStack {
                detailFooter
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryButtonTitle) { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if url.isEmpty { url = initialURL }
        }
    }

    // MARK: - Link section

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste a link from x.com, instagram.com, or youtube.com to embed it on the canvas.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://x.com/…, instagram.com/p/…, or youtube.com/watch?v=…", text: $url)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
        }
    }

    // MARK: - Upload section

    private var uploadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a local image or video.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Images: up to \(byteString(CanvasState.maxImageBytes)) and \(CanvasState.maxImagePixelDim) × \(CanvasState.maxImagePixelDim) px. Videos: up to \(byteString(CanvasState.maxVideoBytes)), \(Int(CanvasState.maxVideoDurationSeconds / 60)) min, and \(Int(CanvasState.maxVideoPixelDim)) × \(Int(CanvasState.maxVideoPixelDim)) px.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    chooseFile()
                } label: {
                    Label(pickedURL == nil ? "Choose File…" : "Choose Different File…",
                          systemImage: "folder")
                }

                if let pickedURL {
                    HStack(spacing: 6) {
                        Image(systemName: pickedKind == .video ? "film" : "photo")
                            .foregroundStyle(.secondary)
                        Text(pickedURL.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("(\(byteString(pickedSizeBytes)))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
                }
            }

            if let pickError {
                Label(pickError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Footer / submit

    @ViewBuilder
    private var detailFooter: some View {
        switch mode {
        case .link:
            if let badge = detectedKindLabel {
                Label(badge.title, systemImage: badge.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .upload:
            if let pickedKind {
                Label(pickedKind == .image ? "Image" : "Video",
                      systemImage: pickedKind == .image ? "photo" : "film")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var primaryButtonTitle: String {
        switch mode {
        case .link:   return "Add to Canvas"
        case .upload: return pickedKind == .video ? "Add Video" :
                             pickedKind == .image ? "Add Image" : "Add to Canvas"
        }
    }

    private var canSubmit: Bool {
        switch mode {
        case .link:
            return TweetService.isLikelyTweetURL(url)
                || InstagramService.isLikelyInstagramURL(url)
                || YouTubeService.isLikelyYouTubeURL(url)
        case .upload:
            return pickedURL != nil && pickError == nil
        }
    }

    private var detectedKindLabel: (title: String, icon: String)? {
        if TweetService.isLikelyTweetURL(url) { return ("X / Twitter post", "bird") }
        if InstagramService.isLikelyInstagramURL(url) { return ("Instagram", "camera") }
        if YouTubeService.isLikelyYouTubeURL(url) { return ("YouTube", "play.rectangle") }
        return nil
    }

    private func submit() {
        switch mode {
        case .link:
            let t = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            onAddURL(t)
            dismiss()
        case .upload:
            guard let pickedURL else { return }
            switch pickedKind {
            case .image:
                if let data = pickedData {
                    onAddImage(data, pickedURL.lastPathComponent)
                    dismiss()
                }
            case .video:
                onAddVideo(pickedURL)
                dismiss()
            case .none:
                break
            }
        }
    }

    // MARK: - File picking + validation

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an image or video"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        validate(url)
    }

    private func validate(_ fileURL: URL) {
        pickError = nil
        pickedURL = nil
        pickedData = nil
        pickedSizeBytes = 0
        pickedKind = nil

        let attrs = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let ext = fileURL.pathExtension.lowercased()
        let imageExts = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"]
        let videoExts = ["mp4", "mov", "m4v", "qt"]

        if imageExts.contains(ext) {
            guard size <= CanvasState.maxImageBytes else {
                pickError = "Image is too large. Maximum is \(byteString(CanvasState.maxImageBytes))."
                return
            }
            do {
                let data = try Data(contentsOf: fileURL)
                guard NSImage(data: data) != nil else {
                    pickError = "That file isn't a valid image."
                    return
                }
                pickedURL = fileURL
                pickedData = data
                pickedSizeBytes = size
                pickedKind = .image
            } catch {
                pickError = "Couldn't read the file."
            }
        } else if videoExts.contains(ext) {
            guard size <= CanvasState.maxVideoBytes else {
                pickError = "Video is too large. Maximum is \(byteString(CanvasState.maxVideoBytes))."
                return
            }
            pickedURL = fileURL
            pickedData = nil
            pickedSizeBytes = size
            pickedKind = .video
        } else {
            pickError = "Unsupported file type. Choose an image or video."
        }
    }

    private func byteString(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
