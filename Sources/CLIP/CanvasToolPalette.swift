import AppKit
import SwiftUI

// MARK: - NativeCanvasToolPalette  (public SwiftUI bridge — alias of _PaletteRepresentable)

/// Mounts the candy-yellow tool palette at the bottom-center of the canvas.
/// All rendering is native AppKit so hit-testing, layer shadows, and animation
/// are precise — no SwiftUI geometry mangling.
///
/// Usage (CanvasView.swift):
///   `_PaletteRepresentable(state: state).frame(width: totalW, height: totalH)`
/// This type is exposed so callers outside this file can reference the
/// CanvasToolPaletteView dimension constants without needing the concrete
/// representable struct.
typealias NativeCanvasToolPalette = _PaletteRepresentable

// MARK: - CanvasToolPaletteView

/// The full horizontal assembly: [main yellow pill] [10 pt gap] [round + pill].
///
/// Figma node 60:12981 — Frame 44 — width 542 × height 62 (plus overflow for
/// the decorative props that poke above the pill and for the drop shadow bleed).
///
/// Visual hierarchy (bottom → top):
///   1. Green outer capsule (border colour #3DA726, drop-shadow)
///   2. Yellow inner capsule (gradient #FFF53B → #F8DE47, top rim #FFFCA9)
///   3. Tool buttons — active one gets a green (#3DA726) fill circle
///   4. Decorative SVG props (Marker, Stickers) — overflow above the pill
///   5. Round "add / section" pill (same candy skin)
final class CanvasToolPaletteView: NSView {

    // MARK: Sub-views

    /// The five-tool main pill  (470 × 62 canvas-rect, but drawn with
    /// extra padding so its drop-shadow is never clipped by the host's bounds).
    private let mainPill = MainPillView()

    /// The round "+" / section pill (62 × 62).
    private let addPill = AddPillView()

    /// Drop-shadows for both pills live HERE (in the full-size host) rather than
    /// inside the pill views — a pill's bounds are only as tall as the pill, so a
    /// shadow parented there is clipped at the pill's bottom edge before it can
    /// reach the host's shadow-bleed room. Parented here, the host's totalW×totalH
    /// bounds fully contain the shadow, so nothing can clip it.
    private let mainShadows = makeCandyShadowLayers()
    private let addShadows  = makeCandyShadowLayers()

    /// The folder-selection action bar (Download / Color / Eject) the toolbar
    /// morphs INTO when a folder is selected (Figma 72:37017). Same candy skin,
    /// narrower capsule; crossfades with the tool pills via `setFolderMode`.
    private let folderBar = FolderActionBarView()
    private let folderShadows = makeCandyShadowLayers()
    private var folderMode = false

    /// Callback injected by `configure(active:onTap:)`.
    var onToolTap: ((ToolMode) -> Void)?
    var onAddTap: (() -> Void)?
    var onFolderTap: (() -> Void)?
    /// Sticker prop tapped → drop a sticky at viewport centre (Spatial-style).
    var onStickerTap: (() -> Void)?
    // Folder-bar actions (only live while morphed in).
    var onDownloadTap: (() -> Void)?
    var onEjectTap: (() -> Void)?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false

        // Shadow layers go behind the pill subviews (zPosition keeps them back).
        (mainShadows + addShadows + folderShadows).forEach {
            $0.zPosition = -1
            layer?.addSublayer($0)
        }

        addSubview(mainPill)
        addSubview(addPill)

        mainPill.onToolTap    = { [weak self] tool in self?.onToolTap?(tool) }
        mainPill.onFolderTap  = { [weak self] in self?.onFolderTap?() }
        mainPill.onStickerTap = { [weak self] in self?.onStickerTap?() }
        addPill.onTap         = { [weak self] in self?.onAddTap?() }
        addPill.accessibilityName = "Add Link or File"

        // Folder bar starts hidden + slightly shrunk (springs in on morph).
        addSubview(folderBar)
        folderBar.alphaValue = 0
        folderBar.isHidden = true
        folderShadows.forEach { $0.opacity = 0 }
        folderBar.onDownload = { [weak self] in self?.onDownloadTap?() }
        folderBar.onColor    = { [weak self] in self?.presentColorFlower() }
        folderBar.onEject    = { [weak self] in self?.onEjectTap?() }

