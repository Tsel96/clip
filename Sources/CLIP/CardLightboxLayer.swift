import SwiftUI
import AppKit

/// Full-screen "theater" lightbox for a single card (double-click to open).
/// Modeled on the GatherOS detail screen: a large centered card on the
/// left, a top toolbar (index / open / download / delete / close), and a
/// right-hand **details inspector** (3D-hover thumbnail + type badge,
/// quantized color palette with scheme variations, editable Name / URL /
/// note, heuristic Generate-prompt, metadata, real Tags + Auto-tag, and the
/// card's Pages). ← → navigate; Esc / ✕ / backdrop closes.
struct CardLightboxLayer: View {
    @EnvironmentObject var state: CanvasState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width of the right-hand details inspector; the card is centered in the
    /// remaining stage area to its left.
    private let inspectorWidth: CGFloat = 332

    // Eyedropper (image cards): pixel sampler + the color under the cursor.
    @State private var sampler: PixelSampler?
    @State private var pickPoint: CGPoint?
    @State private var pickColor: Color?
    @State private var pickCopied: String?

    /// 0 = card sits exactly over its on-canvas source rect; 1 = full centered.
    /// One spring-driven value derives the card's scale + offset AND the
    /// backdrop / chrome opacity — the whole transition is this single number
    /// (Apple Photos: one continuous progress drives the entire hero).
    @State private var progress: CGFloat = 0
    /// True only once the open animation has settled — gates the eyedropper so
    /// its hover tracking / `NSCursor` rect never thrash while the card moves.
    @State private var landed = false

