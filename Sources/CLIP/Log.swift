import os

/// Process-wide loggers, one per area. Failures stay silent in the UI
/// (persistence and updating are best-effort) but remain visible in
/// Console.app for diagnostics and bug reports.
enum Log {
    static let persistence = Logger(subsystem: "com.clip.app", category: "persistence")
    static let updater     = Logger(subsystem: "com.clip.app", category: "updater")
}
