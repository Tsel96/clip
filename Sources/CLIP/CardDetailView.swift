import AppKit
import AVFoundation

// MARK: - Native detail view (Spatial CanvasTransition* 1:1)

/// Fully-native (AppKit) detail / "theater" view for one card — mirrors
/// Spatial's `CanvasTransitionImageView` layout: a clean white stage with the
/// content morphing up from its on-canvas rect, a vertical `ColorPaletteView`
/// on the left, an `ImageMetadataView` on the right, a "Write a note…" field
/// under the content, and a floating black toolbar pill at the bottom. No
/// SwiftUI views — every control is an NSView, so there is no hidden gesture /
/// re-render surface to regress.
final class CardDetailView: NSView {
    override var isFlipped: Bool { true }

    // Callbacks to the model (set by the host each update).
    var onClose: () -> Void = {}
    var onDelete: () -> Void = {}
    var onDuplicate: () -> Void = {}
    var onDownload: (() -> Void)?
    var onSaveNote: (String) -> Void = { _ in }
    var onStep: (Int) -> Void = { _ in }
    var onOpenLink: (String) -> Void = { _ in }

    private(set) var presentedID: UUID?

    // Chrome
    private let backdrop = NSView()
    private let contentClip = NSView()                 // shadow host; transformed as ONE unit
    private let imageLayer = CALayer()                 // rounded media / poster (sublayer of contentClip)
    private let playerLayer = AVPlayerLayer()          // live video, morphs with imageLayer
    private var player: AVQueuePlayer?                 // retains the looping player
    private var looper: AVPlayerLooper?
    private var itemObs: NSKeyValueObservation?        // logs load failures, kicks play on ready
    private let paletteColumn = NSStackView()
    private let metadataColumn = NSStackView()
    private let noteField = NSTextField()
    private let toolbar = ToolbarPill()
    private let backButton = HoverIconButton(symbol: "arrow.left")

    private var node: CanvasNode?
    private var sourceRect: CGRect?                    // window coords
    private var contentAspect: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Spatial's detail view is ALWAYS light, regardless of the app theme.
        appearance = NSAppearance(named: .aqua)
        setupChrome()
        isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Setup

