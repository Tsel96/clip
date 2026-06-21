import AppKit

// MARK: - Unified canvas-object interaction states (1:1 from Figma)
//
// EVERY canvas object (image / sticky / video / web card / text / folder) has
// three visual states — REST, HOVER, SELECTED — reproduced exactly from the
// Figma "Untitled" page (CaFO3DBaQGOXBOB3Nkp0sZ):
//
//   • Rest    (88:329) — CARD 503², 4-layer ambient drop shadow.
//   • Hover   (88:330) — CARD 524² (× 1.0417), SAME shadow geometry but the two
//                        bottom layers' alpha bumped (0.04→0.05, 0.05→0.06) for a
//                        gentle "lift", and the object scales up a little.
//   • Selected(88:336) — CARD 524² + an OUTLINE offset 8px outward from the card
//                        edge: 4px white stroke, 8px corner radius, with its own
//                        soft 4-layer drop shadow. (Same lifted card shadow as
//                        hover.)
//
// CALayer carries a SINGLE shadow, so each multi-layer Figma shadow is rebuilt
// as a STACK of shadow-only sibling layers (one per Figma layer) — the standard
// faithful technique. All geometry is normalised to the object's width so it
// scales 1:1 to any on-screen size, and divided by the live magnification where
// it must stay a constant *screen* size (the outline stroke).
//
// This is the ONE place the rest/hover/selected spec lives, mirroring Spatial's
// unified `highlightStyle` system so the three states never fight. `CardItemView`
// (generic objects) and `FolderCardView` (curved folder silhouette) both drive
// their chrome from here.

/// The interaction state of a canvas object. `click` reuses the selected shadow
/// but is reserved for a future press treatment; today it maps to `.selected`.
enum CardHighlightState: Equatable {
    case rest
    case hover
    case selected
}

/// One drop-shadow layer, normalised to the object's width (so it scales 1:1).
/// `yN`/`blurN` are fractions of the object width; Figma shadows here have x=0.
struct ShadowSpec {
    let yN: CGFloat      // vertical offset ÷ width
    let blurN: CGFloat   // gaussian blur (≈ CALayer shadowRadius) ÷ width
    let alpha: CGFloat   // black alpha
}

/// The exact Figma shadow stacks (rest base 503; hover/selected divided out of
/// their 3.29× artboard zoom so they're directly comparable). See the file
/// header for the source nodes.
enum CardStateSpec {
    /// REST — Figma 88:329, the four visible layers (the fully-transparent
    /// top layer is dropped).
    static let restShadow: [ShadowSpec] = [
        ShadowSpec(yN: 0.06362, blurN: 0.02584, alpha: 0.01),
        ShadowSpec(yN: 0.03579, blurN: 0.02187, alpha: 0.03),
        ShadowSpec(yN: 0.01590, blurN: 0.01590, alpha: 0.04),
        ShadowSpec(yN: 0.00398, blurN: 0.00795, alpha: 0.05),
    ]

    /// HOVER & SELECTED card shadow — Figma 88:330 / 88:336 CARD. Same geometry
    /// as rest; bottom two layers' alpha lifted.
    static let hoverShadow: [ShadowSpec] = [
        ShadowSpec(yN: 0.06494, blurN: 0.02585, alpha: 0.01),
        ShadowSpec(yN: 0.03657, blurN: 0.02207, alpha: 0.03),
        ShadowSpec(yN: 0.01639, blurN: 0.01639, alpha: 0.05),
        ShadowSpec(yN: 0.00378, blurN: 0.00883, alpha: 0.06),
    ]

    /// SELECTED outline's own drop shadow — Figma 88:340 Outline (the a=0 layer
    /// dropped). Softer/tighter than the card shadow.
    static let outlineShadow: [ShadowSpec] = [
        ShadowSpec(yN: 0.06494, blurN: 0.01293, alpha: 0.01),
        ShadowSpec(yN: 0.03657, blurN: 0.01103, alpha: 0.03),
        ShadowSpec(yN: 0.01639, blurN: 0.00820, alpha: 0.05),
        ShadowSpec(yN: 0.00378, blurN: 0.00441, alpha: 0.06),
    ]

    /// Hover (and selected) scale-up: Figma CARD 524 / 503.
    static let hoverScale: CGFloat = 1.0417

