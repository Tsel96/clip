import Foundation

/// One slice of undoable state: everything on a single page (the rest of
/// `CanvasState` is session UI state — tool mode, current selection, etc.
/// — which isn't worth undoing).
struct PageSnapshot: Equatable {
    var nodes: [CanvasNode]
    var connectors: [Connector]
}

/// Bounded undo / redo stacks for a single page.
struct UndoStack: Equatable {
    /// Past snapshots, oldest → newest. The most recent entry is the
    /// "checkpoint before the current state" — undoing replaces the
    /// current page with it and pushes the *current* state onto `future`.
    var past: [PageSnapshot] = []
    /// Future snapshots, newest → oldest (LIFO for redo).
    var future: [PageSnapshot] = []

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    private static let limit = 50

    mutating func push(_ snapshot: PageSnapshot) {
        // Don't grow past the cap.
        if past.count >= Self.limit { past.removeFirst() }
        past.append(snapshot)
        future.removeAll()                  // a new action invalidates redo
    }

    mutating func popUndo(current: PageSnapshot) -> PageSnapshot? {
        guard let restore = past.popLast() else { return nil }
        future.append(current)
        if future.count > Self.limit { future.removeFirst() }
        return restore
    }

    mutating func popRedo(current: PageSnapshot) -> PageSnapshot? {
        guard let restore = future.popLast() else { return nil }
        past.append(current)
        if past.count > Self.limit { past.removeFirst() }
        return restore
    }
}
