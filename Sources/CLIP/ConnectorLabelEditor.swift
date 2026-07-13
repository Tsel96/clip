import AppKit

/// Inline editor for a connector's midpoint label (Obsidian: double-click an edge
/// to type a label). Styled like the link-input (Figma 88-422 / 88-461): a green
/// pill wrapping a white rounded input with SF Mono text + an Enter glyph. Hosted
/// in SCREEN space (the scroll view's superview, which is NOT magnified) at the
/// midpoint's on-screen point, at a locked (screen-constant) size. Commit on
/// Return / click-outside / focus-loss; cancel on Escape.
extension CollectionCanvas.Coordinator: NSTextFieldDelegate {

    private static let fieldFontSize: CGFloat = 18       // matches the rendered label (no size jump)
    private static let innerHeight: CGFloat   = 40       // white input pill (≈ the selected pill height)
    private static let pillPadding: CGFloat   = 4        // green border
    private static let innerPadL: CGFloat      = 16
    private static let innerPadR: CGFloat      = 12
    private static let enterSize: CGFloat      = 20
    private static let enterGap: CGFloat       = 9
    private static let minInnerWidth: CGFloat  = 84
    /// #3DA726 pill, #16181A text.
    private static let pillGreen = NSColor(srgbRed: 0.239, green: 0.655, blue: 0.149, alpha: 1)
    private static let labelTextColor = NSColor(srgbRed: 0.086, green: 0.094, blue: 0.102, alpha: 1)

    func beginEditingConnectorLabel(_ cid: UUID) {
        guard let container = container, let host = scroll?.superview,
              connectorController?.midpoints[cid] != nil else { return }
        finishConnectorLabelEdit(commit: false)   // dismiss any in-flight editor

        let current = config.connectors.first(where: { $0.id == cid })?.label ?? ""

        // Green pill (Figma 88-422) with a soft green drop shadow.
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = Self.pillGreen.cgColor
        pill.layer?.cornerCurve = .continuous
        pill.layer?.masksToBounds = false
        pill.layer?.shadowColor = NSColor(srgbRed: 0, green: 0.361, blue: 0.008, alpha: 1).cgColor
        pill.layer?.shadowOpacity = 0.20      // soft green pool (Figma 4-layer ≈ this)
        pill.layer?.shadowRadius = 8
        pill.layer?.shadowOffset = CGSize(width: 0, height: 8)

        // White input pill — subtle #EFEFEF→white gradient (Figma 88-423 embossed look).
        let inner = NSView()
        let grad = CAGradientLayer()
        grad.colors = [NSColor(srgbRed: 0.937, green: 0.937, blue: 0.937, alpha: 1).cgColor,
                       NSColor.white.cgColor]
        grad.locations = [0, 0.43]
        grad.startPoint = CGPoint(x: 0.5, y: 1)   // top
        grad.endPoint = CGPoint(x: 0.5, y: 0)     // bottom
        grad.cornerCurve = .continuous
        grad.masksToBounds = true
        inner.layer = grad
        inner.wantsLayer = true
        pill.addSubview(inner)

        let field = NSTextField()
        // RAW case — `current` is the model's `Connector.label`, which
        // `ConnectorOverlayController.layoutLabel` already renders uppercase
        // at-rest via a display-time `.uppercased()`. Seeding the editor with
        // an already-uppercased string (and, formerly, re-uppercasing it on
        // every keystroke below) meant committing without retyping baked the
        // uppercase DISPLAY string into the model.
        field.stringValue = current
        field.placeholderString = "LABEL"
        field.font = .monospacedSystemFont(ofSize: Self.fieldFontSize, weight: .semibold)
        field.alignment = .left
        field.isBezeled = false; field.isBordered = false
        field.drawsBackground = false
        field.textColor = Self.labelTextColor
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.delegate = self
        inner.addSubview(field)

        let enter = NSImageView()
        if let url = Bundle.module.url(forResource: "Enter", withExtension: "svg"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: Self.enterSize, height: Self.enterSize)
            enter.image = img                          // SAME Enter.svg as the link input (Figma 88-464)
        }
        enter.imageScaling = .scaleProportionallyUpOrDown
        inner.addSubview(enter)