    private func setupChrome() {
        backdrop.wantsLayer = true
        // Figma: pure white background.
        backdrop.layer?.backgroundColor = NSColor.white.cgColor
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        // Click the empty backdrop to close.
        let bgClick = NSClickGestureRecognizer(target: self, action: #selector(closeTapped))
        backdrop.addGestureRecognizer(bgClick)

        // The morphing content is a SINGLE layer subtree (shadow host +
        // rounded image sublayer) so one transform animation scales the whole
        // thing — image AND shadow — as one continuous unit (Spatial's hero).
        // Animating frames/shadowPath separately is what looked chaotic + ugly.
        contentClip.wantsLayer = true
        contentClip.layer?.masksToBounds = false
        contentClip.shadow = NSShadow()
        contentClip.layer?.shadowColor = NSColor.black.cgColor
        contentClip.layer?.shadowOpacity = 0.10
        contentClip.layer?.shadowRadius = 18
        contentClip.layer?.shadowOffset = CGSize(width: 0, height: 10)
        imageLayer.cornerRadius = Self.contentRadius
        imageLayer.cornerCurve = .continuous
        imageLayer.masksToBounds = true
        imageLayer.backgroundColor = NSColor.white.cgColor
        imageLayer.contentsGravity = .resizeAspect
        contentClip.layer?.addSublayer(imageLayer)
        // Live video sits ON TOP of the poster (imageLayer) inside the same
        // morphing layer, so it scales as one unit during the hero transition.
        // Hidden until the morph settles — AVPlayerLayer renders black under a
        // running transform, so we keep the poster visible through the morph.
        playerLayer.cornerRadius = Self.contentRadius
        playerLayer.cornerCurve = .continuous
        playerLayer.masksToBounds = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.isHidden = true
        contentClip.layer?.addSublayer(playerLayer)
        addSubview(contentClip)

        paletteColumn.orientation = .vertical
        paletteColumn.spacing = 12
        paletteColumn.alignment = .centerX
        paletteColumn.wantsLayer = true
        paletteColumn.layer?.masksToBounds = false     // don't clip a hover-scaled swatch
        addSubview(paletteColumn)

        metadataColumn.orientation = .vertical
        metadataColumn.spacing = 22
        metadataColumn.alignment = .leading
        addSubview(metadataColumn)

        noteField.isBordered = false
        noteField.drawsBackground = false
        noteField.focusRingType = .none
        noteField.font = .systemFont(ofSize: 14)
        noteField.textColor = .labelColor
        noteField.placeholderString = "Write a note…"
        noteField.target = self
        noteField.action = #selector(noteCommitted)
        noteField.alignment = .center
        addSubview(noteField)

        backButton.setSymbol("arrow.left", pointSize: 19)
        backButton.onClick = { [weak self] in self?.onClose() }
        addSubview(backButton)

        addSubview(toolbar)
    }

    // MARK: Present / dismiss (hero morph)

    func present(node: CanvasNode, sourceRect: CGRect?) {
        self.node = node
        self.sourceRect = sourceRect
        presentedID = node.id
        isHidden = false

        rebuildContent(for: node)
        rebuildPalette(for: node)
        rebuildMetadata(for: node)
        noteField.stringValue = node.note ?? ""
        rebuildToolbar()
        needsLayout = true
        layoutSubtreeIfNeeded()

        // ONE continuous spring: the content layer (image + shadow) sits at its
        // final target and is transformed from the card's on-canvas rect to
        // identity — a single, fluid morph (Spatial's CanvasTransitionView).
        backdrop.layer?.opacity = 0
        setChromeAlpha(0)
        layoutContent()                                   // place at target, shadowPath set
        guard let layer = contentClip.layer else { return }
        layer.removeAnimation(forKey: "morph")
        // Spring from the card's on-canvas rect → identity. `from` is passed
        // EXPLICITLY (not read from presentation()) because right after a model
        // set the presentation layer still reports the old identity, which made
        // the spring animate identity→identity → the card just popped in.
        springTransform(to: CATransform3DIdentity, key: "morph", from: sourceTransform())
        // Backdrop gray→white + chrome fade in concurrently with the morph.
        CLIPSpring.run(duration: 0.30, curve: CLIPSpring.easeOutSoft) { [weak self] in
            self?.backdrop.layer?.opacity = 1
            self?.setChromeAlpha(1)
        }
    }

    func dismiss(then: @escaping () -> Void = {}) {
        guard presentedID != nil else { then(); return }
        presentedID = nil
        contentClip.layer?.removeAnimation(forKey: "morph")
        springTransform(to: sourceTransform(), key: "morph")
        CLIPSpring.run(duration: 0.22, curve: CLIPSpring.easeOutSoft, { [weak self] in
            self?.backdrop.layer?.opacity = 0
            self?.setChromeAlpha(0)
        }, completion: { [weak self] in
            guard let self, self.presentedID == nil else { return }
            self.isHidden = true
            self.contentClip.layer?.transform = CATransform3DIdentity
            self.teardownPlayer()                          // free the decoder on close
            then()
        })
    }

    static let contentRadius: CGFloat = 8

    private func roundedPath(_ size: CGSize) -> CGPath {
        CGPath(roundedRect: CGRect(origin: .zero, size: size),
               cornerWidth: Self.contentRadius, cornerHeight: Self.contentRadius, transform: nil)
    }

    /// Transform that places the (target-sized) content layer over the card's
    /// on-canvas rect: scale about the layer's centre + translate centres.
    ///
    /// `sourceRect` is in SwiftUI's `.global` space (top-left origin), and this
    /// flipped view fills the window from that same origin, so it IS already our
    /// local space. (Running it through `convert(from: nil)` — AppKit window-base,
    /// bottom-left — vertically MIRRORED the start, which is why the morph used to
    /// fly in from the wrong side.)
    private func sourceTransform() -> CATransform3D {
        let target = contentTargetRect()
        guard let src = sourceRect, target.width > 1 else {
            return CATransform3DIdentity
        }
        let s = max(0.05, src.width / target.width)
        let c = CGPoint(x: target.width / 2, y: target.height / 2)
        let scaleAboutCenter = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-c.x, -c.y, 0),
                                CATransform3DMakeScale(s, s, 1)),
            CATransform3DMakeTranslation(c.x, c.y, 0))
        let dx = src.midX - target.midX, dy = src.midY - target.midY
        return CATransform3DConcat(scaleAboutCenter, CATransform3DMakeTranslation(dx, dy, 0))
    }

    private func springTransform(to value: CATransform3D, key: String, from: CATransform3D? = nil) {
        guard let layer = contentClip.layer else { return }
        let start = from ?? layer.presentation()?.transform ?? layer.transform
        let a = CASpringAnimation(keyPath: "transform")
        a.fromValue = start
        a.toValue = value
        a.stiffness = CLIPSpring.Preset.hero.stiffness
        a.damping = CLIPSpring.Preset.hero.caDamping
        a.mass = 1
        a.duration = a.settlingDuration
        a.fillMode = .forwards
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = value                          // commit final model, no implicit anim
        CATransaction.commit()
        layer.add(a, forKey: key)
    }

    /// Place the content layer at its target (frame + image + shadow path), no
    /// animation — the morph is done purely with `transform`.
    private func layoutContent() {
        let target = contentTargetRect()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        contentClip.frame = target
        imageLayer.frame = CGRect(origin: .zero, size: target.size)
        playerLayer.frame = imageLayer.frame
        contentClip.layer?.shadowPath = roundedPath(target.size)
        CATransaction.commit()
    }

    private func setChromeAlpha(_ a: CGFloat) {
        for v in [paletteColumn, metadataColumn, noteField, toolbar, backButton] { v.alphaValue = a }
    }

    // MARK: Content

    private func rebuildContent(for node: CanvasNode) {
        // The media is the image LAYER's `contents` (a CGImage) — so the single
        // morph transform scales it with the shadow as one unit. Local images
        // load synchronously; other kinds resolve a representative frame async.
        teardownPlayer()
        imageLayer.contents = nil
        if case .image(let data, _) = node.kind, let img = NSImage(data: data),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            imageLayer.contents = cg
            contentAspect = CGFloat(cg.width) / CGFloat(max(1, cg.height))
        } else {
            contentAspect = node.width / max(1, node.height ?? node.width)
            Task { @MainActor in
                guard let cg = await ColorExtraction.representativeCGImage(for: node),
                      presentedID == node.id else { return }
                imageLayer.contents = cg
                contentAspect = CGFloat(cg.width) / CGFloat(max(1, cg.height))
                layoutContent()
            }
        }
        // Videos keep playing in the detail view: loop muted on an AVPlayerLayer
        // that morphs with the poster. Revealed after the hero morph settles so
        // the transition shows the (sharp) poster, not a black AVPlayerLayer.
        if case .video(let fileURL, _) = node.kind {
            mountPlayer(url: fileURL)
        }
    }

    private func mountPlayer(url: URL) {
        // Canonical loop: an EMPTY queue player driven by an AVPlayerLooper
        // (matches TweetVideoPlayer). Honours the node's non-destructive trim.
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.automaticallyWaitsToMinimizeStalling = false   // start a local file now, don't buffer-wait
        if let s = node?.trimStart, let e = node?.trimEnd, e > s {
            let range = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                                    end: CMTime(seconds: e, preferredTimescale: 600))
            looper = AVPlayerLooper(player: queue, templateItem: item, timeRange: range)
        } else {
            looper = AVPlayerLooper(player: queue, templateItem: item)
        }
        playerLayer.backgroundColor = NSColor.clear.cgColor   // poster shows through until first frame
        playerLayer.player = queue
        player = queue
        // The AVPlayerLayer is transparent until the first frame, so reveal it
        // immediately: the poster shows through underneath until the video
        // paints, then it loops on top. (A CALayer transform — unlike SwiftUI's
        // .scaleEffect — scales an AVPlayerLayer cleanly, so no black flash.)
        playerLayer.isHidden = false
        queue.play()
        // Surface load failures (codec/permissions) and kick playback once the
        // item is actually ready — a queue.play() before readiness can no-op.
        itemObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                switch it.status {
                case .failed:      NSLog("CLIP detail: video FAILED — \(String(describing: it.error))")
                case .readyToPlay: self?.player?.play()
                default:           break
                }
            }
        }
    }

    private func teardownPlayer() {
        itemObs?.invalidate(); itemObs = nil
        player?.pause()
        looper = nil
        player = nil
        playerLayer.player = nil
        playerLayer.isHidden = true
    }

    // MARK: Palette (left) — color circles with haptic-on-hover + click-to-copy

    private func rebuildPalette(for node: CanvasNode) {
        paletteColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let d = D.swatch * scale
        Task { @MainActor in
            let colors = await NativePalette.colors(for: node, count: 6)
            guard presentedID == node.id else { return }
            for c in colors {
                paletteColumn.addArrangedSubview(ColorSwatch(color: c, diameter: d))
            }
            needsLayout = true
        }
    }

    // MARK: Metadata (right) — RESOLUTION / FILENAME / DATE, Spatial style

    private func rebuildMetadata(for node: CanvasNode) {
        metadataColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let fs = 11 * scale
        for row in detailMetadata(for: node) {
            let onClick: (() -> Void)? = row.link.map { url in { [weak self] in self?.onOpenLink(url) } }
            metadataColumn.addArrangedSubview(
                MetadataRowView(label: row.label, value: row.value, fontSize: fs, onClick: onClick))
        }
    }

    /// The Figma's RESOLUTION / LINK / DATE rows, derived from the node. The LINK
    /// row carries its raw URL so the value (with ↗) opens the original on click.
    private func detailMetadata(for node: CanvasNode) -> [(label: String, value: String, link: String?)] {
        var rows: [(label: String, value: String, link: String?)] = []
        // RESOLUTION — pixel dimensions for image.
        if case .image(let data, _) = node.kind, let img = NSImage(data: data) {
            let rep = img.representations.first
            let w = rep?.pixelsWide ?? Int(img.size.width)
            let h = rep?.pixelsHigh ?? Int(img.size.height)
            if w > 0, h > 0 { rows.append(("Resolution", "\(w) × \(h)", nil)) }
        }
        // LINK — source URL, shown compactly as host + ↗, clickable to open.
        if let url = nodeSourceURL(node), let host = URLComponents(string: url)?.host {
            rows.append(("Link", "\(host) ↗", url))
        }
        // DATE — when the card was added.
        let df = DateFormatter(); df.dateFormat = "MMMM d, HH:mm"
        rows.append(("Date", "Created on \(df.string(from: node.addedAt))", nil))
        // Fallback: show the kind for content with no resolution/link.
        if rows.count == 1 { rows.insert(("Type", kindLabel(node.kind), nil), at: 0) }
        return rows
    }

    private func kindLabel(_ kind: CanvasNode.Kind) -> String {
        switch kind {
        case .tweet:     return "Tweet"
        case .instagram: return "Instagram"
        case .youtube:   return "YouTube"
        case .webclip:   return "Web"
        case .image:     return "Image"
        case .video:     return "Video"
        case .text:      return "Text"
        case .drawing:   return "Drawing"
        case .section:   return "Section"
        case .stickyNote: return "Note"
        }
    }

    private func nodeSourceURL(_ node: CanvasNode) -> String? {
        switch node.kind {
        case .tweet(let u), .youtube(let u), .instagram(let u), .webclip(let u): return u
        default: return node.linkURL
        }
    }

    private func rebuildToolbar() {
        toolbar.setButtons([
            .init(symbol: "square.on.square", help: "Duplicate") { [weak self] in self?.onDuplicate() },
            .init(symbol: "arrow.down.to.line", help: "Download", enabled: onDownload != nil) { [weak self] in self?.onDownload?() },
            .init(symbol: "trash", help: "Delete") { [weak self] in self?.onDelete() },
        ])
    }

    // MARK: Layout — Figma "CLIP Detailed view" (1710×1074), scaled to the window

    /// Uniform scale that maps the 1710×1074 Figma frame into the current window,
    /// centered. Every element is placed at its exact design coordinate × scale.
    private enum D {                                  // design constants (pt @ 1×)
        static let frame = CGSize(width: 1710, height: 1074)
        static let contentTop: CGFloat = 112          // content slot origin
        static let contentMaxW: CGFloat = 560
        static let contentMaxH: CGFloat = 631
        static let swatch: CGFloat = 40
        static let swatchPitch: CGFloat = 52
        static let paletteGap: CGFloat = 32           // content.left − palette.right
        static let metaGap: CGFloat = 37              // metadata.left − content.right
        static let metaLabelValueGap: CGFloat = 17
        static let metaGroupPitch: CGFloat = 46
        static let noteGap: CGFloat = 51              // content.bottom → note
        static let pillW: CGFloat = 168
        static let pillH: CGFloat = 62
        static let pillBottom: CGFloat = 30           // frame.bottom → pill.bottom
        static let backInset = CGPoint(x: 19, y: 61)
        static let backSize: CGFloat = 40
    }

    private var scale: CGFloat { min(bounds.width / D.frame.width, bounds.height / D.frame.height) }
    private var originY: CGFloat { (bounds.height - D.frame.height * scale) / 2 }   // center design vertically
    private var originX: CGFloat { (bounds.width - D.frame.width * scale) / 2 }

    /// Content slot: media aspect-fit inside the (scaled) 560×631 box, centered
    /// horizontally in the window, top at the design's 112pt.
    private func contentTargetRect() -> CGRect {
        let s = scale
        let maxW = D.contentMaxW * s, maxH = D.contentMaxH * s
        var w = maxW, h = w / max(0.01, contentAspect)
        if h > maxH { h = maxH; w = h * contentAspect }
        let x = (bounds.width - w) / 2
        let y = originY + D.contentTop * s
        return CGRect(x: x, y: y, width: w, height: h)
    }

    override func layout() {
        super.layout()
        let s = scale
        backdrop.frame = bounds
        backButton.frame = CGRect(x: originX + D.backInset.x * s, y: originY + D.backInset.y * s,
                                  width: D.backSize * s, height: D.backSize * s)

        let target = contentTargetRect()
        if presentedID != nil, !inLiveAnimation { layoutContent() }

        // Palette column just LEFT of the content, top-aligned. 40pt circles.
        paletteColumn.spacing = (D.swatchPitch - D.swatch) * s
        let palSize = paletteColumn.fittingSize
        paletteColumn.frame = CGRect(x: target.minX - D.paletteGap * s - palSize.width,
                                     y: target.minY, width: palSize.width, height: palSize.height)

        // Metadata just RIGHT of the content, top-aligned.
        metadataColumn.spacing = (D.metaGroupPitch - 2 * 12) * s   // group pitch ≈ 46
        let metaSize = metadataColumn.fittingSize
        metadataColumn.frame = CGRect(x: target.maxX + D.metaGap * s, y: target.minY,
                                      width: max(120, metaSize.width), height: metaSize.height)

        // "Write a note…" under the content, left-aligned.
        noteField.alignment = .left
        noteField.font = .systemFont(ofSize: 16 * s, weight: .medium)
        noteField.frame = CGRect(x: target.minX, y: target.maxY + D.noteGap * s,
                                 width: target.width, height: 22 * s)

        // Bottom brand pill, centered horizontally.
        let pw = D.pillW * s, ph = D.pillH * s
        toolbar.frame = CGRect(x: bounds.midX - pw / 2,
                               y: originY + (D.frame.height - D.pillBottom) * s - ph,
                               width: pw, height: ph)
    }

    private var inLiveAnimation: Bool { contentClip.layer?.animationKeys()?.isEmpty == false }

    // MARK: Actions

    @objc private func closeTapped() { onClose() }
    @objc private func noteCommitted() {
        onSaveNote(noteField.stringValue)
        window?.makeFirstResponder(nil)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  onClose()
        case 123: onStep(-1)
        case 124: onStep(1)
        default:  super.keyDown(with: event)
        }
    }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Color swatch (haptic on hover, click to copy)

