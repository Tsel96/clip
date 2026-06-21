import AppKit

/// Inline editor for a connector's midpoint label (Obsidian: double-click an
/// edge to type a label). Hosted in SCREEN space (the scroll view's superview,
/// which is NOT magnified) at the connector midpoint's on-screen point, with its
/// font sized to match the rendered label at the current zoom. This avoids the
/// magnified-canvas pitfalls of an NSTextField (its field editor renders at
/// screen resolution and the connector layer draws over it). Borderless, plain
/// text. Commit on Return / click-outside / focus-loss; cancel on Escape.
extension CollectionCanvas.Coordinator: NSTextFieldDelegate {

    /// Label font size in CONTENT units (must match `ConnectorOverlayController`).
    private static let labelContentFontSize: CGFloat = 17   // Figma: SF Mono Semibold 17
    private static let labelTextColor = NSColor.black
    private static let labelBGColor = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)

    func beginEditingConnectorLabel(_ cid: UUID) {
        guard let container = container,
              let host = scroll?.superview,
              let mid = connectorController?.midpoints[cid] else { return }
        finishConnectorLabelEdit(commit: false)   // dismiss any in-flight editor

        let mag = max(scroll?.magnification ?? 1, 0.0001)
        let current = config.connectors.first(where: { $0.id == cid })?.label ?? ""

        let field = NSTextField()
        field.stringValue = current
        field.placeholderString = "Label"
        // On-screen font = content size × zoom → matches the rendered label.
        field.font = .monospacedSystemFont(ofSize: Self.labelContentFontSize * mag, weight: .semibold)
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
        let mag = max(scroll?.magnification ?? 1, 0.0001)
        field.font = .monospacedSystemFont(ofSize: Self.labelContentFontSize * mag, weight: .semibold)
        let center = container.convert(mid, to: host)
        field.sizeToFit()
        let w = max(40 * mag, field.frame.width + 14 * mag)
        let h = field.frame.height + 4 * mag
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
