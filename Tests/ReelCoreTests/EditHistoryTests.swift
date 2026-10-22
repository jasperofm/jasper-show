import XCTest
@testable import ReelCore

final class EditHistoryTests: XCTestCase {
    func testUndoRedo() {
        var h = EditHistory(.identity)
        var a = EditSettings(); a.brightness = 0.2
        var b = a; b.zoom = 2
        h.apply(a, label: "Brightness")
        h.apply(b, label: "Zoom")
        XCTAssertTrue(h.undo())
        XCTAssertEqual(h.current, a)
        XCTAssertTrue(h.undo())
        XCTAssertEqual(h.current, .identity)
        XCTAssertFalse(h.undo())
        XCTAssertTrue(h.redo())
        XCTAssertEqual(h.current, a)
        XCTAssertEqual(h.redoLabel, "Zoom")
    }

    func testNewEditClearsRedo() {
        var h = EditHistory(.identity)
        var a = EditSettings(); a.brightness = 0.2
        h.apply(a, label: "B")
        h.undo()
        var c = EditSettings(); c.contrast = 1.5
        h.apply(c, label: "C")
        XCTAssertFalse(h.canRedo)
    }

    func testDragCoalescesIntoOneStep() {
        var h = EditHistory(.identity)
        h.beginCoalescing()
        for v in stride(from: 0.1, through: 0.5, by: 0.1) {
            var s = h.current; s.brightness = v
            h.apply(s, label: "Brightness")
        }
        h.endCoalescing()
        XCTAssertTrue(h.undo())
        XCTAssertEqual(h.current, .identity)
        XCTAssertFalse(h.canUndo)
    }

    func testNoOpDragLeavesNoStep() {
        var h = EditHistory(.identity)
        h.beginCoalescing()
        var s = h.current; s.brightness = 0.3
        h.apply(s, label: "B")
        h.apply(.identity, label: "B")
        h.endCoalescing()
        XCTAssertFalse(h.canUndo)
    }
}