private final class ColorSwatch: NSView {
    private let color: NSColor
    private let dot = CALayer()
    private var tracking: NSTrackingArea?
    private let diameter: CGFloat

    init(color: NSColor, diameter: CGFloat = 40) {
        self.color = color
        self.diameter = diameter
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        layer?.masksToBounds = false               // let the hover-scaled dot overflow, never clip
        dot.frame = bounds
        dot.cornerRadius = diameter / 2
        dot.backgroundColor = color.cgColor
        // A visible hairline ring so a near-white swatch reads on the white bg.
        dot.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
        dot.borderWidth = 1
        layer?.addSublayer(dot)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }

    // Spatial-style: the swatch scales up on hover (with the trackpad tick).
    // No cursor change — detail mode keeps the plain arrow (cursor swaps made
    // the pointer flicker badly). masksToBounds=false keeps the scale unclipped.
    override func mouseEntered(with event: NSEvent) {
        CLIPHaptics.snap()                             // trackpad vibration on color hover (user request)
        scaleDot(1.18)
    }
    override func mouseExited(with event: NSEvent) {
        scaleDot(1.0)
    }
    override func mouseDown(with event: NSEvent) {
        let hex = NativePalette.hex(color)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        CLIPHaptics.levelChange()
        scaleDot(0.9)
    }
    override func mouseUp(with event: NSEvent) {
        scaleDot(bounds.contains(convert(event.locationInWindow, from: nil)) ? 1.18 : 1.0)
    }