    /// Selected OUTLINE (Figma 88:340). It traces the SCALED (524) selected card:
    /// the 4px-wide white stroke sits in the 4px–8px band OUTSIDE the scaled card
    /// edge (a 4px clear gap, stroke centre 6px out). Expressed relative to the
    /// UNSCALED object width W, the stroke CENTRE is offset by
    ///   (hoverScale−1)/2  (the card's own grow per side) + 6/524·hoverScale
    /// and the stroke width is 4/524·hoverScale — so the outline lands correctly
    /// over the lifted content without cutting into it.
    static let outlineCenterOffsetN: CGFloat = (hoverScale - 1) / 2 + (6.0 / 524.0) * hoverScale  // ≈0.0328
    static let outlineWidthN: CGFloat = (4.0 / 524.0) * hoverScale                                  // ≈0.00795

    /// Shadow stack for a state.
    static func shadow(for state: CardHighlightState) -> [ShadowSpec] {
        switch state {
        case .rest:                return restShadow
        case .hover, .selected:    return hoverShadow
        }
    }
    /// Scale-up for a state (hover & selected lift; rest is 1).
    static func scale(for state: CardHighlightState) -> CGFloat {
        state == .rest ? 1.0 : hoverScale
    }

    // MARK: Folder (curved silhouette) — Figma 58:210 / 211 / 223.
    //
    // The folder body is an irregular silhouette (with the tab notch), so its
    // shadow can't be a rounded-rect `shadowPath`; it's cast from the folder
    // image's own alpha instead (see `SilhouetteShadowStack`). These are the
    // SVG's baked `filter0_dddd` layers (dy, stdDeviation, alpha) normalised to
    // the folder BODY width (953 in the art canvas).
    static let folderShadow: [ShadowSpec] = [
        ShadowSpec(yN: 0.00735, blurN: 0.00787, alpha: 0.09),
        ShadowSpec(yN: 0.02938, blurN: 0.01469, alpha: 0.08),
        ShadowSpec(yN: 0.06611, blurN: 0.01994, alpha: 0.04),
        ShadowSpec(yN: 0.11752, blurN: 0.02361, alpha: 0.01),
    ]
    /// Folder hover/selected scale-up: Figma Union 977 / 953.
    static let folderScale: CGFloat = 1.0252
    static func folderScaleValue(for state: CardHighlightState) -> CGFloat {
        state == .rest ? 1.0 : folderScale
    }

    // MARK: Transition timing (Spatial-snappy: short, quick).
    static let shadowFade: CFTimeInterval = 0.16
    static let outlineFade: CFTimeInterval = 0.14
    /// Scale spring — quick settle, a hair of overshoot (mirrors `CLIPSpring.control`).
    static let scaleSpring = CLIPSpring.Preset(response: 0.26, damping: 0.8)
}

// MARK: - Silhouette drop-shadow stack (folders / irregular shapes)

/// Casts a Figma multi-layer drop shadow from an IMAGE's alpha (not a rounded
/// rect), for irregular silhouettes like the folder. Each Figma layer is a
/// duplicate image layer with its own `shadowRadius`/`shadowOffset` and a nil
/// `shadowPath` (so the shadow is derived from the folder outline + tab). The
/// container sits BEHIND the real (opaque) folder art, so only the shadow that
/// bleeds outside the folder is seen — the duplicate art itself is covered.
final class SilhouetteShadowStack {
    let container = CALayer()
    private var layers: [CALayer] = []

    init() {
        container.masksToBounds = false
        container.zPosition = -1
    }

    private func ensureLayers(_ n: Int) {
        guard layers.count != n else { return }
        for l in layers { l.removeFromSuperlayer() }
        layers = (0..<n).map { _ in
            let l = CALayer()
            l.shadowColor = NSColor.black.cgColor
            l.shadowOffset = .zero
            l.masksToBounds = false
            container.addSublayer(l)
            return l
        }
    }

    /// Update the stack to cast `image`'s shadow at `frame` (the folder image's
    /// frame in the owner's layer space), for `state`. `bodyWidth` is the folder
    /// body's on-screen width (drives the per-width shadow scale). Hidden when
    /// `image` is nil.
    func update(image: CGImage?, frame: CGRect, bodyWidth: CGFloat,
                specs: [ShadowSpec] = CardStateSpec.folderShadow) {
        guard let image, frame.width > 1, frame.height > 1, bodyWidth > 1 else {
            container.isHidden = true; return
        }
        container.isHidden = false
        ensureLayers(specs.count)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.frame = .zero    // children are positioned in the owner's space directly
        for (i, spec) in specs.enumerated() {
            let l = layers[i]
            l.frame = frame
            l.contents = image
            // Opaque duplicate sits behind the real folder art (which covers it);
            // only the shadow that bleeds OUTSIDE the silhouette shows.
            l.opacity = 1
            l.shadowOpacity = Float(spec.alpha)
            l.shadowRadius = spec.blurN * bodyWidth
            l.shadowOffset = CGSize(width: 0, height: spec.yN * bodyWidth)
        }
        CATransaction.commit()
    }