        // Allow the morph's animated Gaussian blur to render on these layers.
        [mainPill, addPill, folderBar].forEach { $0.layerUsesCoreImageFilters = true }
    }

    // MARK: - Layout

    /// Total width = 386 + 10 + 62 = 458 pt (Figma 89-610 — smaller toolbar).
    /// We add `shadowBleed` of padding on every side so the host NSView
    /// is larger than the visual content and the drop-shadow is never clipped.
    static let mainPillW: CGFloat  = 386
    static let addPillW: CGFloat   = 62
    static let gap: CGFloat        = 10
    /// Visual content height = 62; decorative props overflow ~12 pt above.
    static let contentH: CGFloat   = 62
    static let propOverflow: CGFloat = 32   // marker cap pokes ~28 pt above the pill
    /// Bottom gap = how far the pill sits off the viewport bottom (18 pt, user
    /// spec) AND the room for the visible drop-shadow. The frame bottom sits flush
    /// with the viewport (`.padding(.bottom, 0)`), so the faint shadow tail past
    /// 18 pt simply fades off the screen edge — no hard cut-off in the canvas.
    static let shadowBleed: CGFloat  = 18
    static let totalW: CGFloat =
        mainPillW + gap + addPillW + shadowBleed * 2
    static let totalH: CGFloat =
        contentH + propOverflow + shadowBleed

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.totalW, height: Self.totalH)
    }

    override func layout() {
        super.layout()
        let b = bounds

        // Horizontally centered, pushed to the shadow-bleed bottom
        let leftEdge = (b.width  - (Self.mainPillW + Self.gap + Self.addPillW)) / 2
        let bottomY  = Self.shadowBleed  // Y=0 is visually below pill

        // Main pill  (includes its own propOverflow header above the 62-pt pill)
        mainPill.frame = NSRect(
            x: leftEdge,
            y: bottomY,
            width: Self.mainPillW,
            height: Self.contentH + Self.propOverflow
        )
        // Add pill — Figma's parent flex is `items-center`, both pills are 62 pt,
        // so the add capsule must be flush with the main pill's capsule (which sits
        // in the BOTTOM 62 pt of mainPill, i.e. at `bottomY`). NOT offset up by the
        // prop overflow — that was lifting the "+" 14 pt above the row.
        addPill.frame = NSRect(
            x: leftEdge + Self.mainPillW + Self.gap,
            y: bottomY,
            width: Self.addPillW,
            height: Self.contentH
        )

        // Drop-shadows, in THIS view's non-flipped space (Y-up → "down" is -Y).
        // The green capsule of each pill sits at the bottom contentH of its frame.
        let mainCapsule = NSRect(x: leftEdge, y: bottomY,
                                 width: Self.mainPillW, height: Self.contentH)
        let addCapsule  = NSRect(x: leftEdge + Self.mainPillW + Self.gap, y: bottomY,
                                 width: Self.addPillW, height: Self.contentH)
        layoutCandyShadows(mainShadows, capsule: mainCapsule,
                           radius: Self.contentH / 2, downSign: -1)
        layoutCandyShadows(addShadows, capsule: addCapsule,
                           radius: Self.contentH / 2, downSign: -1)

        // Folder bar — centered on the whole toolbar (so the morph collapses to
        // the row's centre), same bottom + height as the pills.
        let folderRect = NSRect(x: b.width / 2 - FolderActionBarView.outerW / 2, y: bottomY,
                                width: FolderActionBarView.outerW, height: Self.contentH)
        folderBar.frame = folderRect
        layoutCandyShadows(folderShadows, capsule: folderRect,
                           radius: Self.contentH / 2, downSign: -1)
    }

    // MARK: - State

    func configure(active: ToolMode) {
        mainPill.configure(active: active)
    }

    /// Drives the "+" button's green selected skin (link input open/closed).
    func setAddSelected(_ on: Bool) {
        addPill.setSelected(on)
    }

    // MARK: - Folder-bar morph

    /// Called on flower pick: the colour + the ids captured when the flower
    /// opened (so a selection change while picking can't drop the target).
    var onColorPick: ((NSColor, [UUID]) -> Void)?
    /// Current canvas selection (set by the bridge) — snapshotted at Color-tap.
    var selectionProvider: (() -> [UUID])?
    /// Read a folder's current tint hex (or nil) — to capture originals so a
    /// hover-preview can be reverted if the picker is dismissed without a pick.
    var folderColorReader: ((UUID) -> String?)?
    /// Set a folder's tint WITHOUT undo (live hover preview; nil = restore).
    var folderColorPreviewer: ((UUID, String?) -> Void)?
    /// The currently-open flower, so a second tap on the Color button toggles it
    /// CLOSED instead of stacking another picker on top.
    private weak var activeFlower: RadialColorPicker?

    /// Morph between the tool pills and the folder action bar (Figma 72:37017):
    /// a spring crossfade + subtle scale — the Apple-style contextual-toolbar
    /// swap. The candy skin is shared, so it reads as one bar changing contents.
    func setFolderMode(_ on: Bool, animated: Bool = true) {
        guard on != folderMode else { return }
        folderMode = on
        let dur: CFTimeInterval = animated ? 0.30 : 0
        let toolViews: [NSView] = [mainPill, addPill]

        if on { folderBar.isHidden = false } else { mainPill.isHidden = false; addPill.isHidden = false }

        for v in toolViews {
            springFade(v.layer, to: on ? 0 : 1, dur: dur)
            CLIPSpring.scale(v, to: on ? 0.90 : 1.0, preset: .surface, key: "morph")
            morphBlur(v, fadingOut: on, dur: dur)            // SwiftUI-style blur
        }
        (mainShadows + addShadows).forEach { springFade($0, to: on ? 0 : 1, dur: dur) }
        springFade(folderBar.layer, to: on ? 1 : 0, dur: dur)
        CLIPSpring.scale(folderBar, to: on ? 1.0 : 0.90, preset: .surface, key: "morph")
        morphBlur(folderBar, fadingOut: !on, dur: dur)
        folderShadows.forEach { springFade($0, to: on ? 1 : 0, dur: dur) }

        // Drop the faded-out group from hit-testing once the crossfade settles.
        let target = on
        DispatchQueue.main.asyncAfter(deadline: .now() + max(dur, 0.01) + 0.05) { [weak self] in
            guard let self, self.folderMode == target else { return }
            self.mainPill.isHidden = target
            self.addPill.isHidden = target
            self.folderBar.isHidden = !target
        }
    }

    private func springFade(_ layer: CALayer?, to v: CGFloat, dur: CFTimeInterval) {
        guard let layer else { return }
        if dur <= 0 { layer.removeAnimation(forKey: "morphFade"); layer.opacity = Float(v); return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = layer.presentation()?.opacity ?? layer.opacity
        a.toValue = v
        a.duration = dur
        a.timingFunction = CLIPSpring.easeOutSoft
        a.fillMode = .forwards
        layer.opacity = Float(v)
        layer.add(a, forKey: "morphFade")
    }

    /// Animated Gaussian blur on a morphing view — the SwiftUI "blur material"
    /// transition feel. Fading-out blurs 0→max; fading-in sharpens max→0. The
    /// filter is cleared once settled so there's no idle render cost.
    private func morphBlur(_ view: NSView, fadingOut: Bool, dur: CFTimeInterval) {
        guard let layer = view.layer, dur > 0, let f = CIFilter(name: "CIGaussianBlur") else {
            view.layer?.filters = nil; return
        }
        let maxR: CGFloat = 7
        let from: CGFloat = fadingOut ? 0 : maxR
        let to: CGFloat = fadingOut ? maxR : 0
        f.name = "blur"
        f.setValue(to, forKey: "inputRadius")
        layer.filters = [f]
        let a = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        a.fromValue = from; a.toValue = to
        a.duration = dur
        a.timingFunction = CLIPSpring.easeOutSoft
        layer.add(a, forKey: "morphBlur")
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.06) { [weak view] in view?.layer?.filters = nil }
    }

    /// Bloom the flower color picker above the folder bar's Color (droplet) button.
    /// Routed through SCREEN coordinates (always y-up, bottom-left origin) so the
    /// host view's flipped-ness can't invert "above" — the disc floats above the
    /// bar with no overlap.
    func presentColorFlower() {
        guard let window = self.window, let host = window.contentView else { return }
        // Toggle: a second tap on the Color button closes the open flower.
        if let open = activeFlower, open.superview != nil {
            open.dismiss(); activeFlower = nil; return
        }
        let targets = selectionProvider?() ?? []          // capture the selection now
        // Snapshot each target's current tint so a dismiss-without-pick reverts.
        let originals: [UUID: String?] = Dictionary(uniqueKeysWithValues:
            targets.map { ($0, folderColorReader?($0) ?? nil) })
        var committed = false
        let picker = RadialColorPicker()
        // Live preview: recolour the folder(s) to the hovered petal; restore on nil.
        picker.onHoverPreview = { [weak self] color in
            guard let self else { return }
            if let color {
                let hex = color.hexRGB
                for id in targets { self.folderColorPreviewer?(id, hex) }
            } else {
                for id in targets { self.folderColorPreviewer?(id, originals[id] ?? nil) }
            }
        }
        picker.onPick = { [weak self] c in
            committed = true
            // The live preview already set the tint; this commits it (and is the
            // undoable entry). No restore-first — that risked leaving it reverted.
            self?.onColorPick?(c, targets)
        }
        picker.onDismiss = { [weak self] in
            self?.activeFlower = nil
            guard !committed else { return }
            for id in targets { self?.folderColorPreviewer?(id, originals[id] ?? nil) }
        }
        activeFlower = picker
        let btnCenterSelf = CGPoint(x: folderBar.frame.minX + FolderActionBarView.colorButtonCenterX,
                                    y: folderBar.frame.midY)
        let btnScreen = window.convertPoint(toScreen: convert(btnCenterSelf, to: nil))
        // Up in screen space (+y). Disc overlaps the bar top ~19pt (Spatial-style):
        // half-bar 31 + disc radius 68 − overlap 19 ≈ 80.
        let discScreen = CGPoint(x: btnScreen.x, y: btnScreen.y + 80)
        let discInHost = host.convert(window.convertPoint(fromScreen: discScreen), from: nil)
        picker.present(in: host, at: discInHost)
    }
}

