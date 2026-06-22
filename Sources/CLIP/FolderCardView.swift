import AppKit
import CoreImage

/// Native folder card. Renders the exact Figma folder vector (`Folder_Rest.svg`,
/// text stripped) as the shape — back panel + tab notch, gradients, and a
/// silhouette drop shadow — then overlays the LIVE item-count + name + identity
/// icon natively so they update. The SVG's shadow margin bleeds *outside* the
/// node bounds so the folder itself fills the node. Refreshes in place via
/// `NativeCardUpdatable`.
final class FolderCardView: NSView, NativeCardUpdatable {
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
    /// White stroke tracing the folder silhouette (Figma node 58:232), overlaid
    /// on the fill so the folder has a crisp outline (always on).
    private let outlineView = NSImageView()
    /// The hover/selected SELECTION outline — the same silhouette stroke, drawn
    /// in a slightly larger frame so it sits as a curved outline OUTSIDE the
    /// folder (the folder's analogue of the cards' offset rect outline). Faded
    /// in on SELECT only.
    private let selectionOutlineView = NSImageView()
    private var isLifted = false
    private var showsSelectionOutline = false
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

        // Shadow caster FIRST so it sits behind the folder fill: it shows the
        // (clean) folder image purely to derive its alpha silhouette shadow — the
        // image itself is hidden by the opaque `shapeView` directly on top.
        shadowView.image = Self.restImage
        shadowView.imageScaling = .scaleAxesIndependently
        shadowView.wantsLayer = true
        shadowView.layer?.masksToBounds = false
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOffset = .zero    // set in updateShadow()
        addSubview(shadowView)

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

        // Offset selection outline: same silhouette stroke, hidden until lifted,
        // sized larger than the folder in `layout` so it reads as a curved
        // outline sitting just outside the folder edge.
        selectionOutlineView.image = Self.outlineImage
        selectionOutlineView.imageScaling = .scaleAxesIndependently
        selectionOutlineView.wantsLayer = true
        selectionOutlineView.layer?.opacity = 0
        addSubview(selectionOutlineView)

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
        // Shadow caster traces the SAME (clean, untinted) silhouette so the drop
        // shadow is identical whether or not the folder is recoloured.
        shadowView.image = shapeView.image
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
            anim.fromValue = selectionOutlineView.layer?.presentation()?.opacity
                ?? selectionOutlineView.layer?.opacity
            anim.toValue = target
            anim.duration = 0.14
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            selectionOutlineView.layer?.opacity = target
            selectionOutlineView.layer?.add(anim, forKey: "fade")
        }
        updateShadow(animated: liftChanged)
    }

    /// Global object drop shadow (mirrors CardItemView.updateShadow): rest vs
    /// lifted depth + a zoom fade so dozens of folders don't read as mud when
    /// zoomed out. The lift SCALE comes for free — the whole view's transform
    /// scales this sublayer — so only opacity/offset/radius change here.
    private func updateShadow(animated: Bool) {
        guard let l = shadowView.layer else { return }
        let zoomFade = max(0, min(1, (currentMag - Self.shadowMinMag)
                                     / (Self.shadowFullMag - Self.shadowMinMag)))
        let opacity: Float    = (isLifted ? 0.17 : 0.13) * Float(zoomFade)
        let offsetY: CGFloat  = isLifted ? 16 : 6
        let radius: CGFloat   = isLifted ? 20 : 8
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.14)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        l.shadowOpacity = opacity
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
        // Outline art (994×854) is tight to its canvas, same ~1.16 ratio as the
        // folder, so it traces the silhouette when filling the node bounds.
        outlineView.frame = bounds
        // Selection outline: the same silhouette grown by a UNIFORM fraction so it
        // scales isotropically and stays PARALLEL to the folder edge (an equal
        // dx/dy inset warps a non-square silhouette off-parallel — that was the
        // "weird offset"). Small fraction so the outline hugs the folder.
        let g: CGFloat = 0.016
        selectionOutlineView.frame = bounds.insetBy(dx: -w * g, dy: -h * g)

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