    // Persistently mounted; the open/close gate lives inside the GeometryReader.
    // The grow/shrink is an explicit scale+offset from the card's measured
    // on-screen rect to the centered target, driven by `progress`
    // (matchedGeometryEffect can't animate across the split-view→overlay
    // boundary here). The source card stays hidden for the whole session and
    // reappears only when this layer unmounts — never a duplicate mid-flight.
    var body: some View {
        GeometryReader { geo in
            let layerOrigin = geo.frame(in: .global).origin
            ZStack {
                if let id = state.lightboxCardID, let node = state.nodeByID[id] {
                    let target = targetRect(in: geo.size, node: node)
                    let source = sourceLocal(layerOrigin: layerOrigin, fallback: target)
                    let shrink = source.width / max(1, target.width)
                    let scale = shrink + (1 - shrink) * progress
                    let dx = (source.midX - target.midX) * (1 - progress)
                    let dy = (source.midY - target.midY) * (1 - progress)

                    // Dimmed backdrop — opacity tracks progress; tap to close.
                    Color.black.opacity(0.92 * Double(progress))
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { state.closeLightbox() }

                    // The single hero card: laid out at its final (centered)
                    // size, then scaled + offset toward the source by progress.
                    heroCard(for: node, fitted: target.size)
                        .frame(width: target.width, height: target.height)
                        .scaleEffect(scale, anchor: .center)
                        .offset(x: dx, y: dy)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.trailing, inspectorWidth)
                        // Drive the grow on appear; reset on unmount so the next
                        // open starts from the source again.
                        .onAppear {
                            progress = 0; landed = false
                            withAnimation(state.lightboxHeroAnimation) { progress = 1 }
                        }
                        .onDisappear { progress = 0; landed = false }

                    // Chrome (inspector + toolbar + nav) fades with progress.
                    chrome(for: node)
                        .opacity(Double(progress))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(state.lightboxCardID != nil)
        // Close: shrink (progress→0) on the same spring, then unmount so the
        // on-canvas original reappears exactly as the hero vanishes.
        .onChange(of: state.lightboxClosing) { closing in
            guard closing else { return }
            landed = false
            withAnimation(state.lightboxHeroAnimation) { progress = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + state.lightboxCloseDuration) {
                state.finalizeLightboxClose()
            }
        }
        // Eyedropper sampler + the "landed" gate (interaction enabled only once
        // the grow has settled).
        .task(id: state.lightboxCardID) {
            landed = false; pickPoint = nil; pickColor = nil; sampler = nil
            guard let id = state.lightboxCardID, let n = state.nodeByID[id] else { return }
            async let built = PixelSampler.make(for: n)
            if !reduceMotion { try? await Task.sleep(nanoseconds: 420_000_000) }
            if Task.isCancelled { return }
            landed = true
            sampler = await built
        }
    }

    // MARK: - Hero card geometry

    /// The card's final (centered) rect within the stage area (window minus the
    /// inspector column), preserving aspect — also the transform's target.
    private func targetRect(in size: CGSize, node: CanvasNode) -> CGRect {
        let stageW = max(1, size.width - inspectorWidth)
        let aspect = node.width / max(1, state.renderedHeight(of: node))
        let fitted = aspectFit(aspect: aspect, maxW: stageW - 80, maxH: size.height - 100)
        return CGRect(x: (stageW - fitted.width) / 2,
                      y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// The on-canvas source rect (where the card lives) in this layer's local
    /// space. Falls back to a small centered rect if the canvas frame hasn't
    /// been measured yet, so the card still visibly grows.
    private func sourceLocal(layerOrigin: CGPoint, fallback: CGRect) -> CGRect {
        guard let s = state.lightboxSourceRect else {
            let w = fallback.width * 0.3, h = fallback.height * 0.3
            return CGRect(x: fallback.midX - w / 2, y: fallback.midY - h / 2,
                          width: w, height: h)
        }
        return CGRect(x: s.minX - layerOrigin.x, y: s.minY - layerOrigin.y,
                      width: s.width, height: s.height)
    }

    // MARK: - Center stage (the hero card)

    @ViewBuilder
    private func heroCard(for node: CanvasNode, fitted: CGSize) -> some View {
        // Eyedropper is live ONLY once landed — never while the card is
        // growing/shrinking (so hover tracking + the NSCursor rect can't thrash
        // as the card moves). The content is a static poster the whole time
        // (no live↔poster swap, so nothing pops mid-animation).
        let canPick = landed && sampler != nil
        CardContentView(node: node, isLive: false)
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 36, y: 16)
            // Eyedropper loupe follows the cursor over the sampled poster.
            .overlay {
                if canPick, let pt = pickPoint, let c = pickColor {
                    ColorLoupe(color: c, hex: PaletteExtractor.hex(c))
                        .position(x: min(max(pt.x, 36), fitted.width - 36),
                                  y: max(pt.y - 48, 32))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if let h = pickCopied {
                    Text("Copied \(h)")
                        .font(.clip(10.5)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.75), in: Capsule())
                        .padding(.top, 12).allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            // Eyedropper cursor via an AppKit cursor rect confined to this
            // frame — only after landing.
            .overlay {
                if canPick {
                    CursorRect(cursor: .eyedropper).allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                guard canPick else { return }
                switch phase {
                case .active(let p):
                    pickPoint = p
                    pickColor = sampler?.color(fx: p.x / fitted.width, fy: p.y / fitted.height)
                case .ended:
                    pickPoint = nil; pickColor = nil
                }
            }
            // Double-click the card closes the lightbox (shrinks back to its
            // spot); declared before the single tap so SwiftUI disambiguates —
            // single tap still copies the picked color once landed.
            .onTapGesture(count: 2) { state.closeLightbox() }
            .onTapGesture { if canPick { pickColorTapped() } }
    }

    // MARK: - Chrome (inspector + toolbar + nav)

    @ViewBuilder
    private func chrome(for node: CanvasNode) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            DetailsInspector(node: node)
                .id(node.id)
                .frame(width: inspectorWidth)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { topBar(node) }
        .overlay(alignment: .bottom) { navHint }
    }

    /// Click while the eyedropper is over a sampled image → copy the hex.
    private func pickColorTapped() {
        guard let c = pickColor else { return }   // no sampler: just swallow the tap
        let h = PaletteExtractor.hex(c)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(h, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { pickCopied = h }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            withAnimation(.easeOut(duration: 0.2)) { if pickCopied == h { pickCopied = nil } }
        }
    }

    private func aspectFit(aspect: CGFloat, maxW: CGFloat, maxH: CGFloat) -> CGSize {
        guard aspect > 0, maxW > 0, maxH > 0 else { return CGSize(width: 200, height: 200) }
        var w = maxW, h = w / aspect
        if h > maxH { h = maxH; w = h * aspect }
        return CGSize(width: w, height: h)
    }

    // MARK: - Top toolbar

    @ViewBuilder
    private func topBar(_ node: CanvasNode) -> some View {
        HStack(spacing: 14) {
            toolButton("chevron.backward", "Close  (Esc)") { state.closeLightbox() }
            if let pos = state.lightboxPosition {
                Text("\(pos.index) / \(pos.total)")
                    .font(.clip(11))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            if state.sourceURL(of: node) != nil {
                toolButton("arrow.up.forward.square", "Open source") {
                    if let s = state.sourceURL(of: node), let u = URL(string: s) {
                        NSWorkspace.shared.open(u)
                    }
                }
            }
            if let dl = downloadAction(node) {
                toolButton("arrow.down.to.line", "Download", action: dl)
            }
            toolButton("trash", "Delete card") { state.delete(id: node.id); state.closeLightbox() }
            toolButton("xmark", "Close  (Esc)") { state.closeLightbox() }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    @ViewBuilder
    private func toolButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .foregroundStyle(.white.opacity(0.8))
        .help(help)
    }

    @ViewBuilder
    private var navHint: some View {
        HStack(spacing: 8) {
            Button { state.lightboxStep(-1) } label: { Image(systemName: "arrow.left") }
            Button { state.lightboxStep(1) } label: { Image(systemName: "arrow.right") }
            Text("to navigate")
        }
        .buttonStyle(.hover)
        .font(.clip(10.5))
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
        .padding(.bottom, 18)
    }

    private func downloadAction(_ node: CanvasNode) -> (() -> Void)? {
        switch node.kind {
        case .image(let data, let filename):
            return {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = filename.isEmpty ? "image" : filename
                if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
            }
        case .video(let fileURL, _):
            return { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
        default:
            return nil
        }
    }
}

// MARK: - Details inspector

private struct DetailsInspector: View {
    @EnvironmentObject var state: CanvasState
    let node: CanvasNode

    @State private var name = ""
    @State private var link = ""
    @State private var note = ""
    @State private var prompt = ""
    @State private var showNote = false
    @State private var newTag = ""
    @State private var schemeIndex = 0
    @State private var tilt: CGSize = .zero          // hover-tilt offset
    @State private var paletteColors: [Color] = []
    @State private var paletteLoaded = false
    @State private var copiedHex: String?

    private var sourceLink: String { state.sourceURL(of: node) ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                thumbnail
                paletteSection
                field("Name", text: $name, placeholder: "Untitled") { state.setNodeName(node.id, name) }
                urlField
                noteSection
                promptSection
                metadataSection
                chipSection(icon: "folder", title: "Collections", chips: ["Typography"])
                pagesSection
                tagSection
                Spacer(minLength: 8)
            }
            .padding(18)
        }
        .background(Color(red: 0.13, green: 0.11, blue: 0.10))
        .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.06)).frame(width: 1) }
        .onAppear {
            name = node.name ?? ""
            link = node.linkURL ?? sourceLink
            note = node.note ?? ""
            prompt = node.imagePrompt ?? ""
            showNote = !(node.note ?? "").isEmpty
        }
        .task(id: node.id) {
            paletteLoaded = false
            paletteColors = await PaletteExtractor.colorsAsync(for: node, count: 8)
            paletteLoaded = true
        }
    }

    private var header: some View {
        HStack {
            Text("Details").clipLabel(10.5).foregroundStyle(.white.opacity(0.5))
            Spacer()
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: Thumbnail with 3D hover tilt

    private var thumbnail: some View {
        GeometryReader { geo in
            let maxAngle = 9.0
            let ax = Double(-tilt.height / max(1, geo.size.height / 2)) * maxAngle
            let ay = Double(tilt.width / max(1, geo.size.width / 2)) * maxAngle
            ZStack(alignment: .topTrailing) {
                CardContentView(node: node, isLive: false)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(kindBadge)
                    .clipLabel(8.5).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }
            .rotation3DEffect(.degrees(ax), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(ay), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .scaleEffect(tilt == .zero ? 1 : 1.03)
            .shadow(color: .black.opacity(tilt == .zero ? 0.25 : 0.45),
                    radius: tilt == .zero ? 8 : 18, y: tilt == .zero ? 4 : 12)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    tilt = CGSize(width: p.x - geo.size.width / 2,
                                  height: p.y - geo.size.height / 2)
                case .ended:
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { tilt = .zero }
                }
            }
        }
        .frame(height: 200)
    }

    // MARK: Palette + variation remix

    @ViewBuilder
    private var paletteSection: some View {
        let scheme = PaletteExtractor.scheme(schemeIndex, base: paletteColors)
        if !paletteColors.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    ForEach(Array(scheme.colors.prefix(8).enumerated()), id: \.offset) { _, c in
                        Circle().fill(c).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                            .contentShape(Circle())
                            .onTapGesture { copySwatch(c) }
                            .help("Click to copy \(PaletteExtractor.hex(c))")
                    }
                }
                .overlay(alignment: .top) {
                    if let h = copiedHex {
                        Text("Copied \(h)")
                            .font(.clip(9.5)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.75), in: Capsule())
                            .offset(y: -24)
                            .transition(.opacity)
                    }
                }
                variationButton(scheme.name)
            }
        } else if !paletteLoaded {
            HStack(spacing: 7) {
                ForEach(0..<8, id: \.self) { _ in
                    Circle().fill(.white.opacity(0.08)).frame(width: 20, height: 20)
                }
            }
        }
    }