// MARK: - Candy drop-shadow (Figma node 60:12982 / 60:13020)

/// One level of the pill's layered green drop-shadow. A `CALayer` holds only a
/// single shadow, so the four Figma levels are rendered as four stacked
/// shadow-casting layers behind the capsule.
private struct CandyShadowLevel {
    let y: CGFloat      // downward offset (pt)
    let blur: CGFloat   // → shadowRadius
    let alpha: Float    // → shadowOpacity
}

/// Figma drop-shadow on the green capsule, top → bottom (the 38 px level is
/// fully transparent in Figma and omitted). Blur values are Figma's own iOS
/// `shadowRadius` export (2× the CSS blur):
///   offset 2  radius 3   rgba(0,92,2,0.12)
///   offset 6  radius 6   rgba(0,92,2,0.10)
///   offset 14 radius 8   rgba(0,92,2,0.06)
///   offset 24 radius 10  rgba(0,92,2,0.02)
private let candyShadowLevels: [CandyShadowLevel] = [
    .init(y: 2,  blur: 3,  alpha: 0.12),
    .init(y: 6,  blur: 6,  alpha: 0.10),
    .init(y: 14, blur: 8,  alpha: 0.06),
    .init(y: 24, blur: 10, alpha: 0.02),
]

/// `rgba(0, 92, 2, 1)` — the shadow's green tint (#005C02).
private let candyShadowColor =
    NSColor(srgbRed: 0, green: 92.0 / 255, blue: 2.0 / 255, alpha: 1).cgColor

