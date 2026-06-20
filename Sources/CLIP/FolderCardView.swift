import AppKit

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
    /// Up to 3 child-card "covers" that peek out the folder's top when it has
    /// contents (Spatial's stacked peek). Added BEHIND `shapeView` so the folder
    /// body tucks their lower halves in; only the tops show.
    private let peekCovers: [NSView] = (0..<3).map { _ in
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.97).cgColor
        v.layer?.cornerRadius = 9
        v.layer?.cornerCurve = .continuous
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(white: 0, alpha: 0.07).cgColor
        v.layer?.shadowColor = NSColor.black.cgColor
        v.layer?.shadowOpacity = 0.12
        v.layer?.shadowRadius = 7
        v.layer?.shadowOffset = CGSize(width: 0, height: 3)
        v.layer?.masksToBounds = false
        v.isHidden = true
        return v
    }

    /// The folder occupies this sub-rect of the rest SVG's 1163×1044 canvas
    /// (the rest is shadow margin) — used to bleed the margin outside the node.
    private static let svgSize = CGSize(width: 1163, height: 1044)
    private static let folderRect = CGRect(x: 105, y: 113, width: 953, height: 818)

    private static let restImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "Folder_Rest", withExtension: "svg")
        else { return nil }
        let img = NSImage(contentsOf: url)
        img?.resizingMode = .stretch
        return img
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        shapeView.image = Self.restImage
        shapeView.imageScaling = .scaleAxesIndependently
        shapeView.wantsLayer = true
        shapeView.layer?.masksToBounds = false
        addSubview(shapeView)
        // Behind the folder body so only their tops peek out.
        for cover in peekCovers { addSubview(cover, positioned: .below, relativeTo: shapeView) }

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
        let visible = min(childIDs.count, peekCovers.count)
        for (i, c) in peekCovers.enumerated() { c.isHidden = i >= visible }
        needsLayout = true
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
                                 height: Self.svgSize.height * sy)

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

        // Peeking child-card covers — a small receding stack out the folder's
        // top (centred, right of the tab). Behind the body so only the tops show.
        let coverW = w * 0.46, coverH = h * 0.36
        let vis = peekCovers.enumerated().filter { !$0.element.isHidden }
        let n = vis.count
        for (slot, pair) in vis.enumerated() {
            let backDepth = CGFloat(n - 1 - slot)          // backmost peeks highest
            let cx = w / 2 + (CGFloat(slot) - CGFloat(n - 1) / 2) * (w * 0.06)
            let topY = -h * 0.14 - backDepth * (h * 0.03)  // negative = above the top (flipped)
            pair.element.frame = NSRect(x: cx - coverW / 2, y: topY,
                                        width: coverW, height: coverH)
        }
    }
}
