import AppKit
import SwiftUI

// MARK: - Native canvas chrome (the floating "elements around the canvas")
//
// Native AppKit replacements for the SwiftUI floating controls
// (`CanvasFloatingControls`): the bottom-left zoom pill, the bottom-right
// toggles pill, and the top active-tool chip. Each is a plain NSView; a thin
// `NSViewRepresentable` bridge mounts it and pushes state in `updateNSView`
// (SwiftUI drives the updates, so there is no Combine wiring / retain cycle).
// The blur is a real `NSVisualEffectView` (Spatial's controls are native).

/// A borderless icon button for the chrome pills: SF Symbol, soft hover
/// highlight, pointing-hand cursor, click action. No haptics (Spatial restraint).
final class ChromeIconButton: NSView {
    var onClick: () -> Void = {}
    var isOn = false { didSet { applyTint() } }
    /// Tint when ON / OFF (defaults read as primary / secondary label).
    var onColor = NSColor.labelColor
    var offColor = NSColor.secondaryLabelColor

    private let icon = NSImageView()
    private let highlight = CALayer()
    private var tracking: NSTrackingArea?
    private var pointSize: CGFloat = 13
    private var weight: NSFont.Weight = .medium

    init(symbol: String, pointSize: CGFloat = 13, weight: NSFont.Weight = .medium) {
        self.pointSize = pointSize; self.weight = weight
        super.init(frame: .zero)
        wantsLayer = true
        highlight.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        highlight.cornerRadius = 7
        highlight.cornerCurve = .continuous
        highlight.opacity = 0
        layer?.addSublayer(highlight)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setSymbol(symbol)
        applyTint()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ symbol: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
    }
    private func applyTint() { icon.contentTintColor = isOn ? onColor : offColor }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        highlight.frame = bounds.insetBy(dx: 2, dy: 1)
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { fade(1); NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { fade(0); NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) { icon.alphaValue = 0.5 }
    override func mouseUp(with event: NSEvent) {
        icon.alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
    private func fade(_ v: Float) {
        CLIPSpring.run(duration: 0.14) { [weak self] in self?.highlight.opacity = v }
    }
}

/// A blurred, capsule-shaped pill container with a hairline border + soft float
/// shadow — the native twin of SwiftUI's `.regularMaterial` in a `Capsule`.
final class CanvasPill: NSView {
    let blur = NSVisualEffectView()
    let content = NSStackView()
    private let border = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        // Soft float shadow (matches the SwiftUI pills' 0.07/5/y1).
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.07
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -1)   // flipped host → down

        blur.material = .popover
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        border.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        border.borderWidth = 0.5
        blur.layer?.addSublayer(border)

        content.orientation = .horizontal
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let r = bounds.height / 2
        blur.layer?.cornerRadius = r
        blur.layer?.cornerCurve = .continuous
        border.frame = blur.bounds
        border.cornerRadius = r
        border.cornerCurve = .continuous
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        CATransaction.commit()
    }

    /// A thin vertical divider for between grouped buttons.
    static func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return v
    }
}

// MARK: - Toggles pill (connectors / grid / video previews)

final class CanvasTogglesPillView: NSView {
    var onToggleConnectors: () -> Void = {}
    var onToggleGrid: () -> Void = {}
    var onTogglePreview: () -> Void = {}

    private let pill = CanvasPill()
    private let connectorsBtn = ChromeIconButton(symbol: "point.3.connected.trianglepath.dotted")
    private let gridBtn = ChromeIconButton(symbol: "circle.grid.3x3")
    private let previewBtn = ChromeIconButton(symbol: "play.fill")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for b in [connectorsBtn, gridBtn, previewBtn] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
        }
        connectorsBtn.onClick = { [weak self] in self?.onToggleConnectors() }
        gridBtn.onClick = { [weak self] in self?.onToggleGrid() }
        previewBtn.onClick = { [weak self] in self?.onTogglePreview() }
        pill.content.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        pill.content.addArrangedSubview(connectorsBtn)
        pill.content.addArrangedSubview(CanvasPill.divider())
        pill.content.addArrangedSubview(gridBtn)
        pill.content.addArrangedSubview(CanvasPill.divider())
        pill.content.addArrangedSubview(previewBtn)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 32 * 3 + 2 + 12, height: 34) }

    func configure(connectors: Bool, grid: Bool, previewOnly: Bool) {
        connectorsBtn.setSymbol(connectors ? "point.3.filled.connected.trianglepath.dotted"
                                           : "point.3.connected.trianglepath.dotted")
        connectorsBtn.isOn = connectors
        gridBtn.setSymbol(grid ? "circle.grid.3x3.fill" : "circle.grid.3x3")
        gridBtn.isOn = grid
        previewBtn.setSymbol(previewOnly ? "play.slash.fill" : "play.fill")
        previewBtn.isOn = previewOnly
    }
}