/// Builds the four shadow-casting layers (clear-filled; the shadow comes from
/// `shadowPath`, set per-layout). Add these BEHIND the green capsule.
private func makeCandyShadowLayers() -> [CALayer] {
    candyShadowLevels.map { level in
        let l = CALayer()
        l.backgroundColor = NSColor.clear.cgColor
        l.shadowColor     = candyShadowColor
        l.shadowOpacity   = level.alpha
        l.shadowRadius    = level.blur
        l.shadowOffset    = .zero        // offset is baked into the path (below)
        l.masksToBounds   = false
        return l
    }
}

/// Positions the shadow layers over `capsule`. Each layer's FRAME is offset by
/// its level's Y in the "down" direction — `downSign` is +1 for a flipped host
/// (Y-down) or -1 for a non-flipped host (Y-up). The shadowPath is just the
/// layer's own bounds, so we never depend on `geometryFlipped` path orientation.
private func layoutCandyShadows(_ layers: [CALayer], capsule: CGRect,
                                radius: CGFloat, downSign: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let path = CGPath(
        roundedRect: CGRect(origin: .zero, size: capsule.size),
        cornerWidth: radius, cornerHeight: radius, transform: nil
    )
    for (i, l) in layers.enumerated() {
        l.frame = capsule.offsetBy(dx: 0, dy: candyShadowLevels[i].y * downSign)
        l.shadowPath = path
    }
    CATransaction.commit()
}

