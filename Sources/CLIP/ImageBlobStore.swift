import Foundation
import CryptoKit

/// On-disk home for image bytes, so `canvas.json` stays small.
///
/// Images used to be embedded in `canvas.json` as base64, which meant every
/// autosave re-encoded and rewrote every image on the board (hundreds of MB
/// for a big board). Now each image is written once to
/// `~/Library/Application Support/CLIP/images/<sha256>` and the JSON stores
/// only that hash (`dataRef`). Content addressing makes writes idempotent and
/// dedupes identical images.
///
/// Only `CanvasStore` opts in (via `JSONEncoder.userInfo`); every other
/// encoder of `CanvasNode` — the copy/paste payload, tests — still embeds the
/// bytes inline, and the decoder accepts both forms, so older `canvas.json`
/// files keep loading.
enum ImageBlobStore {
    static let userInfoKey = CodingUserInfoKey(rawValue: "clip.imageBlobWriter")!

    static var directory: URL {
        CanvasStore.fileURL.deletingLastPathComponent()
            .appendingPathComponent("images", isDirectory: true)
    }

    enum BlobError: Error { case badReference(String) }

    /// Read an image by reference. Memory-mapped where possible, so loading a
    /// big board doesn't copy every image into RAM up front.
    static func load(ref: String) throws -> Data {
        guard isValidRef(ref) else { throw BlobError.badReference(ref) }
        return try Data(contentsOf: directory.appendingPathComponent(ref), options: .mappedIfSafe)
    }

    /// A ref is a lowercase SHA-256 hex digest — never a path, so a tampered
    /// `canvas.json` can't point the loader at arbitrary files.
    static func isValidRef(_ ref: String) -> Bool {
        ref.count == 64 && ref.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

/// Collects image bytes during one save. Used only on `CanvasStore`'s serial
/// save queue.
final class ImageBlobWriter {
    private(set) var referenced: Set<String> = []
    private let fm = FileManager.default

    init() throws {
        try fm.createDirectory(at: ImageBlobStore.directory, withIntermediateDirectories: true)
    }

    /// Persist `data` (if not already on disk) and return its reference.
    func store(_ data: Data) throws -> String {
        let ref = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = ImageBlobStore.directory.appendingPathComponent(ref)
        if !fm.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        referenced.insert(ref)
        return ref
    }

    /// Delete blobs no longer referenced by the snapshot just written. Call
    /// only AFTER `canvas.json` was written successfully, so the file on disk
    /// never points at a deleted blob. (Undo history / a deleted-page backup
    /// may still hold those bytes in memory; if they come back, the next save
    /// simply writes the blob again.)
    func removeUnreferenced() {
        guard let names = try? fm.contentsOfDirectory(atPath: ImageBlobStore.directory.path) else { return }
        let keep = referenced.union(refsInBackups())
        for name in names where ImageBlobStore.isValidRef(name) && !keep.contains(name) {
            try? fm.removeItem(at: ImageBlobStore.directory.appendingPathComponent(name))
        }
    }

    /// Blobs referenced by `canvas.json.corrupt-…` / `.partial-…` backups stay
    /// alive, so a backup kept for recovery never loses its images. (Backups
    /// from before the blob store embed their images and reference none;
    /// they're skipped by size so a huge legacy file isn't re-read per save.)
    private func refsInBackups() -> Set<String> {
        let dir = CanvasStore.fileURL.deletingLastPathComponent()
        let prefix = CanvasStore.fileURL.lastPathComponent + "."
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var refs = Set<String>()
        for name in names where name.hasPrefix(prefix) {
            let url = dir.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size < 50 * 1024 * 1024,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for match in text.matches(of: Self.refPattern) {
                refs.insert(String(match.1))
            }
        }
        return refs
    }

    // `#/…/#` form: bare `/…/` regex literals need a compiler flag in Swift 5 mode.
    private static let refPattern = #/"dataRef"\s*:\s*"([0-9a-f]{64})"/#
}