struct NativeCanvasTogglesPill: NSViewRepresentable {
    @EnvironmentObject var state: CanvasState
    func makeNSView(context: Context) -> CanvasTogglesPillView { CanvasTogglesPillView() }
    func updateNSView(_ v: CanvasTogglesPillView, context: Context) {
        v.onToggleConnectors = { state.showConnectors.toggle() }
        v.onToggleGrid = { state.showGrid.toggle() }
        v.onTogglePreview = { state.videosShowPreviewOnly.toggle() }
        v.configure(connectors: state.showConnectors, grid: state.showGrid,
                    previewOnly: state.videosShowPreviewOnly)
    }
}

// MARK: - Zoom pill (− / NN% menu / +)

final class ZoomControlsPillView: NSView {
    var onZoomIn: () -> Void = {}
    var onZoomOut: () -> Void = {}
    var onReset: () -> Void = {}
    var onFit: () -> Void = {}
    var onZoomToSelection: () -> Void = {}
    var onSetZoom: (Double) -> Void = { _ in }

    private let pill = CanvasPill()
    private let minus = ChromeIconButton(symbol: "minus", pointSize: 12)
    private let plus = ChromeIconButton(symbol: "plus", pointSize: 12)
    private let percent = NSButton()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for b in [minus, plus] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        }
        minus.onClick = { [weak self] in self?.onZoomOut() }
        plus.onClick = { [weak self] in self?.onZoomIn() }

        // Clickable percent readout → dropdown menu (monospaced digits so the
        // pill width doesn't jitter as the zoom changes).
        percent.bezelStyle = .inline
        percent.isBordered = false
        percent.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        percent.contentTintColor = .labelColor
        percent.target = self
        percent.action = #selector(showZoomMenu)
        percent.translatesAutoresizingMaskIntoConstraints = false
        percent.widthAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true

        pill.content.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        pill.content.addArrangedSubview(minus)
        pill.content.addArrangedSubview(percent)
        pill.content.addArrangedSubview(plus)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 30 + 50 + 30 + 8, height: 34) }

    func configure(zoom: Double) {
        percent.title = "\(Int((zoom * 100).rounded())) %"
    }

    @objc private func showZoomMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Zoom to 100%", action: #selector(zoomReset), keyEquivalent: "")
        menu.addItem(withTitle: "Zoom to fit", action: #selector(zoomFit), keyEquivalent: "")
        menu.addItem(withTitle: "Zoom to selection", action: #selector(zoomSel), keyEquivalent: "")
        menu.addItem(.separator())
        for pct in [25, 50, 100, 200, 400] {
            let it = NSMenuItem(title: "\(pct)%", action: #selector(zoomPreset(_:)), keyEquivalent: "")
            it.representedObject = pct
            it.target = self
            menu.addItem(it)
        }
        for it in menu.items where it.target == nil { it.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: percent.frame.minX, y: percent.frame.minY - 6), in: pill.content)
    }
    @objc private func zoomReset() { onReset() }
    @objc private func zoomFit() { onFit() }
    @objc private func zoomSel() { onZoomToSelection() }
    @objc private func zoomPreset(_ sender: NSMenuItem) {
        if let pct = sender.representedObject as? Int { onSetZoom(Double(pct) / 100) }
    }
}

