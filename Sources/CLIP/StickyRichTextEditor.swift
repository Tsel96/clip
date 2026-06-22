import SwiftUI
import AppKit

// MARK: - Node text accessors

extension CanvasNode {
    /// Plain text of a sticky / text node (search / archive fallback).
    var plainText: String {
        switch kind {
        case .stickyNote(let content, _): return content
        case .text(let content, _):       return content
        default:                          return ""
        }
    }

    /// The archived RTF rich text, decoded — `nil` when the node has no
    /// formatting yet (render the plain string with default attributes).
    var richText: NSAttributedString? {
        guard let data = attributedContent else { return nil }
        return try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil)
    }
}

// MARK: - StickyRichTextEditor

/// Native rich-text editor for a sticky note. An `NSTextView` (`isRichText`) that
/// edits in place inside the SwiftUI `StickyNodeView`. The bottom toolbar's
/// Bold / Italic / Underline / Strike buttons act on it as the window's first
/// responder (`StickyTextFormatting`), so formatting is native + persisted.
/// Commits the attributed string on end-editing (one undo entry per session).
struct StickyRichTextEditor: NSViewRepresentable {
    let node: CanvasNode
    let isEditing: Bool
    let textColor: NSColor
    let onCommit: (NSAttributedString) -> Void
    let onEndEditing: () -> Void

    /// SF Mono Medium 17, sticky text colour, ≈22pt line height (Figma 88-415).
    static func defaultAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        return [
            .font: NSFont.monospacedSystemFont(ofSize: 17, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: para,
            .kern: -0.17,
        ]
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.autohidesScrollers = true

        let tv = scroll.documentView as! NSTextView
        context.coordinator.textView = tv
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 22, height: 24)
        tv.textContainer?.lineFragmentPadding = 0
        tv.insertionPointColor = textColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.typingAttributes = Self.defaultAttributes(textColor)
        tv.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor,
        ]
        tv.isEditable = isEditing
        tv.isSelectable = isEditing
        context.coordinator.load(node: node, textColor: textColor)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        context.coordinator.parent = self
        tv.isEditable = isEditing
        tv.isSelectable = isEditing

        // Re-load from the model only when NOT editing and the plain text drifted
        // (undo / paste / external change) — never clobber a live edit session.
        if !isEditing, !context.coordinator.isCommitting, tv.string != node.plainText {
            context.coordinator.load(node: node, textColor: textColor)
        }

        if isEditing, tv.window?.firstResponder !== tv {
            DispatchQueue.main.async {
                guard tv.isEditable else { return }
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
        } else if !isEditing, tv.window?.firstResponder === tv {
            // Editing was ended programmatically (not by a canvas click) while the
            // text view still held focus → resign so the edit commits.
            tv.window?.makeFirstResponder(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: StickyRichTextEditor
        weak var textView: NSTextView?
        var isCommitting = false

        init(_ p: StickyRichTextEditor) { parent = p }

        func load(node: CanvasNode, textColor: NSColor) {
            guard let tv = textView else { return }
            let attr: NSAttributedString
            if let rich = node.richText, rich.length > 0 {
                attr = rich
            } else {
                attr = NSAttributedString(string: node.plainText,
                                          attributes: StickyRichTextEditor.defaultAttributes(textColor))
            }
            tv.textStorage?.setAttributedString(attr)
            tv.typingAttributes = StickyRichTextEditor.defaultAttributes(textColor)
        }

        func textDidEndEditing(_ notification: Notification) {
            commit()
            parent.onEndEditing()
        }

        /// Caret / selection moved → the enabled styles may differ; tell the bar to
        /// re-light its buttons.
        func textViewDidChangeSelection(_ notification: Notification) {
            StickyTextFormatting.notifyChanged()
        }

        /// Esc commits + ends editing (parity with the old editor's onExitCommand).
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                textView.window?.makeFirstResponder(nil)   // resigns → textDidEndEditing
                return true
            }
            return false
        }

        private func commit() {
            guard let tv = textView else { return }
            isCommitting = true
            parent.onCommit(tv.attributedString())
            isCommitting = false
        }
    }
}

// MARK: - StickyTextFormatting

/// Applies inline formatting to the active editor (the window's first-responder
/// `NSTextView`). Used by the bottom toolbar's text-format buttons — no responder
/// `toggleBold:` selectors (NSTextView doesn't implement them); we toggle the font
/// traits / underline / strike directly, then `didChangeText()` for undo.
enum StickyTextFormatting {
    static func activeTextView() -> NSTextView? {
        (NSApp.keyWindow?.firstResponder as? NSTextView)
            ?? (NSApp.mainWindow?.firstResponder as? NSTextView)
    }

