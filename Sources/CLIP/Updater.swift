import Foundation
import AppKit
import CryptoKit
import os

/// Silent self-updater for CLIP. Ships in every build and runs for *all*
/// installs — the unattended exhibition Mac mini and anyone who downloads the
/// app. No Sparkle, no Developer ID: the app polls a public JSON manifest, and
/// if a newer build exists it downloads the `.zip`, verifies its SHA-256,
/// swaps its own bundle in place, and relaunches itself.
///
/// The update feed is read from the `CLIPFeedURL` Info.plist key (set by
/// `Scripts/make-app.sh` for release builds). Dev builds have no key → the
/// updater is inert, so `swift run` / debug bundles never self-update.
///
/// Safety: user data in `~/Library/Application Support/CLIP` is never touched;
/// any network / verification / permission failure aborts silently and the
/// running app is left exactly as-is.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// How often to poll while running (10 min — matches the kiosk cadence).
    private let interval: TimeInterval = 600

    private var timer: Timer?
    private var inFlight = false

    private struct Manifest: Decodable {
        let build: Int
        let version: String
        let url: String
        let sha256: String
        /// Base64 Ed25519 signature of the zip (see Scripts/sign-update.swift).
        let signature: String?
    }

    /// Refuse anything bigger — a real build is tens of MB.
    private let maxUpdateBytes: Int64 = 500 * 1024 * 1024

    private var feedURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "CLIPFeedURL") as? String,
              !s.isEmpty, let u = URL(string: s) else { return nil }
        return u
    }

    /// Ed25519 public key baked in at build time (`CLIPUpdatePublicKey`).
    /// When present, every update MUST carry a valid signature from the
    /// matching private key — the manifest's SHA-256 alone proves nothing,
    /// since it's served from the same place as the zip.
    private var updatePublicKey: Curve25519.Signing.PublicKey? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "CLIPUpdatePublicKey") as? String,
              let raw = Data(base64Encoded: s) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    private var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    // MARK: - Lifecycle

    /// Begin polling. No-op when there's no feed (dev builds).
    func start() {
        guard feedURL != nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func check() {
        guard !inFlight, let feed = feedURL else { return }
        inFlight = true
        Task { @MainActor in
            defer { inFlight = false }
            do { try await runCheck(feed) }
            catch {
                // Silent to the user — never disturb a running exhibit —
                // but visible in Console so a stuck update is diagnosable.
                Log.updater.error("Update check failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Check / download / verify / install

    private enum UpdateError: Error {
        case insecureURL, tooLarge, hashMismatch, badSignature, unzipFailed(Int32)
    }

    private func runCheck(_ feed: URL) async throws {
        var req = URLRequest(url: feed)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        let m = try JSONDecoder().decode(Manifest.self, from: data)

        guard m.build > currentBuild, let zipURL = URL(string: m.url) else { return }
        guard zipURL.scheme?.lowercased() == "https" else { throw UpdateError.insecureURL }

        // Download the update archive with a hard deadline so a stalled
        // server can't wedge `inFlight` (and every later check) forever.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (tmpZip, _) = try await session.download(from: zipURL)

        // Size-check, then hash + signature-check off the main actor —
        // the zip is tens of MB and this class is @MainActor.
        let maxBytes = maxUpdateBytes
        let publicKey = updatePublicKey
        let zipData = try await Task.detached(priority: .utility) { () throws -> Data in
            let size = (try? tmpZip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard Int64(size) <= maxBytes else { throw UpdateError.tooLarge }
            let data = try Data(contentsOf: tmpZip, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest.caseInsensitiveCompare(m.sha256) == .orderedSame else {
                throw UpdateError.hashMismatch
            }
            if let publicKey {
                guard let sigB64 = m.signature, let sig = Data(base64Encoded: sigB64),
                      publicKey.isValidSignature(sig, for: data) else {
                    throw UpdateError.badSignature
                }
            }
            return data
        }.value
        if publicKey == nil {
            Log.updater.warning("No CLIPUpdatePublicKey in this build — update is hash-checked only")
        }

        // Unzip into a private work dir.
        let fm = FileManager.default
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zipDst = work.appendingPathComponent("CLIP.zip")
        try zipData.write(to: zipDst)
        let status = try runTool("/usr/bin/ditto", ["-x", "-k", zipDst.path, work.path])
        guard status == 0 else { throw UpdateError.unzipFailed(status) }

        let newApp = work.appendingPathComponent("CLIP.app")
        guard fm.fileExists(atPath: newApp.path) else { return }

        // Strip the download quarantine so the swapped bundle relaunches without
        // a Gatekeeper block. Safe only because the bytes were verified above.
        try? runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        try swapAndRelaunch(newApp: newApp)
    }

    /// Hand off to a detached shell that waits for us to quit, replaces the
    /// installed bundle, and relaunches it. Then terminate. The helper outlives
    /// this process, so the swap happens while nothing is running from the old
    /// bundle. Paths are passed as argv (no string interpolation into the
    /// script body) so spaces/odd characters can't break or inject.
    private func swapAndRelaunch(newApp: URL) throws {
        let installed = Bundle.main.bundleURL                 // …/CLIP.app
        let parent = installed.deletingLastPathComponent()

        // Bail silently if we can't write where the app lives (e.g. a
        // locked-down /Applications without admin rights).
        guard FileManager.default.isWritableFile(atPath: parent.path) else { return }

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        PID="$1"; OLD="$2"; NEW="$3"
        # Wait for the running app to fully exit.
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        # Move the old bundle aside first so a failed move-in can be rolled
        # back — never leave the machine with no app installed.
        BACKUP="$OLD.previous"
        rm -rf "$BACKUP"
        if ! mv "$OLD" "$BACKUP"; then open "$OLD"; exit 1; fi
        if mv "$NEW" "$OLD"; then
            rm -rf "$BACKUP"
        else
            rm -rf "$OLD"
            mv "$BACKUP" "$OLD"
        fi
        xattr -dr com.apple.quarantine "$OLD" 2>/dev/null
        open "$OLD"
        """
        let scriptURL = newApp.deletingLastPathComponent().appendingPathComponent("relaunch.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path, String(pid), installed.path, newApp.path]
        try task.run()

        NSApp.terminate(nil)
    }

    @discardableResult
    private func runTool(_ path: String, _ args: [String]) throws -> Int32 {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: path)
        t.arguments = args
        try t.run()
        t.waitUntilExit()
        return t.terminationStatus
    }
}