    private func scaleDot(_ s: CGFloat) {
        let c = CGPoint(x: dot.bounds.midX, y: dot.bounds.midY)
        let to = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-c.x, -c.y, 0),
                                CATransform3DMakeScale(s, s, 1)),
            CATransform3DMakeTranslation(c.x, c.y, 0))
        let a = CASpringAnimation(keyPath: "transform")
        a.fromValue = dot.presentation()?.transform ?? dot.transform
        a.toValue = to
        a.stiffness = CLIPSpring.Preset.control.stiffness
        a.damping = CLIPSpring.Preset.control.caDamping
        a.duration = a.settlingDuration
        dot.transform = to
        dot.add(a, forKey: "scale")
    }
}

// MARK: - Metadata row (label over value, uppercase mono — Spatial ImageMetadataView)

private final class MetadataRowView: NSView {
    private let onClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    init(label: String, value: String, fontSize: CGFloat = 11, onClick: (() -> Void)? = nil) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        // Figma: SF Mono Semibold 11, uppercase. Label = black, value = 40% black.
        let l = NSTextField(labelWithString: label.uppercased())
        l.font = .monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        l.textColor = NSColor.black
        let v = NSTextField(labelWithString: value.uppercased())
        v.font = .monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        // A clickable LINK row reads a touch darker (still mono) to signal it opens.
        v.textColor = NSColor.black.withAlphaComponent(onClick != nil ? 0.55 : 0.40)
        v.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [l, v])
        stack.orientation = .vertical
        stack.spacing = max(3, fontSize * 0.55)        // ≈17pt label→value at 11pt
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard onClick != nil else { return }
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    // No cursor swap in detail mode (it flickered). The LINK row still clicks.
    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }
}

