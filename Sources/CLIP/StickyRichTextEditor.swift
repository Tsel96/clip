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
    /// Base typing font (defaults to the sticky's SF Mono Medium 17).
    var font: NSFont = NSFont.monospacedSystemFont(ofSize: 17, weight: .medium)
    var alignment: NSTextAlignment = .left
    var kern: CGFloat = -0.17
    var inset: NSSize = NSSize(width: 22, height: 24)
    /// When set, the editor paints an OPAQUE rounded fill of this colour on its OWN
    /// layer (AppKit/Core Animation). This is the card's pill/sticky background.
    /// It must be painted here — NOT as a SwiftUI sibling shape behind the editor —
    /// because SwiftUI composites content placed directly behind an embedded
    /// `NSViewRepresentable` at reduced opacity, so the gray canvas bled through and
    /// the pill "greyed while editing". An AppKit layer fill can't be under-opacitied.
    var pillFill: NSColor? = nil
    /// Corner radius for `pillFill`. Negative ⇒ capsule (recomputed to height/2 on layout).
    var pillCornerRadius: CGFloat = -1
    /// Vertically centre the text in the view (text nodes — single-line pills).
    /// Off for stickies (top-aligned, multi-line, scrollable).
    var verticalCenter: Bool = false
    /// Fired on every text change (used by text nodes to live-resize the pill).
    var onTextChange: ((String) -> Void)? = nil
    let onCommit: (NSAttributedString) -> Void
    let onEndEditing: () -> Void

    /// The base (unformatted) attributes for THIS editor.
    func attributes() -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        para.alignment = alignment
        return [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: para,
            .kern: kern,
        ]
    }

    /// Fallback base attributes (sticky SF Mono) for the eraser when the active
    /// text view didn't record its own.
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
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        // CRITICAL: `NSScrollView.drawsBackground = false` does NOT stop the
        // `NSClipView` (contentView) from painting its own background — a gray
        // system color in aqua — and in a layer-backed host (NSHostingView) the
        // backing LAYERS also carry that gray independent of `drawsBackground`.
        // That's what greyed the whole text/sticky card fill while editing. Clear
        // every layer: AppKit color + CALayer color, on scroll, clip view, and tv.
        scroll.contentView.drawsBackground = false
        scroll.contentView.backgroundColor = .clear
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.autohidesScrollers = true

        // Opaque card fill as a REAL subview behind the text (NOT a background
        // colour — that doesn't render in the embedded editor, which composites as a
        // window-hole while first responder; an opaque view does). cornerRadius +
        // masksToBounds shape it to the pill/sticky; updated in updateNSView.
        if let pillFill {
            let backing = NSView()
            backing.wantsLayer = true
            backing.layer?.backgroundColor = pillFill.cgColor
            backing.layer?.cornerCurve = .continuous
            backing.layer?.masksToBounds = true
            backing.frame = scroll.bounds
            backing.autoresizingMask = [.width, .height]
            scroll.addSubview(backing, positioned: .below, relativeTo: scroll.contentView)
            context.coordinator.pillBacking = backing
        }

        // Explicit text stack so we can use a logging/selectable subclass and
        // guarantee the text view fills its width (clicks anywhere select text).
        let container = NSTextContainer(containerSize:
            NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        let tv = StickyTextView(frame: .zero, textContainer: container)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = false
        tv.verticallyCentered = verticalCenter
        if verticalCenter {
            // Fill the clip view (so there's height to centre WITHIN).
            tv.isVerticallyResizable = false
            tv.autoresizingMask = [.width, .height]
        } else {
            tv.isVerticallyResizable = true
            tv.autoresizingMask = [.width]
        }
        scroll.documentView = tv

        // LAYER-BACK the whole editor stack. A non-layer-backed NSTextView embedded
        // in SwiftUI (NSHostingView) composites as a WINDOW-LEVEL hole while it's
        // first responder — it reveals the grey canvas behind everything instead of
        // the white pill drawn right behind it. (Regression: the milestone used
        // `NSTextView.scrollableTextView()`, which is layer-backed; this manual stack
        // wasn't.) Layer-backed + clear = transparent but composited IN-layer, so the
        // pill behind shows through — no hole, no grey.
        scroll.wantsLayer = true
        scroll.contentView.wantsLayer = true
        tv.wantsLayer = true

        context.coordinator.textView = tv
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = inset
        tv.textContainer?.lineFragmentPadding = 0
        tv.insertionPointColor = textColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.alignment = alignment
        tv.typingAttributes = attributes()
        tv.baseAttributes = attributes()        // for the eraser (clear formatting)
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
        // Keep the whole editor stack transparent. In a layer-backed host the
        // scroll/clip/text BACKING LAYERS can carry a gray system background that
        // `drawsBackground = false` doesn't clear — that greyed the pill while
        // editing. Re-assert it here (layers exist once mounted), both the AppKit
        // colour and the CALayer colour.
        scroll.drawsBackground = false; scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false; scroll.contentView.backgroundColor = .clear
        scroll.layer?.backgroundColor = NSColor.clear.cgColor
        scroll.contentView.layer?.backgroundColor = NSColor.clear.cgColor
        tv.drawsBackground = false; tv.backgroundColor = .clear
        tv.layer?.backgroundColor = NSColor.clear.cgColor
        // Opaque pill/sticky fill (real subview, see makeNSView) — keep its colour +
        // capsule radius in sync with the (auto-sizing) editor bounds.
        if let pillFill, let backing = context.coordinator.pillBacking {
            backing.layer?.backgroundColor = pillFill.cgColor
            backing.layer?.cornerRadius = pillCornerRadius < 0 ? backing.bounds.height / 2 : pillCornerRadius
        }
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
        } else if !isEditing {
            if tv.window?.firstResponder === tv {
                // Ended programmatically while still focused → resign so it commits.
                tv.window?.makeFirstResponder(nil)
            } else if tv.selectedRange().length > 0 {
                tv.setSelectedRange(NSRange(location: 0, length: 0))   // clear lingering highlight
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: StickyRichTextEditor
        weak var textView: NSTextView?
        var isCommitting = false
        /// Opaque pill/sticky fill, painted as a real subview behind the text — a
        /// background COLOR doesn't render in the embedded editor (it composites as a
        /// window-hole while first responder), but an opaque view does.
        weak var pillBacking: NSView?

        init(_ p: StickyRichTextEditor) { parent = p }

        func load(node: CanvasNode, textColor: NSColor) {
            guard let tv = textView else { return }
            let base = parent.attributes()
            let attr: NSAttributedString
            if let rich = node.richText, rich.length > 0 {
                attr = rich
            } else {
                attr = NSAttributedString(string: node.plainText, attributes: base)
            }
            tv.textStorage?.setAttributedString(attr)
            tv.typingAttributes = base
            (tv as? StickyTextView)?.baseAttributes = base
        }

        func textDidChange(_ notification: Notification) {
            if let s = textView?.string { parent.onTextChange?(s) }
        }

        func textDidEndEditing(_ notification: Notification) {
            commit()
            // Drop the selection so its (desaturated) highlight doesn't linger on
            // the deselected sticky.
            textView?.setSelectedRange(NSRange(location: 0, length: 0))
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
/// Sticky / text-node editor text view. Accepts first-mouse so a click selects
/// even when the window just became key, and records its base (unformatted)
/// attributes so the eraser can restore the correct font/colour/alignment.
final class StickyTextView: NSTextView {
    var baseAttributes: [NSAttributedString.Key: Any] = [:]
    var verticallyCentered = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        guard verticallyCentered, let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let top = max(0, (bounds.height - used) / 2)
        if abs(textContainerInset.height - top) > 0.5 {
            textContainerInset = NSSize(width: textContainerInset.width, height: top)
        }
    }
}

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
        // Restore the editor's own base attributes (right font/colour/alignment).
        let attrs = (tv as? StickyTextView)?.baseAttributes.isEmpty == false
            ? (tv as! StickyTextView).baseAttributes
            : StickyRichTextEditor.defaultAttributes(color)
        let range = tv.selectedRange()
        if range.length == 0 { tv.typingAttributes = attrs; notifyChanged(); return }
        storage.beginEditing()
        storage.setAttributes(attrs, range: range)
        storage.endEditing()
        tv.didChangeText()
        notifyChanged()
    }
}