    private func variationButton(_ name: String) -> some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { schemeIndex += 1 } } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                Text(schemeIndex == 0 ? "Generate variation" : "Variation · \(name)")
                    .font(.clip(12))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .foregroundStyle(.white.opacity(0.9))
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.hover)
        .help("Cycle color-scheme variations derived from this image")
    }

    private func copySwatch(_ c: Color) {
        let h = PaletteExtractor.hex(c)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(h, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copiedHex = h }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            withAnimation(.easeOut(duration: 0.2)) { if copiedHex == h { copiedHex = nil } }
        }
    }

    // MARK: Editable fields

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String,
                       commit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.clip(9)).foregroundStyle(.white.opacity(0.4))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(.clip(12.5)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .onSubmit(commit)
                .onChange(of: text.wrappedValue) { _ in commit() }
        }
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("URL").font(.clip(9)).foregroundStyle(.white.opacity(0.4))
            HStack(spacing: 6) {
                TextField("https://…", text: $link)
                    .textFieldStyle(.plain).font(.clip(12.5)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .onChange(of: link) { v in
                        // Persist only an override that differs from the post's source.
                        state.setNodeLinkURL(node.id, v == sourceLink ? "" : v)
                    }
                if let u = URL(string: link), !link.isEmpty {
                    Button { NSWorkspace.shared.open(u) } label: {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.hover).foregroundStyle(.white.opacity(0.8))
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .help("Open URL")
                }
            }
        }
    }

    @ViewBuilder
    private var noteSection: some View {
        if showNote {
            field("Note", text: $note, placeholder: "Add a note…") { state.setNodeNote(node.id, note) }
        } else {
            Button { showNote = true } label: {
                Label("Add a note", systemImage: "plus")
                    .font(.clip(12)).foregroundStyle(.white.opacity(0.6))
            }.buttonStyle(.hover)
        }
    }

    // MARK: Image prompt (heuristic)

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Image Prompt", systemImage: "sparkles")
                .font(.clip(10.5)).foregroundStyle(.white.opacity(0.55))
            Button {
                prompt = state.generatePrompt(for: node)
                state.setNodeImagePrompt(node.id, prompt)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                    Text("Generate prompt").font(.clip(12))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .foregroundStyle(.white.opacity(0.9))
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.hover)

            if !prompt.isEmpty {
                TextEditor(text: $prompt)
                    .font(.clip(12)).foregroundStyle(.white.opacity(0.85))
                    .scrollContentBackground(.hidden)
                    .frame(height: 72)
                    .padding(8)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .onChange(of: prompt) { v in state.setNodeImagePrompt(node.id, v) }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.clip(10.5))
                        .foregroundStyle(.white.opacity(0.6))
                }.buttonStyle(.hover)
            }
        }
    }

    @ViewBuilder
    private var metadataSection: some View {
        let rows = NodeMetadata.rows(for: node)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.label) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.label).font(.clip(10.5)).foregroundStyle(.white.opacity(0.4))
                            .frame(width: 78, alignment: .leading)
                        Text(row.value).font(.clip(10.5)).foregroundStyle(.white.opacity(0.75))
                            .lineLimit(2).truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func chipSection(icon: String, title: String, chips: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.clip(10.5)).foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 6) {
                chip("+ Add", filled: false)
                ForEach(chips, id: \.self) { chip($0, filled: true) }
            }
        }
    }

    // Pages — the actual page this card lives on.
    private var pagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Pages", systemImage: "doc").font(.clip(10.5)).foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 6) {
                if let p = state.pageName(forCard: node.id) { chip(p, filled: true) }
            }
        }
    }

    // Tags — real, removable, with inline add + heuristic auto-tag.
    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Tags", systemImage: "number").font(.clip(10.5)).foregroundStyle(.white.opacity(0.55))
            FlowChips {
                ForEach(node.tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text("#\(tag)").font(.clip(10.5))
                        Button { state.removeTag(node.id, tag) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.hover).font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.white.opacity(0.10), in: Capsule(style: .continuous))
                }
                Button { state.autoTag(node.id) } label: {
                    Label("Auto-tag", systemImage: "sparkles").font(.clip(10.5))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.white.opacity(0.06), in: Capsule(style: .continuous))
                }.buttonStyle(.hover)
            }
            TextField("Add tag…", text: $newTag)
                .textFieldStyle(.plain).font(.clip(12)).foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .onSubmit { state.addTag(node.id, newTag); newTag = "" }
        }
    }

    private func chip(_ text: String, filled: Bool) -> some View {
        Text(text).font(.clip(10.5))
            .foregroundStyle(.white.opacity(filled ? 0.85 : 0.55))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.white.opacity(filled ? 0.10 : 0.05), in: Capsule(style: .continuous))
    }

    private var kindBadge: String {
        switch node.kind {
        case .image:     return "JPEG"
        case .video:     return "VIDEO"
        case .tweet:     return "X"
        case .instagram: return "IG"
        case .youtube:   return "YT"
        case .text:      return "TEXT"
        case .stickyNote: return "NOTE"
        case .drawing:   return "DRAW"
        case .section:   return "SECTION"
        }
    }
}

