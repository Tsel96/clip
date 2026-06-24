import SwiftUI
import AppKit

/// Canvas text restyled as a white **pill** (Figma 96-720): IBM Plex Sans
/// SemiBold green text on a fully-rounded white card. Uses the SAME native
/// rich-text editor as stickies (`StickyRichTextEditor`) so bold/italic/
/// underline/strike/eraser + the format bar work identically; the node is sized
/// to the glyphs + pill padding (`CanvasState.textPillSize`), kept live via the
/// editor's `onTextChange`.
struct TextNodeView: View {
    @EnvironmentObject var state: CanvasState
    let nodeID: UUID
    let content: String
    let fontSize: CGFloat
    let isSelected: Bool

    /// #3DA726
    private let green  = Color(.sRGB, red: 0.239, green: 0.655, blue: 0.149, opacity: 1)
    /// #F0EC00
    private let yellow = Color(.sRGB, red: 0.943, green: 0.926, blue: 0.0,   opacity: 1)
    private static let greenNS = NSColor(srgbRed: 0.239, green: 0.655, blue: 0.149, alpha: 1)

    private var liveNode: CanvasNode {
        state.nodes.first { $0.id == nodeID }
            ?? CanvasNode(position: .zero, width: 1, kind: .text(content: content, fontSize: fontSize))
    }
    private var isEditing: Bool { state.editingTextNodeID == nodeID }
    private var nsFont: NSFont {
        NSFont(name: "IBMPlexSans-SemiBold", size: fontSize)
            ?? .systemFont(ofSize: fontSize, weight: .semibold)
    }

    var body: some View {
        // The green band + yellow border are the node's permanent border (all
        // states, Figma 96-720). The white pill is inset inside them.
        let bd = CanvasState.textPillBorder(fontSize)
        let inset = bd.band + bd.yellow
        ZStack {
            Capsule(style: .continuous).fill(green)                       // green band
            Capsule(style: .continuous)
                .fill(Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1))
                .padding(inset)                                            // white pill
            StickyRichTextEditor(
                node: liveNode,
                isEditing: isEditing,
                textColor: Self.greenNS,
                font: nsFont,
                alignment: .center,
                kern: 0,
                inset: NSSize(width: 4, height: 2),
                // White pill painted as the editor's own opaque backing subview, so
                // it stays white while editing (the embedded editor otherwise shows a
                // grey window-hole). Capsule (pillCornerRadius < 0 ⇒ height/2).
                pillFill: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                verticalCenter: true,
                onTextChange: { state.liveResizeText(id: nodeID, content: $0) },
                onCommit: { attr in
                    let plain = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if plain.isEmpty { state.delete(id: nodeID) }
                    else { state.setStickyAttributed(id: nodeID, attr) }
                },
                onEndEditing: {
                    if state.editingTextNodeID == nodeID { state.editingTextNodeID = nil }
                    if state.pendingFocusNodeID == nodeID { state.pendingFocusNodeID = nil }
                    state.selectedNodeIDs.remove(nodeID)
                })
                .padding(inset)
                .allowsHitTesting(isEditing)
                // Empty placeholder (only at rest — text nodes are created focused).
                .overlay {
                    if content.isEmpty && !isEditing {
                        Text("Text")
                            .font(.custom("IBMPlexSans-SemiBold", size: fontSize))
                            .foregroundStyle(green.opacity(0.4))
                            .allowsHitTesting(false)
                    }
                }

            Capsule(style: .continuous).strokeBorder(yellow, lineWidth: bd.yellow)  // yellow edge
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Double-click sets pendingFocusNodeID (DraggableNode) → enter edit mode.
        .onChange(of: state.pendingFocusNodeID) { newID in
            if newID == nodeID && !isEditing {
                state.editingTextNodeID = nodeID
                DispatchQueue.main.async { state.pendingFocusNodeID = nil }
            }
        }
    }
}
