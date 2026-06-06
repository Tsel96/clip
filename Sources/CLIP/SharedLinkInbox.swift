import Foundation

/// Watches a user-chosen iCloud Drive folder for tiny "shared link" files
/// dropped by the iPhone **"Add to Canvas"** Shortcut, and hands each URL
/// to `CanvasState` to ingest as a phone-origin card.
///
/// Uses `NSMetadataQuery` scoped to the folder — the correct API for an
/// iCloud directory, because it reports a file only once iCloud has
/// finished downloading it (raw FSEvents would fire on the not-yet-
/// downloaded placeholder and we'd read an empty file). A synchronous
/// `sweep` covers files already present at launch and the non-iCloud
/// (plain local folder) case.
@MainActor
final class SharedLinkInbox {

    /// Invoked with each newly-arrived URL string. Wired by `CanvasState`.
    var onURL: ((String) -> Void)?

    /// File extensions the Shortcut may use; the file's text contents are
    /// the shared URL.
    static let acceptedExtensions: Set<String> = ["weblink", "url", "txt"]

    private let query = NSMetadataQuery()
    private(set) var folderURL: URL?
    private var observers: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    func start(folderURL: URL) {
        stop()
        self.folderURL = folderURL

        let nc = NotificationCenter.default
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering,
                     NSNotification.Name.NSMetadataQueryDidUpdate] {
            observers.append(
                nc.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    self?.processQueryResults()
                }
            )
        }

        // A directory URL is a valid search scope — restricts the query to
        // just this folder rather than the whole ubiquity container.
        query.searchScopes = [folderURL]
        query.predicate = NSPredicate(value: true)
        query.start()

        // Drain anything already sitting there right now.
        sweep(folderURL: folderURL)
    }

    func stop() {
        if query.isStarted { query.stop() }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        folderURL = nil
    }

    /// One-shot sweep — call on launch / `applicationDidBecomeActive` so
    /// links that arrived while the app was closed get picked up.
    func sweepNow() {
        if let f = folderURL { sweep(folderURL: f) }
    }

    // MARK: - Ingestion

    private func processQueryResults() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  Self.acceptedExtensions.contains(url.pathExtension.lowercased())
            else { continue }

            // If iCloud hasn't downloaded the file yet, kick the download and
            // wait for the next update notification to read it.
            if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
               status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }
            ingest(fileURL: url)
        }
    }

    private func sweep(folderURL: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil
        ) else { return }
        for url in items where Self.acceptedExtensions.contains(url.pathExtension.lowercased()) {
            ingest(fileURL: url)
        }
    }

    /// Read the URL out of one shared-link file, hand it off, and delete the
    /// file so it's never ingested twice.
    private func ingest(fileURL: URL) {
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        // The Shortcut writes just the URL; be tolerant of trailing newline
        // or a leading line of text.
        let urlString = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.lowercased().hasPrefix("http") })
            ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard urlString.lowercased().hasPrefix("http") else { return }
        onURL?(urlString)
    }
}