// MARK: - MainPillView

/// The 470 × (62 + propOverflow) view.  The bottom 62 pt is the candy pill;
/// the top `propOverflow` pt is where Marker / Stickers poke above the rim.
private final class MainPillView: NSView {

    // MARK: Geometry (all in the bottom 62-pt pill local space)

    private static let pillH: CGFloat       = 62     // outer pill height
    private static let innerH: CGFloat      = 58     // inner yellow capsule height
    private static let innerTop: CGFloat    = 2      // top inset of inner capsule
    private static let innerSideInset: CGFloat = 2   // each side
    private static let buttonSize: CGFloat  = 52
    private static let iconSize: CGFloat    = 24
    private static let buttonRadius: CGFloat = 60    // "60px" in Figma

    // Button X origins within inner capsule (Figma 89-610 — smaller toolbar,
    // Folder button REMOVED from the bar; it moved to the + add popover).
    // Cursor  left=2
    // Hand    left=56
    // Text    left=274 (opacity 70%)
    // Connect left=328 (opacity 70%)
    private static let buttonXs: [CGFloat] = [2, 56, 274, 328]
    private static let buttonOpacities: [CGFloat] = [1, 1, 0.7, 0.7]
    // Each button's tool MODE + its icon. Marker / Sticky are NOT buttons;
    // they're the decorative props (made clickable below).
    private static let buttonModes: [ToolMode?] =
        [.select, .hand, .text, .connect]
    private static let buttonIcons: [String] =
        ["tool_select", "tool_hand", "tool_text", "tool_connect"]

    // Decorative prop positions (Figma 89-610, inner-capsule coords; Y from top).
    // Marker:   x=117  (overflows above rim by 12)
    // Stickers: x=176  (overflows above rim by 6)
    // Figma 90-362/90-406: marker-btn at left=112, top=-28 (71×84). The container
    // bottom lands at inner-y 56 (above the toolbar bottom → never overflows the
    // green ring), and the cap pokes 28pt above (needs propOverflow ≥ ~30).
    private static let markerX: CGFloat   = 112
    private static let markerY: CGFloat   = -16   // rest: chisel base flush with pill bottom; hover slides it up 10pt
    private static let stickersX: CGFloat = 165   // 126×76 frame (Figma sticky-btn 90-557/90-537)
    private static let stickersY: CGFloat = -18   // frame bottom flush with capsule bottom (58)

    // MARK: Layers

    private let outerLayer   = CALayer()      // green border
    private let innerLayer   = CAGradientLayer() // yellow gradient
    private let rimLayer     = CALayer()      // top highlight rim

    // Tool button views (index-matched to buttonModes)
    private var buttonViews: [ToolPaletteButton] = []

    // Decorative prop views — clickable (Marker = Draw, Stickers = Sticky).
    private let markerView   = PropButton(image: nil)
    private let stickersView = StickerProp()

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true

        // --- Outer green border layer ---  (drop-shadow is host-parented)
        outerLayer.backgroundColor  = NSColor.paletteHex(0x3DA726).cgColor
        outerLayer.masksToBounds    = false
        layer?.addSublayer(outerLayer)

        // --- Inner yellow gradient ---
        // Figma 60:12983: body gradient #FFF53B → #F8DE47 with a 2 pt pale rim
        // (#FFFCA9) on the TOP edge ONLY (`border-t-2`). A crisp 4-stop vertical
        // gradient renders the rim only along the rounded top — never the sides
        // or bottom — so the green outer ring stays the sole full-perimeter edge.
        innerLayer.colors = [
            NSColor.paletteHex(0xFFFCA9).cgColor,   // pale top rim
            NSColor.paletteHex(0xFFFCA9).cgColor,
            NSColor.paletteHex(0xFFF53B).cgColor,   // body top
            NSColor.paletteHex(0xF8DE47).cgColor    // body bottom
        ]
        // rim ≈ 2 pt of the 58 pt capsule → 2/58 ≈ 0.0345
        innerLayer.locations = [0.0, 0.0345, 0.0345, 1.0]
        innerLayer.startPoint = CGPoint(x: 0.5, y: 0)
        innerLayer.endPoint   = CGPoint(x: 0.5, y: 1)
        innerLayer.masksToBounds = true
        outerLayer.addSublayer(innerLayer)

