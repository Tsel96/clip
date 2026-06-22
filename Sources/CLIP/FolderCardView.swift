import AppKit
import CoreImage

/// Native folder card. Renders the exact Figma folder vector (`Folder_Rest.svg`,
/// text stripped) as the shape — back panel + tab notch, gradients, and a
/// silhouette drop shadow — then overlays the LIVE item-count + name + identity
/// icon natively so they update. The SVG's shadow margin bleeds *outside* the
/// node bounds so the folder itself fills the node. Refreshes in place via
/// `NativeCardUpdatable`.
final class FolderCardView: NSView, NativeCardUpdatable, NSTextFieldDelegate {
    private let shapeView = NSImageView()
    /// Single silhouette shadow caster stacked BEHIND `shapeView`, deriving its
    /// shape from the clean folder alpha. Driven by the GLOBAL object-shadow
    /// settings (see `updateShadow`) so folders lift/zoom-fade exactly like cards.
    private let shadowView = NSImageView()
    /// Global object shadow zoom-fade window (matches CardItemView.updateShadow).
    private static let shadowMinMag: CGFloat = 0.30
    private static let shadowFullMag: CGFloat = 0.55
    /// Current scroll magnification (for the shadow's zoom fade), pushed via setState.
    private var currentMag: CGFloat = 1
    private let countField = NSTextField(labelWithString: "No items")
    private let titleField = NSTextField(labelWithString: "Untitled")
    private let iconChip = NSView()
    private let iconView = NSImageView()
    /// SELECT-only white halo: a solid-white silhouette DERIVED from the folder art
    /// (so it matches the shape exactly — tab + corners, every colour), placed
    /// BEHIND the folder in a slightly larger frame so a clean white edge peeks
    /// out. Replaces the standalone Folder_Outline asset, which drifted off-shape
    /// and caused the white-outline artifacts in all states.
    private let haloView = NSImageView()
    private var isLifted = false
    private var showsSelectionOutline = false
    private var currentCount = 0
    /// While true, the title field is the live rename editor: never auto-hide,
    /// re-position, or let a baked-text SVG cover it (refreshes would otherwise
    /// re-hide it for any non-empty folder, killing the edit).
    private var isRenaming = false
    /// Current art canvas height (1044 rest/per-count, 1099 selected — the
    /// selected SVG carries extra glow margin) so layout maps the taller art.
    private var currentArtHeight: CGFloat = 1044

    /// The folder occupies this sub-rect of the rest SVG's 1163×1044 canvas
    /// (the rest is shadow margin) — used to bleed the margin outside the node.
    private static let svgSize = CGSize(width: 1163, height: 1044)
    private static let folderRect = CGRect(x: 105, y: 113, width: 953, height: 818)

    private static func loadSVG(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg") else { return nil }
        let img = NSImage(contentsOf: url)
        img?.resizingMode = .stretch
        return img
    }
    private static let restImage      = loadSVG("Folder_Rest")
    private static let oneItemImage   = loadSVG("Folder_1-item")
    private static let twoItemsImage  = loadSVG("Folder_2-items")
    private static let threeItemsImage = loadSVG("Folder_3-items")
    /// Open-lid art (Figma 104:672 "Opened part of folder") — a SEPARATE overlay at
    /// (73, 256.23, 1017×685) in the 1163×1044 folder frame, faded + lifted in on
    /// drop-hover so ONLY the lid animates (the body art stays put).
    private static let openLidImage = loadSVG("Folder_OpenedLid")
    private let lidView = NSImageView()
    /// Figma rect of the open lid within the folder frame.
    private static let lidRect = CGRect(x: 73, y: 256.2256, width: 1017, height: 685)
    /// Up-arrow drop affordance (Figma 104:675) — the exact `Arrow up button` SVG
    /// (subtle dark circle + arrow), shown on drop-hover ABOVE everything. Its
    /// Figma rect within the folder frame.
    private static let arrowImage = loadSVG("Folder_ArrowUp")
    private let dropArrow = NSImageView()
    private static let arrowRect = CGRect(x: 471.29, y: 339.39, width: 219.39, height: 219.39)
    /// Current folder tint (so the open-lid art is recoloured to match).
    private var nodeColorHex: String?
    private var isDropHovered = false
    /// Folder art for an item count — the card-peek is baked into each SVG.
    private static func art(forCount count: Int) -> NSImage? {
        // ALWAYS the text-free art: the 1/2/3-item SVGs bake in "Untitled" + a
        // count as outlined paths, which can't reflect a renamed folder (the live
        // name + count come from the dynamic countField/titleField instead).
        restImage
    }