struct NativeZoomControlsPill: NSViewRepresentable {
    @EnvironmentObject var state: CanvasState
    @EnvironmentObject var cameraStore: CameraStore
    func makeNSView(context: Context) -> ZoomControlsPillView { ZoomControlsPillView() }
    func updateNSView(_ v: ZoomControlsPillView, context: Context) {
        v.onZoomIn = { state.zoomIn() }
        v.onZoomOut = { state.zoomOut() }
        v.onReset = { state.resetView() }
        v.onFit = { state.zoomToFit() }
        v.onZoomToSelection = { state.zoomToSelection() }
        v.onSetZoom = { state.setZoom($0) }
        v.configure(zoom: cameraStore.camera.zoom)
    }
}

// MARK: - Active tool chip (top-center)

final class ActiveToolChipView: NSView {
    var onClick: () -> Void = {}
    private let pill = CanvasPill()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "·  press V to select")
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let row = pill.content
        row.spacing = 7
        row.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        row.addArrangedSubview(hint)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(symbol: String, name: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        label.stringValue = "\(name) tool"
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}

struct NativeActiveToolChip: NSViewRepresentable {
    @EnvironmentObject var state: CanvasState
    func makeNSView(context: Context) -> ActiveToolChipView { ActiveToolChipView() }
    func updateNSView(_ v: ActiveToolChipView, context: Context) {
        v.onClick = { state.toolMode = .select }
        v.configure(symbol: state.toolMode.systemImage, name: state.toolMode.label)
    }
}

// MARK: - Brand tool palette (Figma 51:12692, bottom-center "candy bar")

/// Spatial-style green/yellow candy pill: a green capsule rim + a vertical
/// yellow gradient face + a bright top highlight + a soft 4-layer green drop
/// shadow. Shared by the tool bar and the detached "+" button. `content` (inset
/// 2pt) hosts the buttons.
final class BrandPill: NSView {
    let content = NSView()
    private let ring = CALayer()
    private let inner = CAGradientLayer()
    private struct Spec { let opacity: Float; let blur: CGFloat; let dy: CGFloat }
    private static let specs: [Spec] = [
        .init(opacity: 0.12, blur: 1.5, dy: 2), .init(opacity: 0.10, blur: 3, dy: 6),
        .init(opacity: 0.06, blur: 4, dy: 14), .init(opacity: 0.02, blur: 5, dy: 24)]
    private let shadows: [CALayer]
    static let green     = NSColor(srgbRed: 0.239, green: 0.655, blue: 0.149, alpha: 1)  // #3DA726
    static let yellowTop = NSColor(srgbRed: 1.0,   green: 0.961, blue: 0.231, alpha: 1)  // #FFF53B
    static let yellowBot = NSColor(srgbRed: 0.973, green: 0.871, blue: 0.278, alpha: 1)  // #F8DE47
    static let border    = NSColor(srgbRed: 1.0,   green: 0.988, blue: 0.663, alpha: 1)  // #FFFCA9
    static let shadowGreen = NSColor(srgbRed: 0.0, green: 0.361, blue: 0.008, alpha: 1)  // rgb(0,92,2)

    init() {
        shadows = Self.specs.map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        for (l, s) in zip(shadows, Self.specs) {
            l.backgroundColor = NSColor.clear.cgColor
            l.shadowColor = Self.shadowGreen.cgColor
            l.shadowOpacity = s.opacity
            l.isGeometryFlipped = true        // manual sublayers aren't auto-flipped → +dy = down
            layer?.addSublayer(l)
        }
        ring.backgroundColor = Self.green.cgColor
        layer?.addSublayer(ring)
        inner.colors = [Self.yellowTop.cgColor, Self.yellowBot.cgColor]
        inner.startPoint = CGPoint(x: 0.5, y: 0); inner.endPoint = CGPoint(x: 0.5, y: 1)
        inner.borderColor = Self.border.cgColor; inner.borderWidth = 2; inner.masksToBounds = true
        layer?.addSublayer(inner)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let r = bounds.height / 2
        let capsule = CGPath(roundedRect: CGRect(origin: .zero, size: bounds.size),
                             cornerWidth: r, cornerHeight: r, transform: nil)
        let k = bounds.height / 62
        for (l, s) in zip(shadows, Self.specs) {
            l.frame = bounds; l.shadowPath = capsule
            l.shadowRadius = s.blur * k; l.shadowOffset = CGSize(width: 0, height: s.dy * k)
        }
        ring.frame = bounds; ring.cornerRadius = r
        inner.frame = bounds.insetBy(dx: 2, dy: 2); inner.cornerRadius = inner.frame.height / 2
        CATransaction.commit()
    }
}

