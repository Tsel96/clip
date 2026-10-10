import Foundation
import AppKit
import SwiftUI

// Lightbox inspector: source URL, page, tags, prompt — split out of CanvasState.swift (behaviour unchanged).
@MainActor
extension CanvasState {
    // MARK: - Lightbox inspector: source URL, page, tags, prompt

    /// Effective source link for a node — the embedded post URL, or the
    /// manually-entered `linkURL`.
    func sourceURL(of node: CanvasNode) -> String? {
        switch node.kind {
        case .tweet(let u), .instagram(let u), .youtube(let u): return u
        default: return node.linkURL
        }
    }

    /// Name of the page that contains this card (cards live on one page).
    func pageName(forCard id: UUID) -> String? {
        pages.first(where: { $0.nodes.contains(where: { $0.id == id }) })?.name
    }

    func setNodeImagePrompt(_ id: UUID, _ value: String) {
        updateNode(id) { $0.imagePrompt = value.isEmpty ? nil : value }
    }

    func addTag(_ id: UUID, _ raw: String) {
        let t = Self.normalizeTag(raw)
        guard !t.isEmpty else { return }
        updateNode(id) { if !$0.tags.contains(t) { $0.tags.append(t) } }
    }

    func removeTag(_ id: UUID, _ tag: String) {
        updateNode(id) { $0.tags.removeAll { $0 == tag } }
    }

    /// Heuristic auto-tagger (no AI): derives tags from kind, source
    /// domain, dominant color, and aspect; dedup-merges into `node.tags`.
    func autoTag(_ id: UUID) {
        guard let node = nodeByID[id] else { return }
        var derived: [String] = []
        switch node.kind {
        case .image:      derived.append("image")
        case .video:      derived.append("video")
        case .tweet:      derived += ["tweet", "x"]
        case .instagram:  derived.append("instagram")
        case .youtube:    derived += ["youtube", "video"]
        case .webclip:    derived += ["web", "link"]
        case .text:       derived.append("text")
        case .stickyNote: derived.append("note")
        case .drawing:    derived.append("drawing")
        case .section:    break
        case .folder:     derived.append("folder")
        }
        if let host = sourceURL(of: node).flatMap({ URL(string: $0)?.host })?
            .replacingOccurrences(of: "www.", with: ""),
           !["x.com", "twitter.com", "youtube.com", "youtu.be", "instagram.com"].contains(host) {
            derived.append(String(host.split(separator: ".").first ?? Substring(host)))
        }
        if case .image = node.kind,
           let c = PaletteExtractor.colors(for: node, count: 4).first {
            derived.append(PaletteExtractor.colorName(c))
        }
        let h = renderedHeight(of: node)
        if node.width > 1, h > 1 {
            let r = node.width / h
            derived.append(r > 1.2 ? "landscape" : (r < 0.83 ? "portrait" : "square"))
        }
        updateNode(id) { n in
            for t in derived.map(Self.normalizeTag) where !t.isEmpty && !n.tags.contains(t) {
                n.tags.append(t)
            }
        }
    }

    private static func normalizeTag(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Heuristic image-prompt synthesis (no AI) from kind + colors +
    /// orientation + source/name/text.
    func generatePrompt(for node: CanvasNode) -> String {
        let aspect: String = {
            let h = renderedHeight(of: node)
            guard node.width > 1, h > 1 else { return "square" }
            let r = node.width / h
            return r > 1.2 ? "landscape" : (r < 0.83 ? "portrait" : "square")
        }()
        switch node.kind {
        case .image:
            let names = uniqueOrdered(PaletteExtractor.colors(for: node, count: 4)
                                        .map(PaletteExtractor.colorName))
            let palette = names.isEmpty ? "" : " in \(listPhrase(names)) tones"
            let subject = (node.name?.isEmpty == false) ? node.name! : "an abstract composition"
            return "A \(aspect) image of \(subject)\(palette), high detail, soft natural light."
        case .tweet(let u):
            let handle = URL(string: u)?.path.split(separator: "/").first
                .map { "@\($0)" } ?? "a user"
            return "Screenshot of an X post by \(handle), clean UI, crisp legible typography."
        case .instagram:
            return "An Instagram post, square crop, vibrant social-media aesthetic."
        case .youtube:
            return "A YouTube thumbnail, bold focal subject, high contrast, punchy color."
        case .webclip:
            return "A web page screenshot, clean readable layout, informative content."
        case .video:
            return "A \(aspect) video still, cinematic lighting, gentle natural motion."
        case .text(let content, _):
            return "Editorial typographic layout featuring: \u{201C}\(content.prefix(60))\u{201D}."
        case .stickyNote(let content, _):
            return "A handwritten sticky note reading: \u{201C}\(content.prefix(60))\u{201D}."
        case .drawing:
            return "A loose freehand ink sketch, minimal expressive line art."
        case .section:
            return "A labeled grouping frame."
        case .folder:
            return "A folder holding a set of saved items."
        }
    }

    private func uniqueOrdered(_ arr: [String]) -> [String] {
        var seen = Set<String>(); return arr.filter { seen.insert($0).inserted }
    }
    private func listPhrase(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}
