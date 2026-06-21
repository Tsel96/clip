import AppKit
import CoreImage

/// Native folder card. Renders the exact Figma folder vector (`Folder_Rest.svg`,
/// text stripped) as the shape — back panel + tab notch, gradients, and the
/// 4-layer drop shadow — then overlays the LIVE item-count + name + identity
/// icon natively so they update. The SVG's shadow margin bleeds *outside* the
/// node bounds so the folder itself fills the node. Refreshes in place via
/// `NativeCardUpdatable`.
final class FolderCardView: NSView, NativeCardUpdatable {
    private let shapeView = NSImageView()
    private let countField = NSTextField(labelWithString: "No items")
    private let titleField = NSTextField(labelWithString: "Untitled")
    private let iconChip = NSView()
    private let iconView = NSImageView()
    /// White stroke tracing the folder silhouette (Figma node 58:232), overlaid
    /// on the fill so the folder has a crisp outline.
    private let outlineView = NSImageView()
    private var isSelected = false
    private var currentCount = 0
    // === Per-state interaction chrome (rest / hover / selected), 1:1 from Figma
    // 58:210 / 211 / 223. Added by the states task — kept self-contained so the
    // shadow lines below merge cleanly with the main tree's folder-shadow work. ===
    /// Current resolved state (drives the curved outline + scale + shadow).
    private var highlight: CardHighlightState = .rest
    /// Multi-layer folder drop shadow cast from the folder silhouette (the SVG's
    /// baked `filter0_dddd`; NSImage can't render the SVG filter, so we rebuild it
    /// as a CALayer stack — this is why the folder shadow was previously invisible).
    private let folderShadow = SilhouetteShadowStack()
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
    private static let outlineImage   = loadSVG("Folder_Outline")
    /// Folder art for an item count — the card-peek is baked into each SVG.
    private static func art(forCount count: Int) -> NSImage? {
        switch count {
        case 0:  return restImage
        case 1:  return oneItemImage
        case 2:  return twoItemsImage
        default: return threeItemsImage
        }
    }

    // MARK: - Folder tint (recolour from the flower picker)