        // --- Tool buttons ---
        for (i, icon) in Self.buttonIcons.enumerated() {
            let btn = ToolPaletteButton(iconName: icon)
            btn.accessibilityName = ToolPaletteButton.displayName(for: icon)
            btn.iconRestOpacity = Self.buttonOpacities[i]
            let mode = Self.buttonModes[i]
            btn.onTap = { [weak self] in
                if let mode { self?.onToolTap?(mode) }   // enter a tool mode
                else { self?.onFolderTap?() }            // the Folder action button
            }
            addSubview(btn)
            buttonViews.append(btn)
        }

        // --- Decorative props (clickable: Marker = Draw, Stickers = Sticky) ---
        // Marker button crossfades rest↔hover artwork on hover (Figma 72:36900),
        // same treatment as the sticky button; no active state.
        // 3 states (Figma marker-rest/hovered/selected, 71×84): rest, the 10pt
        // lift (hover/select), and the lift + glow (selected). Implemented as a
        // slide (the lift) + crossfade (the glow).
        markerView.setMarkerStates(
            rest:     loadBundleImage(named: "marker-hovered"),   // hovered art for rest too (user); just slides 10pt
            selected: loadBundleImage(named: "marker-selected"),
            lift:     10)
        markerView.onTap = { [weak self] in self?.onToolTap?(.draw) }
        markerView.accessibilityName = "Draw"
        addSubview(markerView)

        // Sticky button: paper + corner-fold sheets physically fan apart on hover
        // (Figma 90-557 → 90-537), via CALayer transforms. No selected state.
        stickersView.setElements(
            paper: loadBundleImage(named: "sticky-paper"),
            fold:  loadBundleImage(named: "sticky-corner-fold"))
        stickersView.onTap = { [weak self] in self?.onStickerTap?() }
        stickersView.accessibilityName = "Sticky Note"
        addSubview(stickersView)
    }

    /// Loads an SVG/PNG from the app bundle's Resources folder.
    private func loadBundleImage(named name: String) -> NSImage? {
        let extensions = ["svg", "png", "pdf"]
        for ext in extensions {
            if let url = Bundle.module.url(forResource: name, withExtension: ext) {
                return NSImage(contentsOf: url)
            }
        }
        return nil
    }

    var onToolTap: ((ToolMode) -> Void)?
    var onFolderTap: (() -> Void)?
    var onStickerTap: (() -> Void)?

    // MARK: - Layout

    override var isFlipped: Bool { true }  // Y=0 at top, matching Figma coords

    override func layout() {
        super.layout()
        let propOverflow = CanvasToolPaletteView.propOverflow
        let pillH = Self.pillH
        // The pill strip starts at y = propOverflow (in flipped coords, top of the pill)
        let pillTopY = propOverflow

        // Outer layer: full pill width × height, at pillTopY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outerLayer.frame = CGRect(x: 0, y: pillTopY, width: bounds.width, height: pillH)
        let outerR = pillH / 2   // 31 → effectively 999px-radius capsule
        outerLayer.cornerRadius  = outerR
        outerLayer.cornerCurve   = .continuous

        // Inner layer: 2pt inset on each side, 2pt from top
        let innerW = bounds.width - Self.innerSideInset * 2
        innerLayer.frame  = CGRect(x: Self.innerSideInset, y: Self.innerTop,
                                   width: innerW, height: Self.innerH)
        let innerR = Self.innerH / 2
        innerLayer.cornerRadius = innerR
        innerLayer.cornerCurve  = .continuous
        CATransaction.commit()

        // Tool buttons (coords relative to inner capsule top-left, then shifted by
        // (innerSideInset, innerTop + pillTopY) to land in view space)
        let innerOriginX = Self.innerSideInset
        let innerOriginY = pillTopY + Self.innerTop   // view-local flipped Y

        for (i, btn) in buttonViews.enumerated() {
            let bx = Self.buttonXs[i]
            // Centre the 52pt button in the 58pt inner capsule → even 3pt top/bottom
            // (was 2pt, which read as an uneven 2/4 gap).
            let by: CGFloat = (Self.innerH - Self.buttonSize) / 2
            btn.frame = NSRect(
                x: innerOriginX + bx,
                y: innerOriginY + by,
                width: Self.buttonSize,
                height: Self.buttonSize
            )
        }

        // Decorative props (Figma gives positions relative to inner capsule top)
        // Marker: 71 × 84 (new marker-* SVGs; the extra height is shadow margin)
        let markerW: CGFloat = 71
        let markerH: CGFloat = 84
        markerView.frame = NSRect(
            x: innerOriginX + Self.markerX,
            y: innerOriginY + Self.markerY,
            width: markerW,
            height: markerH
        )

        // Stickers: 89 × 64, at (195, -6) from inner capsule top
        // The Figma clip is bottom-aligned (bottom: 0)
        let stickersW: CGFloat = 126
        let stickersH: CGFloat = 76
        stickersView.frame = NSRect(
            x: innerOriginX + Self.stickersX,
            y: innerOriginY + Self.stickersY,
            width: stickersW,
            height: stickersH
        )
    }

    // MARK: - State

    func configure(active: ToolMode) {
        for (i, btn) in buttonViews.enumerated() {
            btn.setActive(Self.buttonModes[i] == active, animated: true)
        }
        // The Marker / Stickers props are the Draw / Sticky tools — pop them up
        // when their mode is active (Figma selected variant lifts the 3D art).
        markerView.setActive(active == .draw)
        stickersView.setActive(active == .stickyNote)
    }
}

