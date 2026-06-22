import AppKit

/// Inline editor for a connector's midpoint label (Obsidian: double-click an edge
/// to type a label). Styled like the link-input (Figma 88-422 / 88-461): a green
/// pill wrapping a white rounded input with SF Mono text + an Enter glyph. Hosted
/// in SCREEN space (the scroll view's superview, which is NOT magnified) at the
/// midpoint's on-screen point, at a locked (screen-constant) size. Commit on
/// Return / click-outside / focus-loss; cancel on Escape.
extension CollectionCanvas.Coordinator: NSTextFieldDelegate {

    private static let fieldFontSize: CGFloat = 17       // SF Mono Semibold (Figma link input)
    private static let innerHeight: CGFloat   = 34       // white input pill height
    private static let pillPadding: CGFloat   = 4        // green border around the white pill
    private static let innerPadL: CGFloat      = 14
    private static let innerPadR: CGFloat      = 9
    private static let enterSize: CGFloat      = 18
    private static let enterGap: CGFloat       = 8
    private static let minInnerWidth: CGFloat  = 80
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
        pill.layer?.shadowColor = NSColor(srgbRed: 0, green: 0.36, blue: 0.008, alpha: 1).cgColor
        pill.layer?.shadowOpacity = 0.22
        pill.layer?.shadowRadius = 6
        pill.layer?.shadowOffset = CGSize(width: 0, height: 4)

        // White input pill.
        let inner = NSView()
        inner.wantsLayer = true
        inner.layer?.backgroundColor = NSColor.white.cgColor
        inner.layer?.cornerCurve = .continuous
        inner.layer?.masksToBounds = true
        pill.addSubview(inner)

        let field = NSTextField()
        field.stringValue = current.uppercased()
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
        enter.image = NSImage(systemSymbolName: "return.left", accessibilityDescription: "Enter")
        enter.symbolConfiguration = .init(pointSize: Self.enterSize * 0.85, weight: .semibold)
        enter.contentTintColor = NSColor(white: 0.55, alpha: 1)
        enter.imageScaling = .scaleProportionallyDown
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

        let f = NSFont.monospacedSystemFont(ofSize: Self.fieldFontSize, weight: .semibold)
        field.font = f
        field.currentEditor()?.font = f
        field.sizeToFit()
        let textW = max(8, field.frame.width)
        let fieldH = field.frame.height

        let pad = Self.pillPadding
        let innerH = Self.innerHeight
        let pillH = innerH + pad * 2
        let innerW = max(Self.minInnerWidth,
                         Self.innerPadL + textW + Self.enterGap + Self.enterSize + Self.innerPadR)
        let pillW = innerW + pad * 2

        pill.frame = CGRect(x: (center.x - pillW / 2).rounded(),
                            y: (center.y - pillH / 2).rounded(), width: pillW, height: pillH)
        pill.layer?.cornerRadius = pillH / 2
        pill.layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: pill.frame.size),
                                        cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil)

        inner.frame = CGRect(x: pad, y: pad, width: innerW, height: innerH)
        inner.layer?.cornerRadius = innerH / 2

        field.frame = CGRect(x: Self.innerPadL, y: (innerH - fieldH) / 2, width: textW, height: fieldH)
        enter.frame = CGRect(x: innerW - Self.innerPadR - Self.enterSize,
                             y: (innerH - Self.enterSize) / 2,
                             width: Self.enterSize, height: Self.enterSize)
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
        // Force uppercase display (Figma), preserving the caret position.
        if let field = editingConnectorField {
            let upper = field.stringValue.uppercased()
            if upper != field.stringValue {
                let sel = field.currentEditor()?.selectedRange
                field.stringValue = upper
                if let sel { field.currentEditor()?.selectedRange = sel }
            }
        }
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
