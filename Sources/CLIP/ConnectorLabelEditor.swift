import AppKit

/// Inline editor for a connector's midpoint label (Obsidian: double-click an
/// edge to type a label). Hosted in SCREEN space (the scroll view's superview,
/// which is NOT magnified) at the connector midpoint's on-screen point, with its
/// font sized to match the rendered label at the current zoom. This avoids the
/// magnified-canvas pitfalls of an NSTextField (its field editor renders at
/// screen resolution and the connector layer draws over it). Borderless, plain
/// text. Commit on Return / click-outside / focus-loss; cancel on Escape.
extension CollectionCanvas.Coordinator: NSTextFieldDelegate {

    /// SCREEN-constant label size (must match `ConnectorOverlayController.labelFontSize`)
    /// — the editor is locked to the same on-screen size at any zoom.
    private static let labelScreenFontSize: CGFloat = 22
    private static let labelTextColor = NSColor(srgbRed: 0.086, green: 0.094, blue: 0.102, alpha: 1)  // #16181A
    private static let labelBGColor = NSColor(srgbRed: 0.929, green: 0.941, blue: 0.945, alpha: 1)    // #EDF0F1

    func beginEditingConnectorLabel(_ cid: UUID) {
        guard let container = container,
              let host = scroll?.superview,
              connectorController?.midpoints[cid] != nil else { return }
        finishConnectorLabelEdit(commit: false)   // dismiss any in-flight editor

        let current = config.connectors.first(where: { $0.id == cid })?.label ?? ""

        let field = NSTextField()
        field.stringValue = current.uppercased()
        field.placeholderString = "LABEL"
        // Screen-constant font → matches the (locked-size) rendered label.
        field.font = .monospacedSystemFont(ofSize: Self.labelScreenFontSize, weight: .semibold)
        field.alignment = .center
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = Self.labelBGColor      // canvas colour → masks the line
        field.textColor = Self.labelTextColor
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.delegate = self
        field.wantsLayer = true
        field.layer?.cornerRadius = 4

        host.addSubview(field)                          // above the (magnified) scroll
        editingConnectorID = cid
        editingConnectorField = field
        positionEditor(at: cid)                         // size to text + center on the midpoint

        container.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)

        // Click anywhere outside the field commits + dismisses it.
        editingConnectorMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let f = self.editingConnectorField else { return event }
            let p = f.convert(event.locationInWindow, from: nil)
            if !f.bounds.contains(p) { self.finishConnectorLabelEdit(commit: true) }
            return event
        }
    }

    /// Re-size the field to its text and re-center it on the (live) midpoint, and
    /// re-derive the font from the current zoom — so the editor SCALES WITH the
    /// canvas (called on open, on every keystroke, and on every zoom/pan via
    /// `refreshChrome`). Keeps it pinned to the line and matching the label size.
    func positionEditor(at cid: UUID) {
        guard let field = editingConnectorField,
              let container = container, let host = scroll?.superview,
              let mid = connectorController?.midpoints[cid] else { return }
        let f = NSFont.monospacedSystemFont(ofSize: Self.labelScreenFontSize, weight: .semibold)
        field.font = f
        field.currentEditor()?.font = f          // the ACTIVE field editor needs it too, or the live text won't resize
        let center = container.convert(mid, to: host)
        field.sizeToFit()
        let w = max(40, field.frame.width + 14)   // screen-constant (locked) — no × mag
        let h = field.frame.height + 4
        field.frame = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }

    func finishConnectorLabelEdit(commit: Bool) {
        if let m = editingConnectorMonitor { NSEvent.removeMonitor(m); editingConnectorMonitor = nil }
        guard let field = editingConnectorField, let cid = editingConnectorID else { return }
        editingConnectorField = nil          // clear first so re-entrant delegate calls no-op
        editingConnectorID = nil
        if commit { config.onSetConnectorLabel(cid, field.stringValue) }
        field.removeFromSuperview()
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