// MARK: - SwiftUI mounting

/// `NSViewRepresentable` that wires `CanvasToolPaletteView` to `CanvasState`.
/// CanvasView mounts this in an `.overlay(alignment: .bottom)` with an explicit
/// `.frame(width: totalW, height: totalH)` so the shadow bleed is honored.
///
/// `toolMode` and `isAddSelected` are stored as value-type fields so SwiftUI
/// can diff them across renders and guarantee `updateNSView` fires on change.
/// Without this, `state` is a reference type — same pointer each render —
/// and SwiftUI skips the update, leaving the "+" button stuck yellow.
struct _PaletteRepresentable: NSViewRepresentable {
    let state: CanvasState
    let toolMode: ToolMode
    let isAddSelected: Bool
    let folderSelected: Bool   // value field so SwiftUI diffs it → updateNSView fires

    init(state: CanvasState) {
        self.state        = state
        self.toolMode     = state.toolMode
        self.isAddSelected = state.isLinkInputPresented
        let ids = state.selectedNodeIDs
        // The contextual action bar shows for folders AND stickies (same bar).
        self.folderSelected = !ids.isEmpty && ids.allSatisfy { id in
            guard let n = state.nodes.first(where: { $0.id == id }) else { return false }
            return n.isFolder || n.isStickyNote || n.isText
        }
    }

    func makeNSView(context: Context) -> CanvasToolPaletteView {
        let v = CanvasToolPaletteView()
        v.configure(active: toolMode)
        v.setAddSelected(isAddSelected)
        wireCallbacks(v, state: state)
        v.setFolderMode(folderSelected, animated: false)
        return v
    }

    func updateNSView(_ nsView: CanvasToolPaletteView, context: Context) {
        nsView.configure(active: toolMode)
        nsView.setAddSelected(isAddSelected)
        wireCallbacks(nsView, state: state)
        nsView.setFolderMode(folderSelected)
    }

    private func wireCallbacks(_ v: CanvasToolPaletteView, state: CanvasState) {
        v.onToolTap = { mode in
            // Text tool drops a text node at viewport centre, focused for input
            // (Spatial-style, like the sticker/folder), then returns to select.
            if mode == .text {
                state.addText()
                return
            }
            // The Marker prop = Draw → a Freeform-style yellow highlighter:
            // wide, translucent yellow stroke.
            if mode == .draw {
                state.drawColor = .highlighter
                state.drawWidth = 18
                state.drawOpacity = 0.4
            }
            withAnimation(Motion.feedback) { state.toolMode = mode }
        }
        v.onFolderTap = { state.addFolder() }   // the Folder button
        v.onStickerTap = { state.addStickyNote() }   // sticker prop → sticky at viewport centre
        // "+" toggles the inline link input (Figma 72:36784); its green
        // selected skin follows `isLinkInputPresented`.
        v.onAddTap = {
            withAnimation(Motion.popper) { state.isLinkInputPresented.toggle() }
        }
        // Folder-bar Color button → flower picks a colour; apply to any selected
        // sections now (folder-colour model is the separate F4 feature).
        v.selectionProvider = { Array(state.selectedNodeIDs) }
        v.folderColorReader = { id in state.nodes.first(where: { $0.id == id })?.folderColor }
        v.folderColorPreviewer = { id, hex in state.previewFolderColor(id: id, hex: hex) }
        v.onColorPick = { nsColor, targets in
            let preset = RadialColorPicker.nearestSectionColor(to: nsColor)
            let hex = nsColor.hexRGB
            for id in targets {
                guard let n = state.nodes.first(where: { $0.id == id }) else { continue }
                if n.isSection          { state.setSectionColor(id: id, to: preset) }
                else if n.isFolder      { state.setFolderColor(id: id, hex: hex) }
                else if n.isStickyNote  { state.setFolderColor(id: id, hex: hex) }   // sticky tint reuses folderColor
            }
        }
        // Download / Eject actions: TODO (pending behaviour spec).
    }