    func setHidden(_ hidden: Bool) { container.isHidden = hidden }
}

// MARK: - Multi-layer drop-shadow stack (rounded-rect objects)

/// Renders a Figma multi-layer drop shadow as a stack of shadow-only CALayers
/// behind an object, and cross-fades the whole stack between REST / HOVER /
/// SELECTED. Each sublayer is a `shadowPath`-backed rounded rect (cheap; no
/// off-screen rasterisation), sized to the object bounds and scaled by width.
///
/// Attach `container` once, behind the object's content; call `update` from the
/// owner's `layout`/chrome refresh.
final class MultiShadowStack {
    /// Parent for the shadow sublayers (added behind content by the owner).
    let container = CALayer()
    private var shadowLayers: [CAShapeLayer] = []
    private var currentState: CardHighlightState = .rest
    private var didInstall = false

    init() {
        container.masksToBounds = false
        container.zPosition = -1
    }

    /// (Re)build `n` shadow sublayers if the count changed.
    private func ensureLayers(_ n: Int) {
        guard shadowLayers.count != n else { return }
        for l in shadowLayers { l.removeFromSuperlayer() }
        shadowLayers = (0..<n).map { _ in
            let l = CAShapeLayer()
            l.fillColor = NSColor.white.cgColor      // the "object" the shadow is cast by
            l.shadowColor = NSColor.black.cgColor
            l.shadowOffset = .zero
            container.addSublayer(l)
            return l
        }
    }

    /// Position + size the stack to `bounds` (object content rect, in the owner's
    /// layer space) with `cornerRadius`, for `state`. Pass `specs` to override the
    /// per-state stack (e.g. the selected OUTLINE's softer shadow). Animates a
    /// cross-fade only when `state` changes.
    func update(bounds: CGRect, cornerRadius: CGFloat, state: CardHighlightState,
                specs specsOverride: [ShadowSpec]? = nil, animated: Bool = true) {
        let specs = specsOverride ?? CardStateSpec.shadow(for: state)
        ensureLayers(specs.count)
        let w = bounds.width
        guard w > 1, bounds.height > 1 else { return }

        let path = CGPath(roundedRect: bounds, cornerWidth: cornerRadius,
                          cornerHeight: cornerRadius, transform: nil)
        let changed = state != currentState
        currentState = state

        // Geometry is applied WITHOUT animation so it tracks live during
        // resize/zoom; only the per-state alpha/blur change cross-fades.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.frame = bounds.standardized.insetBy(dx: -bounds.width, dy: -bounds.height)
        let originInContainer = CGPoint(x: bounds.width, y: bounds.height)
        for (i, spec) in specs.enumerated() {
            let l = shadowLayers[i]
            // Each sublayer fills the object rect (offset so it sits at `bounds`
            // inside the padded container) and casts ITS layer's shadow.
            l.frame = CGRect(origin: originInContainer, size: bounds.size)
            let local = CGPath(roundedRect: CGRect(origin: .zero, size: bounds.size),
                               cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                               transform: nil)
            l.path = local
            l.shadowPath = local
            l.shadowRadius = spec.blurN * w            // CALayer blur ≈ figma blur
            l.shadowOffset = CGSize(width: 0, height: spec.yN * w)
            l.fillColor = NSColor.white.cgColor
        }
        CATransaction.commit()
        _ = path

        if animated && changed {
            for (i, spec) in specs.enumerated() {
                let l = shadowLayers[i]
                let a = CABasicAnimation(keyPath: "shadowOpacity")
                a.fromValue = l.presentation()?.shadowOpacity ?? l.shadowOpacity
                a.toValue = Float(spec.alpha)
                a.duration = CardStateSpec.shadowFade
                a.timingFunction = CLIPSpring.easeOutSoft
                l.add(a, forKey: "shadowFade")
                l.shadowOpacity = Float(spec.alpha)
            }
        } else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (i, spec) in specs.enumerated() { shadowLayers[i].shadowOpacity = Float(spec.alpha) }
            CATransaction.commit()
        }
    }

    func setHidden(_ hidden: Bool) { container.isHidden = hidden }
}

extension NSImage {
    /// A `CGImage` of this image for use as a CALayer's `contents` (folder shadow
    /// casting). Returns nil if the image has no raster.
    func cgImageForShadow() -> CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
