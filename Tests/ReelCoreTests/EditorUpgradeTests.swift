import XCTest
import AVFoundation
@testable import ReelCore

final class EditorUpgradeTests: XCTestCase {
    func testOldVariationJSONDecodesWithNewDefaults() throws {
        // Settings saved by 0.3.0 had no look, audio or cover keys.
        let old = #"{"crop":[[0,0],[1,1]],"pan":[0,0],"zoom":1.5,"rotation":0,"outputAspect":"source","brightness":0.1,"contrast":1,"saturation":1,"temperature":6500,"cuts":[],"speed":1}"#
        let s = try JSONDecoder().decode(EditSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.zoom, 1.5)
        XCTAssertEqual(s.brightness, 0.1)
        XCTAssertEqual(s.volume, 1)
        XCTAssertEqual(s.vignette, 0)
        XCTAssertNil(s.coverTime)
        XCTAssertNil(s.lutID)
    }

    func testNewFieldsRoundTripAndClamp() throws {
        var s = EditSettings()
        s.volume = 5; s.fadeIn = 9; s.vignette = -1; s.coverTime = 2.5; s.lutID = "Film.cube"
        let back = try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        let n = s.normalized(sourceDuration: 10)
        XCTAssertEqual(n.volume, 2)
        XCTAssertEqual(n.fadeIn, 5)
        XCTAssertEqual(n.vignette, 0)
        XCTAssertTrue(n.changeSummary.contains("Cover at 2.5s"))
    }

    func testLooksOnlyTouchColor() {
        var s = EditSettings()
        s.zoom = 2
        s.cuts = [TimeRange(start: 1, end: 2)]
        LookPreset.mono.apply(to: &s)
        XCTAssertEqual(s.saturation, 0)
        XCTAssertEqual(s.zoom, 2)
        XCTAssertEqual(s.cuts.count, 1)
        LookPreset.natural.apply(to: &s)
        XCTAssertEqual(s.saturation, 1)
    }

    func testCubeParsing() throws {
        var text = "TITLE \"Identity\"\n# comment\nLUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(r) \(g) \(b)\n" } } }
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.data.count, 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n"))
        XCTAssertThrowsError(try CubeLUT.parse("0 0 0\n"))
    }

    func testLUTImportAndApply() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lib = LUTLibrary(directory: dir)
        var text = "LUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(1 - r) \(1 - g) \(1 - b)\n" } } } // invert
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("Invert-\(UUID().uuidString).cube")
        try text.write(to: src, atomically: true, encoding: .utf8)
        let id = try lib.importCube(from: src)
        XCTAssertEqual(lib.available(), [id])
        let img = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let out = lib.apply(id, intensity: 1, to: img)
        XCTAssertEqual(out.extent, img.extent)
        XCTAssertTrue(lib.apply("missing.cube", intensity: 1, to: img) === img)
    }

    func testSafeZonesLeaveRoom() {
        for p in Platform.allCases {
            let r = SafeZone.for(p).safeRect
            XCTAssertGreaterThan(r.width, 0.5)
            XCTAssertGreaterThan(r.height, 0.3)
        }
    }

    func testAudioMixOnlyWhenNeeded() {
        let comp = AVMutableComposition()
        _ = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        XCTAssertNil(VariationRenderer.makeAudioMix(for: comp, settings: EditSettings()))
        var s = EditSettings()
        s.fadeIn = 1
        XCTAssertNotNil(VariationRenderer.makeAudioMix(for: comp, settings: s))
    }
}
