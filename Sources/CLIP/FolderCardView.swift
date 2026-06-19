import AppKit

/// Native folder card (Figma `Folder_Rest` 58:210 + the user's recording):
/// a white folder silhouette with a tab notch top-left, a faint centered
/// upload-arrow (drop affordance) while empty, the item count + name lower-left,
/// and the chosen identity icon as a chip lower-right. Renders in `CardItemView`
/// like the other native card kinds; refreshes in place via `NativeCardUpdatable`.
final class FolderCardView: NSView, NativeCardUpdatable {
    private let shapeLayer = CAShapeLayer()      // folder silhouette (tab + body)
    private let frontLayer = CAShapeLayer()      // the front "pocket" panel
    private let dividerLayer = CAShapeLayer()    // hairline where the pocket meets the back
    private let arrowCircle = NSView()
    private let arrowIcon = NSImageView()
    private let countField = NSTextField(labelWithString: "No items")
    private let titleField = NSTextField(labelWithString: "Untitled")
    private let iconChip = NSView()
    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        // Folder silhouette — geometry-flipped so the path uses the Figma's
        // top-left origin. Soft folder-shaped float shadow on the back layer.
        shapeLayer.isGeometryFlipped = true
        shapeLayer.fillColor = NSColor(white: 0.97, alpha: 1).cgColor
        shapeLayer.shadowColor = NSColor.black.cgColor
        shapeLayer.shadowOpacity = 0.14
        shapeLayer.shadowRadius = 14
        shapeLayer.shadowOffset = CGSize(width: 0, height: -8)   // flipped → downward
        layer?.addSublayer(shapeLayer)

        frontLayer.isGeometryFlipped = true
        frontLayer.fillColor = NSColor(white: 0.995, alpha: 1).cgColor
        shapeLayer.addSublayer(frontLayer)

        dividerLayer.isGeometryFlipped = true
        dividerLayer.fillColor = nil
        dividerLayer.strokeColor = NSColor(white: 0, alpha: 0.04).cgColor
        dividerLayer.lineWidth = 1
        frontLayer.addSublayer(dividerLayer)

        // Centered upload-arrow circle (faint) — the "drop here" affordance.
        arrowCircle.wantsLayer = true
        arrowCircle.layer?.backgroundColor = NSColor(white: 0, alpha: 0.02).cgColor
        arrowIcon.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        arrowIcon.contentTintColor = NSColor(white: 0, alpha: 0.18)
        arrowIcon.imageScaling = .scaleProportionallyUpOrDown
        arrowCircle.addSubview(arrowIcon)
        addSubview(arrowCircle)

        // Count (SF Pro, 40%) over the name (SF Mono), lower-left.
        countField.textColor = NSColor(white: 0, alpha: 0.4)
        countField.font = .systemFont(ofSize: 13, weight: .light)
        addSubview(countField)
        titleField.textColor = .black
        titleField.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        addSubview(titleField)

        // Identity-icon chip, lower-right.
        iconChip.wantsLayer = true
        iconChip.layer?.backgroundColor = NSColor.white.cgColor
        iconChip.layer?.cornerRadius = 12
        iconChip.layer?.cornerCurve = .continuous
        iconChip.layer?.shadowColor = NSColor.black.cgColor
        iconChip.layer?.shadowOpacity = 0.12
        iconChip.layer?.shadowRadius = 5
        iconChip.layer?.shadowOffset = CGSize(width: 0, height: -1)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .black
        iconChip.addSubview(iconView)
        addSubview(iconChip)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }     // top-left origin for subviews

    func update(for node: CanvasNode) {
        guard case .folder(let title, let icon, let childIDs) = node.kind else { return }
        titleField.stringValue = title.isEmpty ? "Untitled" : title
        countField.stringValue = childIDs.isEmpty ? "No items"
            : "\(childIDs.count) Item\(childIDs.count == 1 ? "" : "s")"
        arrowCircle.isHidden = !childIDs.isEmpty       // arrow only while empty
        if icon.isEmpty {
            iconChip.isHidden = true
        } else {
            iconChip.isHidden = false
            iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        guard w > 1, h > 1 else { return }
        let r = min(w, h) * 0.085

        CATransaction.begin(); CATransaction.setDisableActions(true)
        shapeLayer.frame = bounds
        let silhouette = Self.folderPath(w: w, h: h, r: r)
        shapeLayer.path = silhouette
        shapeLayer.shadowPath = silhouette

        let frontTop = h * 0.16
        let front = CGRect(x: 0, y: frontTop, width: w, height: h - frontTop)
        frontLayer.frame = bounds
        let frontPath = CGPath(roundedRect: front, cornerWidth: r, cornerHeight: r, transform: nil)
        frontLayer.path = frontPath
        dividerLayer.frame = bounds
        dividerLayer.path = CGPath(roundedRect: front.insetBy(dx: 1, dy: 1),
                                   cornerWidth: r, cornerHeight: r, transform: nil)
        CATransaction.commit()

        // Subviews (top-left coords).
        let circle = min(w, h) * 0.22
        arrowCircle.frame = CGRect(x: (w - circle) / 2, y: h * 0.30, width: circle, height: circle)
        arrowCircle.layer?.cornerRadius = circle / 2
        arrowIcon.frame = arrowCircle.bounds.insetBy(dx: circle * 0.3, dy: circle * 0.3)

        let pad = w * 0.115
        countField.sizeToFit()
        titleField.sizeToFit()
        let titleY = h - frontTop - titleField.frame.height - h * 0.10
        titleField.frame.origin = CGPoint(x: pad, y: titleY)
        countField.frame.origin = CGPoint(x: pad, y: titleY - countField.frame.height - 2)

        let chip = min(w, h) * 0.20
        iconChip.frame = CGRect(x: w - pad - chip, y: titleY - chip * 0.15,
                                width: chip, height: chip)
        iconChip.layer?.cornerRadius = chip * 0.28
        iconView.frame = iconChip.bounds.insetBy(dx: chip * 0.26, dy: chip * 0.26)
    }

    /// Folder silhouette: rounded body with a tab notch at the top-left that
    /// steps down to the rest of the top edge. Top-left origin (y down).
    static func folderPath(w: CGFloat, h: CGFloat, r: CGFloat) -> CGPath {
        let tabRight = w * 0.37
        let notchEnd = w * 0.47
        let stepY = h * 0.16
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: r))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))            // TL
        p.addLine(to: CGPoint(x: tabRight, y: 0))                                         // tab top
        p.addCurve(to: CGPoint(x: notchEnd, y: stepY),                                    // notch step
                   control1: CGPoint(x: tabRight + (notchEnd - tabRight) * 0.6, y: 0),
                   control2: CGPoint(x: notchEnd, y: stepY * 0.35))
        p.addLine(to: CGPoint(x: w - r, y: stepY))
        p.addQuadCurve(to: CGPoint(x: w, y: stepY + r), control: CGPoint(x: w, y: stepY)) // TR
        p.addLine(to: CGPoint(x: w, y: h - r))
        p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))         // BR
        p.addLine(to: CGPoint(x: r, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))         // BL
        p.closeSubpath()
        return p
    }
}