// MARK: - Reusable native button kit (placeholder; restyled later from Spatial)

/// Borderless icon button matching Spatial's `Button`/`Circle` feel: a soft
/// hover highlight that fades in, a subtle hover-grow, a press-shrink, and a
/// springy release-bounce — all via `CLIPSpring`. Pointing-hand cursor. NO
/// haptic on hover/press (Spatial reserves haptics for snap/level-change).
final class HoverIconButton: NSView {
    var onClick: () -> Void = {}
    /// Highlight tint — light for dark surfaces (the pill), dark for light ones.
    var highlightColor: NSColor = NSColor.labelColor.withAlphaComponent(0.10) {
        didSet { highlight.backgroundColor = highlightColor.cgColor }
    }
    var enabled = true { didSet { alphaValue = enabled ? 1 : 0.35 } }

    private let icon = NSImageView()
    private let highlight = CALayer()
    private var tracking: NSTrackingArea?
    private var hovering = false

    init(symbol: String) {
        super.init(frame: .zero)
        wantsLayer = true
        highlight.backgroundColor = highlightColor.cgColor
        highlight.cornerRadius = 7
        highlight.cornerCurve = .continuous
        highlight.opacity = 0
        layer?.addSublayer(highlight)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setTint(_ color: NSColor) { icon.contentTintColor = color }
    func setSymbol(_ symbol: String, pointSize: CGFloat = 15) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
    }

