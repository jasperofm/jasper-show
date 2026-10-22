import XCTest
@testable import ReelCore

final class LibraryStoreTests: XCTestCase {
    var store: LibraryStore!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try LibraryStore(root: dir)
    }

    private func seed() throws -> (SourceAsset, Variation, Account) {
        let a = SourceAsset(title: "clip", relativePath: "Sources/x.mov", originalFilename: "x.mov",
                            duration: 30, pixelWidth: 1080, pixelHeight: 1920, frameRate: 30)
        try store.insert(a)
        let v = Variation(assetID: a.id, name: "V1")
        try store.insert(v)
        let acc = Account(platform: .youtube, username: "chan", remoteID: "UC1", status: .connected)
        try store.upsert(acc)
        return (a, v, acc)
    }

    func testVariationRoundTripAndRevisions() throws {
        let (_, v, _) = try seed()
        var edited = v
        edited.settings.zoom = 1.5
        edited.updatedAt = Date()
        try store.save(edited)
        try store.save(edited) // identical → no new revision
        XCTAssertEqual(try store.variation(id: v.id)?.settings.zoom, 1.5)
        XCTAssertEqual(try store.revisions(for: v.id).count, 2)
    }

    func testPruneHistoryDropsOldRevisions() throws {
        let (_, v, _) = try seed()
        try store.pruneHistory(now: Date().addingTimeInterval(31 * 24 * 3600))
        XCTAssertTrue(try store.revisions(for: v.id).isEmpty)
    }

    func testDueJobs() throws {
        let (_, v, acc) = try seed()
        let now = Date()
        try store.upsert(PostJob(variationID: v.id, accountID: acc.id, status: .scheduled, scheduledAt: now.addingTimeInterval(-10), approvedAt: now))
        try store.upsert(PostJob(variationID: v.id, accountID: acc.id, status: .scheduled, scheduledAt: now.addingTimeInterval(600), approvedAt: now))
        try store.upsert(PostJob(variationID: v.id, accountID: acc.id, status: .failed, nextAttemptAt: now.addingTimeInterval(-1), approvedAt: now))
        try store.upsert(PostJob(variationID: v.id, accountID: acc.id, status: .failed, approvedAt: now)) // manual retry only
        // A draft is never due, even with a time set.
        try store.upsert(PostJob(variationID: v.id, accountID: acc.id, status: .scheduled, scheduledAt: now.addingTimeInterval(-10)))
        XCTAssertEqual(try store.dueJobs(now: now).count, 2)
    }

    func testAttemptLog() throws {
        let (_, v, acc) = try seed()
        let j = PostJob(variationID: v.id, accountID: acc.id, privacy: .privateOnly)
        try store.upsert(j)
        let id = try store.beginAttempt(jobID: j.id)
        try store.finishAttempt(id: id, succeeded: false, httpStatus: 500, message: "boom")
        let log = try store.attempts(for: j.id)
        XCTAssertEqual(log.first?.httpStatus, 500)
        XCTAssertEqual(try store.job(id: j.id)?.privacy, .privateOnly)
    }

    func testDeletingAssetCascades() throws {
        let (a, v, acc) = try seed()
        try store.upsert(PostJob(variationID: v.id, accountID: acc.id))
        try store.deleteAsset(a)
        XCTAssertTrue(try store.allVariations().isEmpty)
        XCTAssertTrue(try store.jobs().isEmpty)
    }
}

final class RetryPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func testSchedule() {
        let p = RetryPolicy()
        XCTAssertEqual(p.nextAttempt(afterFailureNumber: 1, error: nil, now: now), now.addingTimeInterval(60))
        XCTAssertEqual(p.nextAttempt(afterFailureNumber: 2, error: nil, now: now), now.addingTimeInterval(300))
        XCTAssertEqual(p.nextAttempt(afterFailureNumber: 3, error: nil, now: now), now.addingTimeInterval(900))
        XCTAssertNil(p.nextAttempt(afterFailureNumber: 4, error: nil, now: now))
    }

    func testNonRetryableErrorsWaitForUser() {
        let e = PlatformError(platform: .tiktok, httpStatus: 400, message: "bad")
        XCTAssertNil(RetryPolicy().nextAttempt(afterFailureNumber: 1, error: e, now: now))
    }

    func testRetryAfterIsHonored() {
        let e = PlatformError(platform: .instagram, httpStatus: 429, message: "slow down", retryAfter: 3600)
        XCTAssertEqual(RetryPolicy().nextAttempt(afterFailureNumber: 1, error: e, now: now), now.addingTimeInterval(3600))
    }

    func testRateLimiterSpacing() async {
        let limiter = RateLimiter(minSpacing: [.youtube: 30])
        let acc = Account(platform: .youtube, username: "x")
        await limiter.recordCall(for: acc, at: now)
        let wait = await limiter.waitTime(for: acc, now: now.addingTimeInterval(10))
        XCTAssertEqual(wait, 20, accuracy: 0.001)
    }

    func testTikTokChunkPlan() {
        XCTAssertEqual(TikTokClient.chunkPlan(fileSize: 10 * 1024 * 1024).count, 1)
        let big = TikTokClient.chunkPlan(fileSize: 105 * 1024 * 1024)
        XCTAssertEqual(big.chunkSize, 10 * 1024 * 1024)
        XCTAssertEqual(big.count, 10) // last chunk carries the 5 MB remainder
    }
}