/// Simple wrapping HStack for tag chips.
private struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        // A lightweight wrap using a vertical stack of HStacks is overkill;
        // SwiftUI's native wrapping via `Layout` keeps it simple here.
        FlowLayout(spacing: 6) { content }
    }
}

/// Minimal flow layout (wraps children to the next line).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW { x = 0; y += lineH + spacing; lineH = 0 }
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + lineH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX { x = bounds.minX; y += lineH + spacing; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
    }
}

// MARK: - Shared per-kind content renderer

struct CardContentView: View {
    @EnvironmentObject var state: CanvasState
    let node: CanvasNode
    var isLive: Bool = true

    var body: some View {
        switch node.kind {
        case .tweet(let url):       TweetCardView(url: url, isLive: isLive)
        case .instagram(let url):   InstagramCardView(url: url, isLive: isLive)
        case .youtube(let url):     YouTubeNodeView(url: url, isLive: isLive)
        case .image(let data, let filename):
            ImageNodeView(data: data, filename: filename, isLive: isLive)
        case .video(let fileURL, let filename):
            VideoNodeView(fileURL: fileURL, filename: filename, isLive: isLive,
                          trimStart: node.trimStart, trimEnd: node.trimEnd)
        case .text(let content, let fontSize):
            TextNodeView(nodeID: node.id, content: content, fontSize: fontSize, isSelected: false)
        case .drawing(let stroke):
            DrawingNodeView(stroke: stroke,
                            size: CGSize(width: node.width, height: node.height ?? 100),
                            onDelete: {})
        case .section(let title, let color):
            SectionNodeView(node: node, title: title, color: color)
        case .stickyNote(let content, let color):
            StickyNodeView(node: node, content: content, color: color)
        }
    }
}