    override func layout() {
        super.layout()
        // Figma "Copy-Hover": the highlight is a circle filling the 52×52 button
        // (a centred square the size of the shorter edge). The button does NOT
        // resize on hover — only this circle fades in behind the static icon.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        highlight.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                                 width: side, height: side)
        highlight.cornerRadius = side / 2
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) {
        guard enabled else { return }
        hovering = true
        fadeHighlight(to: 1)                               // circle only — no resize, no cursor swap
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        fadeHighlight(to: 0)
        icon.alphaValue = 1
    }
    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        icon.alphaValue = 0.55                             // tactile press dim (no geometry change)
    }
    override func mouseUp(with event: NSEvent) {
        guard enabled else { return }
        icon.alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
    private func fadeHighlight(to v: Float) {
        CLIPSpring.run(duration: 0.18) { [weak self] in self?.highlight.opacity = v }
    }
}

/// CLIP's brand toolbar pill (Figma "Frame 42"): a green ring (#3DA726) with a
/// green drop-shadow around a vertical yellow gradient (#FFF53B→#F8DE47) with a
/// light top border (#FFFCA9), holding dark icon buttons.
final class ToolbarPill: NSView {
    struct Item { let symbol: String; let help: String; var enabled = true; let action: () -> Void }
    private let ring = CAGradientLayer()               // outer green capsule (was self.layer bg)
    private let inner = CAGradientLayer()
    private let stack = NSStackView()

