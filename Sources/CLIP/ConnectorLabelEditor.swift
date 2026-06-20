import AppKit

/// Inline editor for a connector's midpoint label (Obsidian: double-click an
/// edge to type a label). The field is added to the flipped content container at
/// the connector's midpoint (content space), so it sits on the line and pans /
/// zooms with the canvas. Commit on Return / focus-loss, cancel on Escape.
extension CollectionCanvas.Coordinator: NSTextFieldDelegate {

    func beginEditingConnectorLabel(_ cid: UUID) {
        guard let container = container,
              let mid = connectorController?.midpoints[cid] else { return }
        finishConnectorLabelEdit(commit: false)   // dismiss any in-flight editor

        let mag = max(scroll?.magnification ?? 1, 0.0001)
        let current = config.connectors.first(where: { $0.id == cid })?.label ?? ""

        let field = NSTextField()
        field.stringValue = current
        field.placeholderString = "Label"
        field.font = .systemFont(ofSize: 13 / mag, weight: .medium)
        field.alignment = .center
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.delegate = self

        let w = 160 / mag, h = 26 / mag
        field.frame = CGRect(x: mid.x - w / 2, y: mid.y - h / 2, width: w, height: h)
        container.addSubview(field)

        editingConnectorID = cid
        editingConnectorField = field
        container.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func finishConnectorLabelEdit(commit: Bool) {
        guard let field = editingConnectorField, let cid = editingConnectorID else { return }
        editingConnectorField = nil          // clear first so re-entrant delegate calls no-op
        editingConnectorID = nil
        if commit { config.onSetConnectorLabel(cid, field.stringValue) }
        field.removeFromSuperview()
        refreshConnectors()                  // redraw with (or without) the new label
    }

    // MARK: NSTextFieldDelegate

    public func controlTextDidEndEditing(_ obj: Notification) {
        // Fires on focus loss (clicking elsewhere) — commit what's there.
        finishConnectorLabelEdit(commit: true)
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