// MARK: - Palette extraction + color schemes

// MARK: - Eyedropper pixel sampler + loupe

/// Samples a node's image into a top-left-origin RGBX buffer so the
/// lightbox eyedropper can read the color under the cursor in O(1).
/// Image cards only.
struct PixelSampler {
    let w: Int
    let h: Int
    let px: [UInt8]   // RGBX, row-major, top-left origin

    /// Build a sampler from a node's representative image — local image,
    /// tweet poster, IG og:image, YouTube thumbnail, or video frame. Works
    /// for any card with an image (not just local image cards).
    static func make(for node: CanvasNode, maxDim: Int = 1400) async -> PixelSampler? {
        guard let cg = await ColorExtraction.representativeCGImage(for: node) else { return nil }
        return fromCGImage(cg, maxDim: maxDim)
    }

    private static func fromCGImage(_ cg: CGImage, maxDim: Int) -> PixelSampler? {
        let scale = min(1.0, Double(maxDim) / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * scale))
        let h = max(1, Int(Double(cg.height) * scale))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        // Flip so buffer row 0 == top of image (matches SwiftUI's y-down).
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return PixelSampler(w: w, h: h, px: buf)
    }

    /// Color at a normalized (0…1, top-left) coordinate.
    func color(fx: Double, fy: Double) -> Color? {
        guard w > 0, h > 0 else { return nil }
        let x = min(w - 1, max(0, Int(fx * Double(w))))
        let y = min(h - 1, max(0, Int(fy * Double(h))))
        let o = (y * w + x) * 4
        return Color(.sRGB,
                     red: Double(px[o]) / 255.0,
                     green: Double(px[o + 1]) / 255.0,
                     blue: Double(px[o + 2]) / 255.0)
    }
}

