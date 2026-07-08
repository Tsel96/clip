import Foundation
import CryptoKit

/// R10 — content-addressed media storage at
/// `~/Library/Application Support/CLIP/media/<sha256>.<ext>`.
/// canvas.json stores file references instead of base64 blobs (which made
/// every save re-encode the whole board and launch parse megabytes of JSON),
/// and imported videos are COPIED here so a card can't silently break when
/// the user moves/deletes the original file.
/// ponytail: no garbage collection — deleting a card orphans its file; add a
/// sweep keyed on referenced names if the folder ever matters.
enum MediaStore {

    static var dir: URL {
        (FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("CLIP/media", isDirectory: true)
    }

    static func url(for name: String) -> URL { dir.appendingPathComponent(name) }

    static func read(_ name: String) -> Data? { try? Data(contentsOf: url(for: name)) }

    /// Write `data` as `<sha256>.<ext>` (skipped when already present —
    /// content-addressing makes repeat saves free). Returns the FILE NAME.
    static func store(_ data: Data, ext: String) throws -> String {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = ext.isEmpty ? hash : "\(hash).\(ext.lowercased())"
        let dst = url(for: name)
        if !FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dst, options: .atomic)
        }
        return name
    }

    /// Copy an external file into the store under its content hash (hash is
    /// STREAMED — videos can be 100 MB). Returns the stored URL, or the
    /// original on any failure so an import never dies on a storage hiccup.
    static func importFile(_ src: URL) -> URL {
        guard let stream = InputStream(url: src) else { return src }
        var hasher = SHA256()
        stream.open(); defer { stream.close() }
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n < 0 { return src }
            if n == 0 { break }
            buf.withUnsafeBytes {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: $0.baseAddress, count: n))
            }
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let ext = src.pathExtension.lowercased()
        let dst = url(for: ext.isEmpty ? hash : "\(hash).\(ext)")
        if !FileManager.default.fileExists(atPath: dst.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: src, to: dst)
            } catch {
                // A concurrent import of the same content may have won the
                // copy — content-addressing makes its file just as good.
                return FileManager.default.fileExists(atPath: dst.path) ? dst : src
            }
        }
        return dst
    }
}