    /// White OFFSET-outline ring of each art (cached) — the selection outline: a
    /// thin white ring sitting a GAP outside the folder edge, derived from the art
    /// so it traces the folder EXACTLY (tab + corners) at any colour.
    private static let restRing  = whiteRing(of: restImage)
    private static let oneRing   = whiteRing(of: oneItemImage)
    private static let twoRing   = whiteRing(of: twoItemsImage)
    private static let threeRing = whiteRing(of: threeItemsImage)
    private static func ring(forCount count: Int) -> NSImage? {
        restRing   // matches the always-rest art above
    }

    /// A thin WHITE ring offset a gap OUTSIDE `image`'s silhouette: dilate the folder
    /// alpha to (gap) and to (gap+line) and keep the difference, so the outline sits
    /// a clear gap off the folder edge (an offset outline, not a hugging border).
    private static func whiteRing(of image: NSImage?) -> NSImage? {
        guard let image, let tiff = image.tiffRepresentation, let base = CIImage(data: tiff) else { return nil }
        let ext = base.extent
        let unit = ext.width / 1163.0      // px per art-unit (handles 1× vs 2× raster)
        let solid = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: ext)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: base])
        // Disc dilation (rounded) grows the silhouette outward; the band between the
        // two grown copies is the offset ring. ~10 art-units gap, ~7.5 thick (+50%).
        let inner = solid.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 10 * unit]).cropped(to: ext)
        let outer = solid.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 17.5 * unit]).cropped(to: ext)
        let ring = outer.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner]).cropped(to: ext)
        let result = NSImage(size: image.size)
        result.addRepresentation(NSCIImageRep(ciImage: ring))
        return result
    }

    /// Parse `#RRGGBB` (sRGB).
    private static func color(fromHex hex: String) -> NSColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Recolour the folder art to `color`'s hue, keeping the art's luminance,
    /// gradient and alpha (transparent corners stay transparent) via a colour
    /// blend (`CIColorBlendMode`: hue/chroma from the colour, luminance + alpha
    /// from the folder).
    private static func tinted(_ image: NSImage, with color: NSColor) -> NSImage {
        guard let tiff = image.tiffRepresentation, let folder = CIImage(data: tiff),
              let c = CIColor(color: color.usingColorSpace(.sRGB) ?? color) else { return image }
        // Grayscale folder = luminance + shading + alpha, with no lavender hue.
        let mono = folder.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        // Solid colour clipped to the folder silhouette (transparent corners stay clear).
        let colorClipped = CIImage(color: c).cropped(to: folder.extent)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: folder])
        // Multiply colour × shading → a clearly-coloured folder that keeps its depth.
        let out = colorClipped.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: mono])
        let result = NSImage(size: image.size)
        result.addRepresentation(NSCIImageRep(ciImage: out))
        return result
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        // Shadow caster FIRST so it sits behind the folder fill: it shows the
        // (clean) folder image purely to derive its alpha silhouette shadow — the
        // image itself is hidden by the opaque `shapeView` directly on top.
        shadowView.image = Self.restImage
        shadowView.imageScaling = .scaleAxesIndependently
        shadowView.wantsLayer = true
        shadowView.layer?.masksToBounds = false
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOffset = .zero    // set in updateShadow()
        // BAKE the alpha-derived blur: rasterize so a zoom resamples the cached
        // shadow instead of re-blurring every frame (high-zoom FPS fix). The art it
        // shows is occluded by `shapeView`, so only the shadow is visible.
        shadowView.layer?.shouldRasterize = true
        shadowView.layer?.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2
        shadowView.layer?.magnificationFilter = .trilinear
        addSubview(shadowView)

        // Selection halo BEHIND the folder so only its white edge peeks out; sized
        // larger than the folder in `layout`, faded in on SELECT only.
        haloView.imageScaling = .scaleAxesIndependently
        haloView.wantsLayer = true
        haloView.layer?.opacity = 0
        addSubview(haloView)

        shapeView.image = Self.restImage
        shapeView.imageScaling = .scaleAxesIndependently
        shapeView.wantsLayer = true
        shapeView.layer?.masksToBounds = false
        addSubview(shapeView)

        // Open-lid overlay — hidden at rest, fades + lifts in on drop-hover. Sits
        // ABOVE the body but BELOW the text/icon (added next).
        lidView.image = Self.openLidImage
        lidView.imageScaling = .scaleAxesIndependently
        lidView.wantsLayer = true
        lidView.layer?.masksToBounds = false
        lidView.layer?.opacity = 0
        addSubview(lidView)

        countField.textColor = NSColor(white: 0, alpha: 0.4)
        countField.wantsLayer = true
        addSubview(countField)
        titleField.textColor = .black
        titleField.wantsLayer = true
        addSubview(titleField)

        iconChip.wantsLayer = true
        iconChip.layer?.backgroundColor = NSColor.white.cgColor
        iconChip.layer?.cornerCurve = .continuous
        iconChip.layer?.shadowColor = NSColor.black.cgColor
        iconChip.layer?.shadowOpacity = 0.12
        iconChip.layer?.shadowRadius = 5
        iconChip.layer?.shadowOffset = CGSize(width: 0, height: -1)
        iconChip.layer?.masksToBounds = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .black
        iconChip.addSubview(iconView)
        addSubview(iconChip)

        // Up-arrow drop affordance (Figma 104:675) — the exact SVG, ABOVE
        // everything, faded in on hover.
        dropArrow.image = Self.arrowImage
        dropArrow.imageScaling = .scaleAxesIndependently
        dropArrow.wantsLayer = true
        dropArrow.layer?.opacity = 0
        addSubview(dropArrow)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }     // top-left origin for the overlays

    func update(for node: CanvasNode) {
        guard case .folder(let title, let icon, let childIDs) = node.kind else { return }
        titleField.stringValue = title.isEmpty ? "Untitled" : title
        countField.stringValue = childIDs.isEmpty
            ? "No items"
            : "\(childIDs.count) item\(childIDs.count == 1 ? "" : "s")"
        iconChip.isHidden = icon.isEmpty
        if !icon.isEmpty {
            iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        }
        currentCount = childIDs.count
        nodeColorHex = node.folderColor
        refreshArt()
        // Folder tint from the flower picker (nil → default lavender): recolour
        // the folder IMAGE so the picked hue actually shows.
        if let hex = node.folderColor, let color = Self.color(fromHex: hex),
           let base = Self.art(forCount: currentCount) {
            shapeView.image = Self.tinted(base, with: color)
        }
        // The 1/2/3-item SVGs bake in their own count + "Untitled" (as outlined
        // Art is ALWAYS the text-free Folder_Rest now, so the dynamic count +
        // name labels are ALWAYS shown (they carry the live, renamable values).
        countField.isHidden = false
        titleField.isHidden = false
        needsLayout = true
    }

    private func refreshArt() {
        // Always the per-count art (so the count + card peek stay visible when
        // selected); selection is shown by the scale + ring, not an art swap.
        shapeView.image = Self.art(forCount: currentCount)
        // Shadow caster traces the SAME (clean, untinted) silhouette so the drop
        // shadow is identical whether or not the folder is recoloured.
        shadowView.image = shapeView.image
        // Selection outline = the clean white ring (stays white at any folder colour).
        haloView.image = Self.ring(forCount: currentCount)
        currentArtHeight = 1044
    }

    /// Hover/selected feedback. `lifted` (hover OR select) drives the 1.06 scale;
    /// `selected` drives the curved offset outline (hover shows scale only, to
    /// match the cards' Figma-exact hover). Called from CardItemView.updateChrome.
    func setState(lifted: Bool, selected: Bool, mag: CGFloat) {
        currentMag = mag
        let liftChanged = lifted != isLifted
        if liftChanged {
            isLifted = lifted
            // Scale from the CENTRE. A layer-backed NSView anchors its backing layer
            // at the corner (anchorPoint 0,0), so `CATransform3DMakeScale` alone grows
            // from a corner — build an explicit centre-pivot transform instead.
            let cx = bounds.width / 2, cy = bounds.height / 2
            let factor: CGFloat = lifted ? CardItemView.liftScale : 1.0
            let target = CATransform3DConcat(
                CATransform3DConcat(CATransform3DMakeTranslation(-cx, -cy, 0),
                                    CATransform3DMakeScale(factor, factor, 1)),
                CATransform3DMakeTranslation(cx, cy, 0))
            let anim = CardItemView.liftSpring(
                from: layer?.presentation()?.transform ?? layer?.transform ?? target, to: target)
            layer?.transform = target
            layer?.add(anim, forKey: "liftScale")
        }
        if selected != showsSelectionOutline {
            showsSelectionOutline = selected
            let target: Float = selected ? 1 : 0
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = haloView.layer?.presentation()?.opacity ?? haloView.layer?.opacity
            anim.toValue = target
            anim.duration = 0.14
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            haloView.layer?.opacity = target
            haloView.layer?.add(anim, forKey: "fade")
        }
        updateShadow(animated: liftChanged)
    }

    /// Drop-hover (a card is held over this folder): the lid OPENS — crossfade to
    /// the open-lid `Folder_Hovered` art — and the selection outline fades in. On
    /// exit it closes back to the per-count art. Driven natively from the drag
    /// loop (CollectionCanvas.liveReposition) so it's smooth + SwiftUI-free.
    func setDropHover(_ hovering: Bool) {
        guard hovering != isDropHovered else { return }
        isDropHovered = hovering
        // Show the labels on hover (the open lid covers any baked-in SVG text);
        // restore the per-count visibility on exit.
        // Labels are always visible now (text-free art); nothing to toggle here.
        countField.isHidden = false
        titleField.isHidden = false
        lidView.image = tintedIfNeeded(Self.openLidImage)
        // ONLY the lid animates (the body art stays put): the open-lid overlay fades
        // + springs UP out of the folder front on enter, and back on exit.
        let cx = lidView.bounds.width / 2, cy = lidView.bounds.height / 2
        let closed = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-cx, -cy, 0),
                                CATransform3DMakeScale(0.94, 0.94, 1)),
            CATransform3DMakeTranslation(cx, cy + cy * 0.10, 0))    // sunk into the front
        // Open lid rests 5pt HIGHER than its slot (the user's nudge).
        let to = hovering ? CATransform3DMakeTranslation(0, -5, 0) : closed
        let s = CASpringAnimation(keyPath: "transform")
        s.fromValue = lidView.layer?.presentation()?.transform ?? lidView.layer?.transform ?? to
        s.toValue = to
        s.stiffness = 320; s.damping = 26; s.mass = 1
        s.duration = s.settlingDuration
        lidView.layer?.transform = to
        lidView.layer?.add(s, forKey: "lidOpen")

        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = lidView.layer?.presentation()?.opacity ?? lidView.layer?.opacity
        o.toValue = hovering ? 1 : 0
        o.duration = 0.18
        o.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        lidView.layer?.opacity = hovering ? 1 : 0
        lidView.layer?.add(o, forKey: "lidFade")

        // Outline — IDENTICAL to the selected state (kept on if genuinely selected).
        let op: Float = hovering ? 1 : (showsSelectionOutline ? 1 : 0)
        let ho = CABasicAnimation(keyPath: "opacity")
        ho.fromValue = haloView.layer?.presentation()?.opacity ?? haloView.layer?.opacity
        ho.toValue = op
        ho.duration = 0.16
        ho.timingFunction = CAMediaTimingFunction(name: .easeOut)
        haloView.layer?.opacity = op
        haloView.layer?.add(ho, forKey: "fade")

        // Up-arrow drop affordance fades in/out with the hover.
        let ao = CABasicAnimation(keyPath: "opacity")
        ao.fromValue = dropArrow.layer?.presentation()?.opacity ?? dropArrow.layer?.opacity
        ao.toValue = hovering ? 1 : 0
        ao.duration = 0.16
        ao.timingFunction = CAMediaTimingFunction(name: .easeOut)
        dropArrow.layer?.opacity = hovering ? 1 : 0
        dropArrow.layer?.add(ao, forKey: "arrowFade")

        // Slide the labels DOWN 3pt and the arrow DOWN 5pt on hover (animated).
        slideY(countField.layer, to: hovering ? 3 : 0)
        slideY(titleField.layer, to: hovering ? 3 : 0)
        slideY(dropArrow.layer,  to: hovering ? 5 : 0)
    }

    /// Spring a layer's vertical translation (the hover slide-down).
    private func slideY(_ layer: CALayer?, to ty: CGFloat) {
        guard let layer else { return }
        let target = CATransform3DMakeTranslation(0, ty, 0)
        let a = CASpringAnimation(keyPath: "transform")
        a.fromValue = layer.presentation()?.transform ?? layer.transform
        a.toValue = target
        a.stiffness = 320; a.damping = 26; a.mass = 1
        a.duration = a.settlingDuration
        layer.transform = target
        layer.add(a, forKey: "slideY")
    }

    // MARK: - Inline rename (double-click the name label, Figma 104:688)

    private var renameCommit: ((String) -> Void)?

    func beginRename(commit: @escaping (String) -> Void) {
        renameCommit = commit
        isRenaming = true
        // Swap to the text-FREE art so a baked-in "Untitled" can't sit under the
        // editor (the 1/2/3-item SVGs bake their own title; the rest art is clean).
        shapeView.image = tintedIfNeeded(Self.restImage)
        titleField.isHidden = false                 // show even if a baked-text SVG is up
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.usesSingleLineMode = true        // one line then … (Figma)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.delegate = self
        // Give the editor a comfortable width regardless of the sized-to-fit title.
        let w = bounds.width
        titleField.frame.size.width = max(titleField.frame.width, w * 0.5)
        // Defer past the current click event so the canvas input view doesn't
        // immediately re-grab first responder (which fired an instant commit).
        focusTitleField(attempt: 0)
    }

    /// Drive the title field to first responder, retrying a couple of runloop
    /// turns — inside an NSCollectionView item the window can refuse the first
    /// makeFirstResponder until the item settles.
    private func focusTitleField(attempt: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRenaming, let window = self.window else { return }
            window.makeKeyAndOrderFront(nil)
            let ok = window.makeFirstResponder(self.titleField)
            if ok {
                self.titleField.currentEditor()?.selectAll(nil)
            } else if attempt < 3 {
                self.focusTitleField(attempt: attempt + 1)
            }
            FolderCardView.diag("beginRename focus ok=\(ok) attempt=\(attempt) win=\(window) hidden=\(self.titleField.isHidden)")
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let commit = renameCommit else { return }
        renameCommit = nil
        isRenaming = false
        let newTitle = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.delegate = nil
        // Restore the per-count art (with its baked title) now the edit is done.
        refreshArt()
        commit(newTitle)
    }

    /// Append a line to /tmp/clip_diag.txt (rename debugging; cheap, removed later).
    static func diag(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        let url = URL(fileURLWithPath: "/tmp/clip_diag.txt")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }

    /// Apply the folder tint to an art image if one is set.
    private func tintedIfNeeded(_ base: NSImage?) -> NSImage? {
        if let hex = nodeColorHex, let color = Self.color(fromHex: hex), let b = base {
            return Self.tinted(b, with: color)
        }
        return base
    }

    /// Global object drop shadow (mirrors CardItemView.updateShadow): rest vs
    /// lifted depth + a zoom fade so dozens of folders don't read as mud when
    /// zoomed out. The lift SCALE comes for free — the whole view's transform
    /// scales this sublayer. The blur is BAKED (shadowView.layer is rasterized), so
    /// `shadowOpacity`/radius/offset change only on lift (rare re-bake); the zoom
    /// fade rides the composite `opacity`, which never invalidates the cache.
    private func updateShadow(animated: Bool) {
        guard let l = shadowView.layer else { return }
        let zoomFade = max(0, min(1, (currentMag - Self.shadowMinMag)
                                     / (Self.shadowFullMag - Self.shadowMinMag)))
        let baseOpacity: Float = isLifted ? 0.17 : 0.13
        let offsetY: CGFloat   = isLifted ? 16 : 6
        let radius: CGFloat    = isLifted ? 20 : 8
        // Zoom fade — composite opacity, instant per tick, no re-raster.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.opacity = Float(zoomFade)
        CATransaction.commit()
        // Baked params — change on lift only → cached shadow bitmap reused on zoom.
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.14)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        l.shadowOpacity = baseOpacity
        l.shadowRadius = radius
        l.shadowOffset = CGSize(width: 0, height: -offsetY)   // downward (non-flipped sublayer)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        guard w > 1, h > 1 else { return }

        // Map the SVG's folder sub-rect onto the node bounds; the whole SVG
        // (incl. the shadow margin) bleeds outside via a larger, offset frame.
        let sx = w / Self.folderRect.width, sy = h / Self.folderRect.height
        shapeView.frame = CGRect(x: -Self.folderRect.minX * sx,
                                 y: -Self.folderRect.minY * sy,
                                 width: Self.svgSize.width * sx,
                                 height: currentArtHeight * sy)
        // Shadow caster shares the folder frame; its params come from the global
        // object shadow (updateShadow), independent of the folder's own size.
        shadowView.frame = shapeView.frame
        updateShadow(animated: false)
        // Selection outline: the ring image already bakes in the gap + thickness
        // (dilated in art space), so it shares the folder art frame exactly.
        haloView.frame = shapeView.frame
        // Open-lid overlay — its own Figma sub-rect of the folder frame.
        lidView.frame = CGRect(x: (Self.lidRect.minX - Self.folderRect.minX) * sx,
                               y: (Self.lidRect.minY - Self.folderRect.minY) * sy,
                               width: Self.lidRect.width * sx,
                               height: Self.lidRect.height * sy)

        // Live text — Figma 104:673 "No items" (SF Pro Display Light, 40%) +
        // 104:674 "Untitled" (SF Mono Medium, black), both ≈ h·0.0714, at the
        // Figma positions (x 0.109w; No items 0.688h, Untitled 0.768h).
        let pad = w * 0.109
        countField.font = .systemFont(ofSize: max(8, h * 0.0714), weight: .light)
        titleField.font = NSFont.monospacedSystemFont(ofSize: max(9, h * 0.0714), weight: .medium)
        countField.sizeToFit(); titleField.sizeToFit()
        countField.frame.origin = CGPoint(x: pad, y: h * 0.688)        // rest position
        titleField.frame.origin = CGPoint(x: pad, y: h * 0.768)        // (slides +3 on hover)

        // Identity-icon chip, lower-right.
        let chip = min(w, h) * 0.20
        iconChip.frame = CGRect(x: w - pad - chip, y: h * 0.70, width: chip, height: chip)
        iconChip.layer?.cornerRadius = chip * 0.28
        iconView.frame = iconChip.bounds.insetBy(dx: chip * 0.26, dy: chip * 0.26)

        // Up-arrow drop affordance — its Figma sub-rect (slides +5 on hover).
        dropArrow.frame = CGRect(x: (Self.arrowRect.minX - Self.folderRect.minX) * sx,
                                 y: (Self.arrowRect.minY - Self.folderRect.minY) * sy,
                                 width: Self.arrowRect.width * sx,
                                 height: Self.arrowRect.height * sy)
    }
}
