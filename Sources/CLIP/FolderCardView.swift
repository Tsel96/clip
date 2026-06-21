import AppKit
import CoreImage

/// Native folder card. Renders the exact Figma folder vector (`Folder_Rest.svg`,
/// text stripped) as the shape — back panel + tab notch, gradients, and the
/// 4-layer drop shadow — then overlays the LIVE item-count + name + identity
/// icon natively so they update. The SVG's shadow margin bleeds *outside* the
/// node bounds so the folder itself fills the node. Refreshes in place via
/// `NativeCardUpdatable`.
/// One level of the folder's Figma drop shadow (node 953×818). Values are in the
/// 953-wide design space and are scaled to the rendered folder.
private struct FolderShadowLevel { let alpha: Float; let radius: CGFloat; let dy: CGFloat }

final class FolderCardView: NSView, NativeCardUpdatable {
    private let shapeView = NSImageView()
    /// Figma's 4-layer drop shadow, softest/largest last. Each level is cast by a
    /// dedicated image view stacked BEHIND `shapeView` (a CALayer holds only one
    /// shadow), deriving its shape from the clean folder silhouette's alpha.
    private static let shadowLevels: [FolderShadowLevel] = [
        .init(alpha: 0.09, radius: 6,  dy: 3),
        .init(alpha: 0.07, radius: 11, dy: 11),
        .init(alpha: 0.04, radius: 14, dy: 24),
        .init(alpha: 0.01, radius: 17, dy: 43),
    ]
    private let shadowViews: [NSImageView] = (0..<4).map { _ in NSImageView() }
    private let countField = NSTextField(labelWithString: "No items")
    private let titleField = NSTextField(labelWithString: "Untitled")
    private let iconChip = NSView()
    private let iconView = NSImageView()
    /// White stroke tracing the folder silhouette (Figma node 58:232), overlaid
    /// on the fill so the folder has a crisp outline.
    private let outlineView = NSImageView()
    private var isSelected = false
    private var currentCount = 0
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

        // Shadow casters FIRST so they sit behind the folder fill. Each shows the
        // (clean) folder image purely to derive its alpha shadow — the image
        // itself is hidden by the opaque `shapeView` directly on top.
        for (i, sv) in shadowViews.enumerated() {
            sv.image = Self.restImage
            sv.imageScaling = .scaleAxesIndependently
            sv.wantsLayer = true
            sv.layer?.masksToBounds = false
            sv.layer?.shadowColor = NSColor.black.cgColor
            sv.layer?.shadowOpacity = Self.shadowLevels[i].alpha
            sv.layer?.shadowOffset = .zero    // scaled in layout()
            addSubview(sv)
        }

        shapeView.image = Self.restImage
        shapeView.imageScaling = .scaleAxesIndependently
        shapeView.wantsLayer = true
        shapeView.layer?.masksToBounds = false
        addSubview(shapeView)
        outlineView.image = Self.outlineImage
        outlineView.imageScaling = .scaleAxesIndependently
        // Crisp white edge tracing the folder silhouette (Figma outline.svg, 994×854,
        // tab included). Its ~1.16 aspect matches the folder, so stretched to the node
        // bounds it follows the folder shape.
        outlineView.isHidden = false
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
        // Folder tint from the flower picker (nil → default lavender): recolour
        // the folder IMAGE so the picked hue actually shows.
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
        // Shadow casters trace the SAME (clean, untinted) silhouette so the drop
        // shadow is identical whether or not the folder is recoloured.
        for sv in shadowViews { sv.image = shapeView.image }
        currentArtHeight = 1044
    }

    /// Selection feedback: ONLY a subtle, animated scale (Spatial's "selected
    /// folder is a bit scaled") — no ring, no art swap. Called from
    /// CardItemView.updateChrome.
    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        // Scale from the CENTRE. A layer-backed NSView anchors its backing layer at
        // the corner (anchorPoint 0,0), so `CATransform3DMakeScale` alone grows from
        // a corner — build an explicit centre-pivot transform instead.
        let cx = bounds.width / 2, cy = bounds.height / 2
        let factor: CGFloat = selected ? 1.04 : 1.0
        let target = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-cx, -cy, 0),
                                CATransform3DMakeScale(factor, factor, 1)),
            CATransform3DMakeTranslation(cx, cy, 0))
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = layer?.presentation()?.transform ?? layer?.transform
        anim.toValue = target
        anim.duration = 0.18
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.transform = target
        layer?.add(anim, forKey: "selectScale")
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
        // Shadow casters share the folder frame; the Figma values (953-wide design
        // space) scale by `sx`. Negative height = downward (non-flipped sublayer).
        for (i, sv) in shadowViews.enumerated() {
            sv.frame = shapeView.frame
            let lvl = Self.shadowLevels[i]
            sv.layer?.shadowRadius = lvl.radius * sx
            sv.layer?.shadowOffset = CGSize(width: 0, height: -lvl.dy * sx)
        }
        // Outline art (994×854) is tight to its canvas, same ~1.16 ratio as the
        // folder, so it traces the silhouette when filling the node bounds.
        outlineView.frame = bounds

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