/// The eyedropper readout that follows the cursor — a color disc + hex.
private struct ColorLoupe: View {
    let color: Color
    let hex: String
    var body: some View {
        VStack(spacing: 4) {
            Circle().fill(color)
                .frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(.white.opacity(0.95), lineWidth: 2))
                .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
            Text(hex)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.72), in: Capsule())
        }
    }
}

enum PaletteExtractor {
    /// Distinct dominant colors via coarse RGB-bucket quantization (top
    /// buckets, near-duplicates merged). Empty for non-image kinds.
    /// Sync palette — local image cards only. Used by auto-tag / prompt
    /// (must not block on the network).
    static func colors(for node: CanvasNode, count: Int) -> [Color] {
        guard case .image(let data, _) = node.kind,
              let cg = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return [] }
        return quantize(cg, count: count)
    }

    /// Async palette for ANY card that has a representative image — local
    /// image, tweet poster, Instagram og:image, YouTube thumbnail, or a
    /// video frame (fetched via `ColorExtraction`). Empty for text/sticky/
    /// drawing/section.
    static func colorsAsync(for node: CanvasNode, count: Int) async -> [Color] {
        guard let cg = await ColorExtraction.representativeCGImage(for: node) else { return [] }
        return quantize(cg, count: count)
    }

    /// `#RRGGBB` for a swatch (click-to-copy).
    static func hex(_ color: Color) -> String {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }

    /// Coarse RGB-bucket quantizer → up to `count` distinct dominant colors.
    static func quantize(_ cg: CGImage, count: Int) -> [Color] {
        let dim = 32
        var px = [UInt8](repeating: 0, count: dim * dim * 4)
        guard let ctx = CGContext(
            data: &px, width: dim, height: dim, bitsPerComponent: 8,
            bytesPerRow: dim * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: dim, height: dim))

        var buckets: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
        for i in stride(from: 0, to: dim * dim * 4, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            var e = buckets[key] ?? (0, 0, 0, 0)
            e.n += 1; e.r += r; e.g += g; e.b += b
            buckets[key] = e
        }
        let ranked: [(n: Int, c: (Double, Double, Double))] = buckets.values
            .map { e in
                let nd = Double(e.n)
                let avg = (Double(e.r) / nd / 255.0,
                           Double(e.g) / nd / 255.0,
                           Double(e.b) / nd / 255.0)
                return (n: e.n, c: avg)
            }
            .sorted { $0.n > $1.n }

        var picked: [(Double, Double, Double)] = []
        for s in ranked where picked.allSatisfy({ dist($0, s.c) > 0.012 }) {
            picked.append(s.c)
            if picked.count >= count { break }
        }
        return picked.map { Color(.sRGB, red: $0.0, green: $0.1, blue: $0.2) }
    }

    private static func dist(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
        return dr * dr + dg * dg + db * db
    }

    /// Nearest named color — used for auto-tags and prompt synthesis.
    static func colorName(_ color: Color) -> String {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return "neutral" }
        let r = Double(ns.redComponent), g = Double(ns.greenComponent), b = Double(ns.blueComponent)
        let named: [(String, (Double, Double, Double))] = [
            ("black", (0, 0, 0)), ("white", (1, 1, 1)), ("gray", (0.5, 0.5, 0.5)),
            ("red", (0.85, 0.15, 0.15)), ("orange", (0.95, 0.55, 0.15)), ("yellow", (0.95, 0.85, 0.25)),
            ("green", (0.2, 0.65, 0.3)), ("teal", (0.2, 0.6, 0.6)), ("blue", (0.2, 0.4, 0.85)),
            ("purple", (0.5, 0.3, 0.7)), ("pink", (0.9, 0.5, 0.7)), ("brown", (0.5, 0.35, 0.2)),
            ("cream", (0.93, 0.9, 0.82)),
        ]
        var best = "neutral"; var bestD = Double.greatestFiniteMagnitude
        for (name, c) in named {
            let d = (r - c.0) * (r - c.0) + (g - c.1) * (g - c.1) + (b - c.2) * (b - c.2)
            if d < bestD { bestD = d; best = name }
        }
        return best
    }

    /// Color-scheme variations derived from the palette's dominant color.
    static func scheme(_ index: Int, base: [Color]) -> (name: String, colors: [Color]) {
        guard let first = base.first else { return ("Extracted", base) }
        let hsb = hsbOf(first)
        func wrap(_ x: Double) -> Double { let m = x.truncatingRemainder(dividingBy: 1); return m < 0 ? m + 1 : m }
        func hues(_ offs: [Double]) -> [Color] {
            offs.map { Color(hue: wrap(hsb.h + $0), saturation: hsb.s, brightness: hsb.b) }
        }
        switch index % 5 {
        case 0: return ("Extracted", base)
        case 1: return ("Analogous", hues([-0.08, -0.04, 0, 0.04, 0.08]))
        case 2: return ("Complementary", hues([0, 0.04, 0.5, 0.54, 0.46]))
        case 3: return ("Triadic", hues([0, 0.333, 0.667, 0.166, 0.833]))
        default:
            return ("Shades", (0..<6).map {
                Color(hue: hsb.h, saturation: hsb.s,
                      brightness: max(0.15, min(0.95, hsb.b - 0.35 + Double($0) * 0.14)))
            })
        }
    }

    private static func hsbOf(_ color: Color) -> (h: Double, s: Double, b: Double) {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return (0, 0.5, 0.5) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }
}