    static var hasActiveEditor: Bool { activeTextView() != nil }

    /// Posted whenever the active editor's formatting MIGHT have changed (a toggle
    /// or a selection move) — the bottom bar listens and lights up the enabled
    /// buttons (green circle, like the toolbar's selected tool).
    static let didChange = Notification.Name("StickyTextFormattingDidChange")
    static func notifyChanged() { NotificationCenter.default.post(name: didChange, object: nil) }

    /// Which inline styles are currently ON for the selection (or the typing
    /// attributes when the selection is empty).
    struct State: Equatable { var bold = false, italic = false, underline = false, strike = false }
    static func currentState() -> State {
        guard let tv = activeTextView() else { return State() }
        let range = tv.selectedRange()
        let attrs: [NSAttributedString.Key: Any]
        if range.length == 0 {
            attrs = tv.typingAttributes
        } else if let storage = tv.textStorage, range.location < storage.length {
            attrs = storage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attrs = tv.typingAttributes
        }
        var s = State()
        if let f = attrs[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: f)
            s.bold = traits.contains(.boldFontMask)
            s.italic = traits.contains(.italicFontMask)
        }
        s.underline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
        s.strike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
        return s
    }

    static func toggleBold()   { toggleTrait(.boldFontMask) }
    static func toggleItalic() { toggleTrait(.italicFontMask) }

    private static func toggleTrait(_ trait: NSFontTraitMask) {
        guard let tv = activeTextView(), let storage = tv.textStorage else { return }
        let fm = NSFontManager.shared
        let range = tv.selectedRange()

        // Empty selection → flip the typing attribute for the next characters.
        if range.length == 0 {
            let cur = (tv.typingAttributes[.font] as? NSFont)
                ?? NSFont.monospacedSystemFont(ofSize: 17, weight: .medium)
            let on = fm.traits(of: cur).contains(trait)
            tv.typingAttributes[.font] = on
                ? fm.convert(cur, toNotHaveTrait: trait)
                : fm.convert(cur, toHaveTrait: trait)
            notifyChanged()
            return
        }

        // Decide the target state from the first character so a mixed run becomes
        // uniformly on/off (predictable, like Pages).
        let firstFont = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            ?? NSFont.monospacedSystemFont(ofSize: 17, weight: .medium)
        let turnOn = !fm.traits(of: firstFont).contains(trait)

        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, r, _ in
            let cur = (value as? NSFont) ?? firstFont
            let newFont = turnOn ? fm.convert(cur, toHaveTrait: trait)
                                 : fm.convert(cur, toNotHaveTrait: trait)
            storage.addAttribute(.font, value: newFont, range: r)
        }
        storage.endEditing()
        tv.didChangeText()
        notifyChanged()
    }

    static func toggleUnderline()     { toggleLine(.underlineStyle) }
    static func toggleStrikethrough() { toggleLine(.strikethroughStyle) }

    private static func toggleLine(_ key: NSAttributedString.Key) {
        guard let tv = activeTextView(), let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let single = NSUnderlineStyle.single.rawValue

        if range.length == 0 {
            let cur = (tv.typingAttributes[key] as? Int) ?? 0
            tv.typingAttributes[key] = cur == 0 ? single : 0
            notifyChanged()
            return
        }
        let curFirst = (storage.attribute(key, at: range.location, effectiveRange: nil) as? Int) ?? 0
        let newVal = curFirst == 0 ? single : 0
        storage.beginEditing()
        storage.addAttribute(key, value: newVal, range: range)
        storage.endEditing()
        tv.didChangeText()
        notifyChanged()
    }

    /// Eraser (Figma 104:593) — strip bold/italic/underline/strike back to the
    /// default sticky typing attributes for the selection (or typing attrs).
    static func clearFormatting() {
        guard let tv = activeTextView(), let storage = tv.textStorage else { return }
        let color = (tv.typingAttributes[.foregroundColor] as? NSColor) ?? .black
        let attrs = StickyRichTextEditor.defaultAttributes(color)
        let range = tv.selectedRange()
        if range.length == 0 { tv.typingAttributes = attrs; notifyChanged(); return }
        storage.beginEditing()
        storage.setAttributes(attrs, range: range)
        storage.endEditing()
        tv.didChangeText()
        notifyChanged()
    }
}