    /// Parse `#RRGGBB` (sRGB).
    private static func color(fromHex hex: String) -> NSColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Recolour the folder art to `color`: grayscale (keeps the shading + alpha) ×
    /// the solid colour clipped to the folder silhouette — a clearly-coloured
    /// folder that keeps its depth and transparent corners.
    private static func tinted(_ image: NSImage, with color: NSColor) -> NSImage {
        guard let tiff = image.tiffRepresentation, let folder = CIImage(data: tiff),
              let c = CIColor(color: color.usingColorSpace(.sRGB) ?? color) else { return image }
        let mono = folder.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        let colorClipped = CIImage(color: c).cropped(to: folder.extent)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: folder])
        let out = colorClipped.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: mono])
        let result = NSImage(size: image.size)
        result.addRepresentation(NSCIImageRep(ciImage: out))
        return result
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        shapeView.image = Self.restImage
        shapeView.imageScaling = .scaleAxesIndependently
        shapeView.wantsLayer = true
        shapeView.layer?.masksToBounds = false
        // === Folder drop shadow (states task) ===
        // NSImage can't render the SVG's baked `filter0_dddd` shadow, so it is
        // rebuilt as a multi-layer CALayer stack cast from the folder silhouette
        // (`SilhouetteShadowStack`) — this is the fix for the previously-INVISIBLE
        // folder shadow. The stack sits behind the folder art; updated per state
        // in `layout()`. (Replaces the old single 0.13/12 layer shadow.)
        folderShadow.container.zPosition = -1
        layer?.addSublayer(folderShadow.container)
        addSubview(shapeView)
        // === end folder shadow ===
        outlineView.image = Self.outlineImage
        outlineView.imageScaling = .scaleAxesIndependently
        // Curved white outline tracing the folder silhouette (Figma outline.svg /
        // Folder_Selected node 58:232, 994×854, tab included). Its ~1.16 aspect
        // matches the folder, so stretched to the node bounds it follows the shape.
        // Shown ONLY in the SELECTED state (Figma 58:223); fades via `opacity`.
        outlineView.wantsLayer = true
        outlineView.layer?.opacity = 0
        addSubview(outlineView)

        countField.textColor = NSColor(white: 0, alpha: 0.4)
        addSubview(countField)
        titleField.textColor = .black
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
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }     // top-left origin for the overlays

    func update(for node: CanvasNode) {
        guard case .folder(let title, let icon, let childIDs) = node.kind else { return }
        titleField.stringValue = title.isEmpty ? "Untitled" : title
        countField.stringValue = childIDs.isEmpty
            ? "No items"
            : "\(childIDs.count) Items"
        iconChip.isHidden = icon.isEmpty
        if !icon.isEmpty {
            iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        }
        currentCount = childIDs.count
        refreshArt()
        // Flower-picker tint (nil → default): recolour the folder art so the picked
        // hue shows. shapeView keeps the tinted image; the shadow casts from it in
        // layout() (same silhouette alpha, so the drop shadow is unchanged).
        if let hex = node.folderColor, let color = Self.color(fromHex: hex),
           let base = Self.art(forCount: currentCount) {
            shapeView.image = Self.tinted(base, with: color)
        }
        // The 1/2/3-item SVGs bake in their own count + "Untitled" (as outlined
        // paths), so suppress our dynamic overlays whenever a baked-text SVG is
        // shown — only the text-stripped empty Folder_Rest needs them. (4+ caps at
        // the 3-item art; re-export the SVGs text-free to make ALL counts dynamic
        // + support renaming.)
        let svgHasText = childIDs.count >= 1
        countField.isHidden = svgHasText
        titleField.isHidden = svgHasText
        needsLayout = true
    }

    private func refreshArt() {
        // Always the per-count art (so the count + card peek stay visible when
        // selected); selection is shown by the scale + ring, not an art swap.
        shapeView.image = Self.art(forCount: currentCount)
        currentArtHeight = 1044
    }

    /// Selection shim (legacy callers). Maps to the three-state path.
    func setSelected(_ selected: Bool) { setHighlight(selected ? .selected : .rest) }

    /// Drive the folder's interaction state (Figma 58:210 rest / 58:211 hover /
    /// 58:223 selected): HOVER + SELECTED scale the folder up a little (Union
    /// 977/953 = 1.0252); SELECTED additionally shows the CURVED white outline
    /// tracing the folder silhouette. Called from `CardItemView.updateChrome`.
    func setHighlight(_ state: CardHighlightState) {
        guard state != highlight else { return }
        let wasSelected = highlight == .selected
        highlight = state
        isSelected = state == .selected

        // Subtle scale from the CENTRE (a layer-backed NSView anchors at its corner,
        // so build an explicit centre-pivot transform). Quick spring (Spatial feel).
        let cx = bounds.width / 2, cy = bounds.height / 2
        let factor = CardStateSpec.folderScaleValue(for: state)
        let target = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-cx, -cy, 0),
                                CATransform3DMakeScale(factor, factor, 1)),
            CATransform3DMakeTranslation(cx, cy, 0))
        let anim = CASpringAnimation(keyPath: "transform")
        anim.fromValue = layer?.presentation()?.transform ?? layer?.transform
        anim.toValue = target
        anim.stiffness = CardStateSpec.scaleSpring.stiffness
        anim.damping = CardStateSpec.scaleSpring.caDamping
        anim.mass = 1
        anim.duration = anim.settlingDuration
        anim.fillMode = .forwards
        layer?.transform = target
        layer?.add(anim, forKey: "stateScale")

        // Curved outline: fade in only when SELECTED (Figma 58:223).
        if (state == .selected) != wasSelected {
            let to: Float = state == .selected ? 1 : 0
            let f = CABasicAnimation(keyPath: "opacity")
            f.fromValue = outlineView.layer?.presentation()?.opacity ?? outlineView.layer?.opacity
            f.toValue = to
            f.duration = CardStateSpec.outlineFade
            f.timingFunction = CLIPSpring.easeOutSoft
            outlineView.layer?.opacity = to
            outlineView.layer?.add(f, forKey: "outlineFade")
        }
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
        // === Folder drop shadow (states task) ===
        // Cast the multi-layer shadow from the folder silhouette image at the same
        // frame as the art, behind it. `bodyWidth = w` (the on-screen folder body)
        // scales the per-state shadow exactly. The folder shadow is the same in all
        // states here (the Figma hover/selected only scale + add the outline), so
        // the scale-up naturally enlarges it.
        folderShadow.update(image: shapeView.image?.cgImageForShadow(),
                            frame: shapeView.frame, bodyWidth: w)
        // === end folder shadow ===
        // Curved outline (Folder_Outline.svg 994×854): its stroke path nearly fills
        // its own canvas, which is ~1.043× the folder body, so filling `bounds`
        // exactly would trace just INSIDE the folder edge. Enlarge the frame ~2.1%
        // about the centre so the white stroke sits ~8px OUTSIDE the folder body
        // (the Figma 58:223 selected gap). The whole-view 1.0252 scale (applied via
        // the layer transform on selection) then lifts outline + folder together.
        let oScale: CGFloat = 1.021
        outlineView.frame = CGRect(x: -w * (oScale - 1) / 2, y: -h * (oScale - 1) / 2,
                                   width: w * oScale, height: h * oScale)

        // Live text, lower-left (the baked text sat at ≈12% in, 69%/77% down).
        let pad = w * 0.118
        countField.font = .systemFont(ofSize: max(8, h * 0.060), weight: .light)
        titleField.font = NSFont.monospacedSystemFont(ofSize: max(9, h * 0.077), weight: .medium)
        countField.sizeToFit(); titleField.sizeToFit()
        titleField.frame.origin = CGPoint(x: pad, y: h * 0.775)
        countField.frame.origin = CGPoint(x: pad, y: h * 0.775 - countField.frame.height - h * 0.005)

        // Identity-icon chip, lower-right.
        let chip = min(w, h) * 0.20
        iconChip.frame = CGRect(x: w - pad - chip, y: h * 0.70, width: chip, height: chip)
        iconChip.layer?.cornerRadius = chip * 0.28
        iconView.frame = iconChip.bounds.insetBy(dx: chip * 0.26, dy: chip * 0.26)
    }
}
