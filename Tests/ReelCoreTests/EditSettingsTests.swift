import XCTest
@testable import ReelCore

final class EditSettingsTests: XCTestCase {
    func testMergeCutsSortsMergesAndClips() {
        let cuts = [TimeRange(start: 5, end: 7), TimeRange(start: 1, end: 3), TimeRange(start: 2.5, end: 4), TimeRange(start: 9, end: 20)]
        let merged = EditSettings.mergeCuts(cuts, duration: 10)
        XCTAssertEqual(merged.map(\.start), [1, 5, 9])
        XCTAssertEqual(merged.map(\.end), [4, 7, 10])
    }

    func testKeptRangesAndOutputDuration() {
        var s = EditSettings()
        s.cuts = [TimeRange(start: 2, end: 4)]
        s.speed = 2
        let kept = s.keptRanges(sourceDuration: 10)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept[0].end, 2)
        XCTAssertEqual(kept[1].start, 4)
        XCTAssertEqual(s.outputDuration(sourceDuration: 10), 4, accuracy: 0.0001)
    }

    func testNormalizedClampsValues() {
        var s = EditSettings()
        s.zoom = 10; s.speed = 0.1; s.brightness = 5
        s.crop = CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5) // mostly outside → too small → reset
        let n = s.normalized(sourceDuration: 10)
        XCTAssertEqual(n.zoom, 4)
        XCTAssertEqual(n.speed, 0.5)
        XCTAssertEqual(n.brightness, 1)
        XCTAssertEqual(n.crop, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testCodableRoundTrip() throws {
        var s = EditSettings()
        s.crop = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        s.cuts = [TimeRange(start: 1, end: 2)]
        s.outputAspect = .vertical9x16
        let back = try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testChangeSummary() {
        XCTAssertEqual(EditSettings().changeSummary, ["No edits"])
        var s = EditSettings()
        s.zoom = 1.5
        XCTAssertEqual(s.changeSummary, ["Zoom 1.50×"])
    }
}

final class FrameGeometryTests: XCTestCase {
    let size = CGSize(width: 1920, height: 1080)

    func testIdentityIsWholeFrame() {
        let g = FrameGeometry(sourceSize: size, settings: .identity)
        XCTAssertEqual(g.window, CGRect(origin: .zero, size: size))
        XCTAssertEqual(g.coverScale, 1, accuracy: 1e-9)
        XCTAssertEqual(g.renderSize(maxLongEdge: 1920), size)
    }

    func testCropConvertsToBottomLeftOrigin() {
        var s = EditSettings()
        s.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5) // top-left quarter
        let g = FrameGeometry(sourceSize: size, settings: s)
        XCTAssertEqual(g.window, CGRect(x: 0, y: 540, width: 960, height: 540))
    }

    func testVerticalAspectFit() {
        var s = EditSettings()
        s.outputAspect = .vertical9x16
        let g = FrameGeometry(sourceSize: size, settings: s)
        XCTAssertEqual(g.window.height, 1080, accuracy: 0.01)
        XCTAssertEqual(g.window.width, 607.5, accuracy: 0.01)
        XCTAssertEqual(g.window.midX, 960, accuracy: 0.01)
    }

    func testZoomAndPan() {
        var s = EditSettings()
        s.zoom = 2
        s.pan = CGPoint(x: 1, y: 0)
        let g = FrameGeometry(sourceSize: size, settings: s)
        XCTAssertEqual(g.window.size.width, 960, accuracy: 0.01)
        XCTAssertEqual(g.window.maxX, 1920, accuracy: 0.01) // panned fully right
    }

    func testRotationNeedsCoverScale() {
        var s = EditSettings()
        s.rotation = 90
        let g = FrameGeometry(sourceSize: size, settings: s)
        XCTAssertEqual(g.coverScale, 1920.0 / 1080.0, accuracy: 1e-6)
    }

    func testRenderSizeCapsAndIsEven() {
        let g = FrameGeometry(sourceSize: CGSize(width: 3841, height: 2161), settings: .identity)
        let r = g.renderSize(maxLongEdge: 1920)
        XCTAssertEqual(r.width, 1920)
        XCTAssertEqual(Int(r.height) % 2, 0)
    }
}