        host.addSubview(pill)
        editingConnectorID = cid
        editingConnectorField = field
        editingConnectorPill = pill
        editingConnectorEnter = enter
        positionEditor(at: cid)

        container.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)

        // Click anywhere outside the pill commits + dismisses it.
        editingConnectorMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let p = self.editingConnectorPill else { return event }
            let pt = p.convert(event.locationInWindow, from: nil)
            if !p.bounds.contains(pt) { self.finishConnectorLabelEdit(commit: true) }
            return event
        }
    }

    /// Re-size the pill to its text and re-center it on the (live) midpoint. Locked
    /// (screen-constant) size — called on open, on every keystroke, and on every
    /// zoom/pan via `refreshChrome`, so it stays pinned to the line.
    func positionEditor(at cid: UUID) {
        guard let field = editingConnectorField, let pill = editingConnectorPill,
              let enter = editingConnectorEnter, let inner = pill.subviews.first,
              let container = container, let host = scroll?.superview,
              let mid = connectorController?.midpoints[cid] else { return }
        let center = container.convert(mid, to: host)
        // DAMPENED zoom (√mag) — matches the rendered label, so the editor scales
        // gently with zoom instead of staying a fixed (too-big-when-zoomed-out) size.
        let s = sqrt(max(scroll?.magnification ?? 1, 0.0001))

        let f = NSFont.monospacedSystemFont(ofSize: Self.fieldFontSize * s, weight: .semibold)
        field.font = f
        field.currentEditor()?.font = f
        field.sizeToFit()
        let textW = max(8, field.frame.width)
        let fieldH = field.frame.height

        let pad = Self.pillPadding * s
        let innerH = Self.innerHeight * s
        let enterSz = Self.enterSize * s
        let pillH = innerH + pad * 2
        let innerW = max(Self.minInnerWidth * s,
                         Self.innerPadL * s + textW + Self.enterGap * s + enterSz + Self.innerPadR * s)
        let pillW = innerW + pad * 2

        pill.frame = CGRect(x: (center.x - pillW / 2).rounded(),
                            y: (center.y - pillH / 2).rounded(), width: pillW, height: pillH)
        pill.layer?.cornerRadius = pillH / 2
        pill.layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: pill.frame.size),
                                        cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil)

        inner.frame = CGRect(x: pad, y: pad, width: innerW, height: innerH)
        inner.layer?.cornerRadius = innerH / 2

        field.frame = CGRect(x: Self.innerPadL * s, y: (innerH - fieldH) / 2, width: textW, height: fieldH)
        enter.frame = CGRect(x: innerW - Self.innerPadR * s - enterSz,
                             y: (innerH - enterSz) / 2, width: enterSz, height: enterSz)
        // Enter icon fully opaque only once there's text (Figma — faded placeholder state).
        enter.alphaValue = field.stringValue.isEmpty ? 0.4 : 1.0
    }

    func finishConnectorLabelEdit(commit: Bool) {
        if let m = editingConnectorMonitor { NSEvent.removeMonitor(m); editingConnectorMonitor = nil }
        guard let field = editingConnectorField, let cid = editingConnectorID else { return }
        editingConnectorField = nil          // clear first so re-entrant delegate calls no-op
        editingConnectorID = nil
        if commit { config.onSetConnectorLabel(cid, field.stringValue) }
        editingConnectorPill?.removeFromSuperview()
        editingConnectorPill = nil
        editingConnectorEnter = nil
        refreshConnectors()                  // redraw with (or without) the new label
    }

    // MARK: NSTextFieldDelegate

    public func controlTextDidChange(_ obj: Notification) {
        // The field keeps the RAW-case text the user types — forcing it
        // uppercase here (as this used to) mutates the value that gets
        // committed, not just its on-screen appearance. The display-only
        // uppercase transform already happens at render time in
        // `ConnectorOverlayController.layoutLabel` (`text.uppercased()`),
        // matching how `c.label` is stored raw everywhere else.
        if let cid = editingConnectorID { positionEditor(at: cid) }
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        finishConnectorLabelEdit(commit: true)   // focus-loss backup
    }

    public func control(_ control: NSControl, textView: NSTextView,
                        doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            finishConnectorLabelEdit(commit: true);  return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishConnectorLabelEdit(commit: false); return true
        default:
            return false
        }
    }
}