/// A 52×52 circular tool button on the yellow bar. Active = solid green chip +
/// white icon; inactive = dark icon at 70%, with a faint chip on hover.
final class ToolPaletteButton: NSView {
    var onClick: () -> Void = {}
    var isActive = false { didSet { refresh() } }
    private let chip = CALayer()
    private let icon = NSImageView()
    private var tracking: NSTrackingArea?

    init(symbol: String) {
        super.init(frame: .zero)
        wantsLayer = true
        chip.backgroundColor = BrandPill.green.cgColor
        chip.opacity = 0
        layer?.addSublayer(chip)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 19, weight: .medium))
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        chip.opacity = isActive ? 1 : 0
        icon.contentTintColor = isActive ? .white : NSColor.black.withAlphaComponent(0.70)
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let s = min(bounds.width, bounds.height)
        chip.frame = CGRect(x: bounds.midX - s / 2, y: bounds.midY - s / 2, width: s, height: s)
        chip.cornerRadius = s / 2
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with e: NSEvent) { if !isActive { chip.opacity = 0.18 } }
    override func mouseExited(with e: NSEvent) { if !isActive { chip.opacity = 0 } }
    override func mouseUp(with e: NSEvent) {
        if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick() }
    }
}

/// The bottom-center palette: a yellow bar of tool buttons + a detached green
/// "+" pill (Figma 51:12692). Tools map to `ToolMode`; the active one shows a
/// green chip.
final class CanvasToolPaletteView: NSView {
    var onPick: (ToolMode) -> Void = { _ in }
    var onAdd: () -> Void = {}
    private let bar = BrandPill()
    private let addPill = BrandPill()
    private var buttons: [(ToolMode, ToolPaletteButton)] = []
    private let tools: [ToolMode] = [.select, .text, .stickyNote, .draw, .connect]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        addPill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar); addSubview(addPill)

        let stack = NSStackView()
        stack.orientation = .horizontal; stack.distribution = .fillEqually; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for t in tools {
            let b = ToolPaletteButton(symbol: t.systemImage)
            b.onClick = { [weak self] in self?.onPick(t) }
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 52).isActive = true
            buttons.append((t, b))
            stack.addArrangedSubview(b)
        }
        bar.content.addSubview(stack)
        let add = ToolPaletteButton(symbol: "plus")
        add.onClick = { [weak self] in self?.onAdd() }
        add.translatesAutoresizingMaskIntoConstraints = false
        addPill.content.addSubview(add)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.content.bottomAnchor),
            add.leadingAnchor.constraint(equalTo: addPill.content.leadingAnchor),
            add.trailingAnchor.constraint(equalTo: addPill.content.trailingAnchor),
            add.topAnchor.constraint(equalTo: addPill.content.topAnchor),
            add.bottomAnchor.constraint(equalTo: addPill.content.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            addPill.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 10),
            addPill.trailingAnchor.constraint(equalTo: trailingAnchor),
            addPill.topAnchor.constraint(equalTo: topAnchor),
            addPill.bottomAnchor.constraint(equalTo: bottomAnchor),
            addPill.widthAnchor.constraint(equalToConstant: 62),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: tools.count * 52 + 4 + 10 + 62, height: 62) }
    func configure(active: ToolMode) { for (t, b) in buttons { b.isActive = (t == active) } }
}

struct NativeCanvasToolPalette: NSViewRepresentable {
    @EnvironmentObject var state: CanvasState
    func makeNSView(context: Context) -> CanvasToolPaletteView { CanvasToolPaletteView() }
    func updateNSView(_ v: CanvasToolPaletteView, context: Context) {
        v.onPick = { state.toolMode = $0 }
        v.onAdd = { state.isAddSheetPresented = true }
        v.configure(active: state.toolMode)
    }
}