    func makeCoordinator() -> Void { }
}

// MARK: - NSColor hex helper

extension NSColor {
    /// Initialise from a 0xRRGGBB integer literal (calibrated RGB — the
    /// palette's original colour handling; shared with ToolPaletteControls).
    static func paletteHex(_ hex: UInt32) -> NSColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >>  8) & 0xFF) / 255
        let b = CGFloat( hex        & 0xFF) / 255
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }

    /// `#RRGGBB` (sRGB) — used to persist the folder tint.
    var hexRGB: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

// MARK: - FolderActionBarView

/// The folder-selection action bar (Figma 72:37017) the main toolbar morphs
/// INTO when a folder is selected. Same candy skin as the main pill (green
/// `#3DA726` border + `#fff53b→#f8de47` gradient + pale top rim), a narrower
/// 168×62 capsule, with three round icon buttons — Download / Color / Eject.
private final class FolderActionBarView: NSView {

    static let outerW: CGFloat = 168
    static let outerH: CGFloat = 62
    /// Center-x of the Color (droplet) button in this view's coords — used by the
    /// toolbar to bloom the flower picker above it. originX(4) + slot(54) + half(26).
    static let colorButtonCenterX: CGFloat = 84

    var onDownload: (() -> Void)?
    var onColor: (() -> Void)?
    var onEject: (() -> Void)?

    private let outerLayer = CALayer()
    private let innerLayer = CAGradientLayer()
    private let download = ToolPaletteButton(iconName: "Download")
    private let colorBtn = ToolPaletteButton(iconName: "Color")
    private let eject    = ToolPaletteButton(iconName: "Eject")

    override init(frame: NSRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false
        outerLayer.backgroundColor = NSColor.paletteHex(0x3DA726).cgColor
        outerLayer.masksToBounds = false
        layer?.addSublayer(outerLayer)
        innerLayer.colors = [
            NSColor.paletteHex(0xFFFCA9).cgColor, NSColor.paletteHex(0xFFFCA9).cgColor,
            NSColor.paletteHex(0xFFF53B).cgColor, NSColor.paletteHex(0xF8DE47).cgColor,
        ]
        innerLayer.locations = [0.0, 0.0345, 0.0345, 1.0]
        innerLayer.startPoint = CGPoint(x: 0.5, y: 0)
        innerLayer.endPoint   = CGPoint(x: 0.5, y: 1)
        innerLayer.masksToBounds = true
        outerLayer.addSublayer(innerLayer)
        download.onTap = { [weak self] in self?.onDownload?() }
        colorBtn.onTap = { [weak self] in self?.onColor?() }
        eject.onTap    = { [weak self] in self?.onEject?() }
        download.accessibilityName = "Download"
        colorBtn.accessibilityName = "Color"
        eject.accessibilityName    = "Eject"
        [download, colorBtn, eject].forEach(addSubview)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outerLayer.frame = bounds
        outerLayer.cornerRadius = bounds.height / 2
        outerLayer.cornerCurve  = .continuous
        let inset: CGFloat = 2
        innerLayer.frame = bounds.insetBy(dx: inset, dy: inset)
        innerLayer.cornerRadius = innerLayer.frame.height / 2
        innerLayer.cornerCurve  = .continuous
        CATransaction.commit()
        let bs: CGFloat = 52
        let originX: CGFloat = 4
        let y = (bounds.height - bs) / 2
        download.frame = NSRect(x: originX,       y: y, width: bs, height: bs)
        colorBtn.frame = NSRect(x: originX + 54,  y: y, width: bs, height: bs)
        eject.frame    = NSRect(x: originX + 108, y: y, width: bs, height: bs)
    }
}