    private static let green  = NSColor(srgbRed: 0.239, green: 0.655, blue: 0.149, alpha: 1)
    private static let yellowTop = NSColor(srgbRed: 1.0, green: 0.961, blue: 0.231, alpha: 1)
    private static let yellowBot = NSColor(srgbRed: 0.973, green: 0.871, blue: 0.278, alpha: 1)
    private static let border    = NSColor(srgbRed: 1.0, green: 0.988, blue: 0.663, alpha: 1)
    // Figma shadow colour: rgb(0, 0.361, 0.008) — a deep green.
    private static let shadowGreen = NSColor(srgbRed: 0.0, green: 0.361, blue: 0.008, alpha: 1)

    /// The exact 4-layer green drop-shadow stack from the Figma export (design
    /// pill = 62pt tall). Each is a separate shadow because one CALayer casts
    /// only one shadow; blur/offset scale with the pill's actual height.
    private struct ShadowSpec { let opacity: Float; let blur: CGFloat; let dy: CGFloat }
    private static let shadowSpecs: [ShadowSpec] = [
        .init(opacity: 0.12, blur: 3,  dy: 2),
        .init(opacity: 0.10, blur: 6,  dy: 6),
        .init(opacity: 0.06, blur: 8,  dy: 14),
        .init(opacity: 0.02, blur: 10, dy: 24),
    ]
    private static let designHeight: CGFloat = 62
    private let shadowLayers: [CALayer]

    override init(frame frameRect: NSRect) {
        shadowLayers = Self.shadowSpecs.map { _ in CALayer() }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        // Bottom-most: 4 shadow-only layers (transparent body, just cast their
        // green shadow). Below the green ring so the shadow reads behind it.
        for (l, spec) in zip(shadowLayers, Self.shadowSpecs) {
            l.backgroundColor = NSColor.clear.cgColor
            l.shadowColor = Self.shadowGreen.cgColor
            l.shadowOpacity = spec.opacity
            l.masksToBounds = false
            // Manually-created sublayers are NOT auto-flipped the way a view's
            // backing layer is in a flipped view, so a +dy offset would throw the
            // shadow UPWARD. Flip geometry so the Figma's +dy renders downward.
            l.isGeometryFlipped = true
            layer?.addSublayer(l)
        }
        ring.colors = [Self.green.cgColor, Self.green.cgColor]      // flat green capsule
        ring.masksToBounds = true
        layer?.addSublayer(ring)
        inner.colors = [Self.yellowTop.cgColor, Self.yellowBot.cgColor]
        inner.startPoint = CGPoint(x: 0.5, y: 0)
        inner.endPoint = CGPoint(x: 0.5, y: 1)
        inner.borderColor = Self.border.cgColor
        inner.borderWidth = 1.5
        inner.masksToBounds = true
        layer?.addSublayer(inner)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let r = bounds.height / 2
        let capsule = CGPath(roundedRect: CGRect(origin: .zero, size: bounds.size),
                             cornerWidth: r, cornerHeight: r, transform: nil)
        let k = bounds.height / Self.designHeight                   // design→actual scale
        for (l, spec) in zip(shadowLayers, Self.shadowSpecs) {
            l.frame = bounds
            l.shadowPath = capsule
            l.shadowRadius = spec.blur * k
            l.shadowOffset = CGSize(width: 0, height: spec.dy * k)
        }
        ring.frame = bounds
        ring.cornerRadius = r
        inner.frame = bounds.insetBy(dx: 2, dy: 2)
        inner.cornerRadius = inner.frame.height / 2
        CATransaction.commit()
    }

    func setButtons(_ items: [Item]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for it in items {
            let b = HoverIconButton(symbol: it.symbol)
            b.setSymbol(it.symbol, pointSize: 19)
            b.setTint(NSColor.black.withAlphaComponent(0.82))      // dark icons on yellow
            b.highlightColor = NSColor.white.withAlphaComponent(0.40)   // Figma "Copy-Hover" circle
            b.enabled = it.enabled
            b.onClick = it.action
            stack.addArrangedSubview(b)
        }
    }
}
