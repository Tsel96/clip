import Foundation

// TEMPORARY scroll-path diagnostics — appends to /tmp/clip_diag.txt.
// Added 2026-07-13 to trace "two-finger scroll doesn't pan"; DELETE after.
enum Diag {
    private static let url = URL(fileURLWithPath: "/tmp/clip_diag.txt")
    private static let q = DispatchQueue(label: "clip.diag")
    static func log(_ s: String) {
        q.async {
            let line = "\(Date().timeIntervalSince1970) \(s)\n"
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
