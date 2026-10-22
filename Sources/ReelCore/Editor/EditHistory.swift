import Foundation

/// Undo/redo stack of whole `EditSettings` snapshots. Snapshots are tiny, so
/// storing values beats storing inverse operations and can never desync.
///
/// Slider drags should call `beginCoalescing()` on mouse-down and
/// `endCoalescing()` on mouse-up, so one drag is one undo step.
public struct EditHistory: Sendable {
    public private(set) var current: EditSettings
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private var coalescing = false
    private var coalesceStart: EditSettings?
    public let limit: Int

    public struct Entry: Sendable {
        public let settings: EditSettings
        public let label: String
    }

    public init(_ initial: EditSettings, limit: Int = 500) {
        current = initial
        self.limit = limit
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }

    /// Applies a change. No-op if the value didn't actually change.
    public mutating func apply(_ new: EditSettings, label: String) {
        guard new != current else { return }
        if coalescing {
            if coalesceStart == nil {
                coalesceStart = current
                push(Entry(settings: current, label: label))
            }
        } else {
            push(Entry(settings: current, label: label))
        }
        current = new
        redoStack.removeAll()
    }

    public mutating func beginCoalescing() {
        coalescing = true
        coalesceStart = nil
    }

    public mutating func endCoalescing() {
        coalescing = false
        // A drag that ended where it started leaves no undo step.
        if let start = coalesceStart, start == current { undoStack.removeLast() }
        coalesceStart = nil
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let e = undoStack.popLast() else { return false }
        redoStack.append(Entry(settings: current, label: e.label))
        current = e.settings
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let e = redoStack.popLast() else { return false }
        undoStack.append(Entry(settings: current, label: e.label))
        current = e.settings
        return true
    }

    /// Replaces the state without an undo step (e.g. after loading).
    public mutating func reset(to s: EditSettings) {
        current = s
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private mutating func push(_ e: Entry) {
        undoStack.append(e)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
    }
}