// MARK: - Cursor rect

/// Applies a custom `NSCursor` to exactly the bounds of this view via an
/// AppKit cursor rect. Unlike `NSCursor.push()` on a SwiftUI hover (which
/// AppKit resets on every mouse-move so it never visually sticks), a cursor
/// rect is managed by the window: the cursor changes on enter and reverts on
/// exit, and is strictly confined to the rect — so it can't leak onto the
/// surrounding toolbar / inspector buttons.
private struct CursorRect: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorRectNSView {
        let v = CursorRectNSView()
        v.cursor = cursor
        return v
    }

    func updateNSView(_ nsView: CursorRectNSView, context: Context) {
        nsView.cursor = cursor
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    final class CursorRectNSView: NSView {
        var cursor: NSCursor = .arrow

        // Transparent to mouse events so the SwiftUI tap-to-copy gesture
        // underneath still fires; cursor rects work regardless of hit-testing.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: cursor)
        }
    }
}

// MARK: - Eyedropper cursor

extension NSCursor {
    /// A custom color-picker cursor (eyedropper glyph) used while sampling a
    /// color from a card in the lightbox. Built once from the `eyedropper`
    /// SF Symbol, rendered white with a dark outline so it reads on any
    /// background; the hotspot sits at the dropper's bottom-left tip.
    static let eyedropper: NSCursor = makeEyedropperCursor()

    private static func makeEyedropperCursor() -> NSCursor {
        let side: CGFloat = 24
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "eyedropper",
                                   accessibilityDescription: "Color picker")?
            .withSymbolConfiguration(cfg) else {
            return .crosshair
        }

        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        let symSize = symbol.size
        let rect = NSRect(x: (side - symSize.width) / 2,
                          y: (side - symSize.height) / 2,
                          width: symSize.width, height: symSize.height)

        // Dark outline (draw the tinted symbol offset in 8 directions) so the
        // glyph stays visible on light backgrounds…
        if let dark = symbol.tinted(with: .black) {
            for dx in [-1.0, 0.0, 1.0] {
                for dy in [-1.0, 0.0, 1.0] where !(dx == 0 && dy == 0) {
                    dark.draw(in: rect.offsetBy(dx: dx, dy: dy),
                              from: .zero, operation: .sourceOver, fraction: 0.9)
                }
            }
        }
        // …then the white fill on top.
        (symbol.tinted(with: .white) ?? symbol)
            .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()

        // Hotspot at the bottom-left tip of the dropper (image coords are
        // top-left origin for the hotspot).
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: side - 3))
    }
}

private extension NSImage {
    /// Returns a copy of the (template) symbol tinted with a solid color.
    func tinted(with color: NSColor) -> NSImage? {
        guard let copy = self.copy() as? NSImage else { return nil }
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }
}
