import XCTest
@testable import ReelCore

final class SchedulingTests: XCTestCase {
    func testStaggerPlanner() {
        let start = Date(timeIntervalSince1970: 0)
        let d = StaggerPlanner.dates(count: 3, start: start, interval: 4 * 3600)
        XCTAssertEqual(d.map(\.timeIntervalSince1970), [0, 14400, 28800])
        XCTAssertTrue(StaggerPlanner.dates(count: 0, start: start, interval: 60).isEmpty)
    }

    func testYouTubeRedirectFromClientID() {
        XCTAssertEqual(OAuthRedirects.suggested(for: .youtube, clientID: "123-abc.apps.googleusercontent.com"),
                       "com.googleusercontent.apps.123-abc:/oauth2redirect")
        XCTAssertTrue(OAuthRedirects.suggested(for: .tiktok, clientID: "x").hasSuffix("/oauth/tiktok/"))
    }

    func testOverlayRoundTripsThroughStore() throws {
        let store = try LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let a = SourceAsset(title: "c", relativePath: "Sources/c.mov", originalFilename: "c.mov",
                            duration: 10, pixelWidth: 1080, pixelHeight: 1920, frameRate: 30)
        try store.insert(a)
        var v = Variation(assetID: a.id, name: "V")
        v.settings.overlay = TextOverlay(text: "Hello", position: .bottom)
        try store.insert(v)
        XCTAssertEqual(try store.variation(id: v.id)?.settings.overlay?.text, "Hello")

        let acc = Account(platform: .facebook, username: "Page", remoteID: "1", status: .connected)
        try store.upsert(acc)
        let job = PostJob(variationID: v.id, accountID: acc.id, overlay: TextOverlay(text: "Per account"))
        try store.upsert(job)
        XCTAssertEqual(try store.job(id: job.id)?.overlay?.text, "Per account")

        try store.upsert(PostStats(jobID: job.id, views: 10, likes: 2, comments: 1))
        XCTAssertEqual(try store.stats()[job.id]?.engagement, 3)
    }

    func testOldSettingsJSONWithoutOverlayStillDecodes() throws {
        var s = EditSettings()
        s.zoom = 2
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        obj.removeValue(forKey: "overlay")
        let back = try JSONDecoder().decode(EditSettings.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(back.zoom, 2)
        XCTAssertNil(back.overlay)
    }

    func testPlatformSpecWarnings() {
        let fb = PlatformSpec.spec(for: .facebook)
        XCTAssertFalse(fb.issues(duration: 120, aspect: 9.0 / 16.0, fileBytes: nil).isEmpty)
        XCTAssertTrue(fb.issues(duration: 30, aspect: 9.0 / 16.0, fileBytes: nil).isEmpty)
    }
}
