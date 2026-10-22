import XCTest
@testable import ReelCore

final class PublishGateTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// 2024-05-01 12:00 UTC
    let noon = Date(timeIntervalSince1970: 1_714_564_800)
    let account = Account(platform: .instagram, username: "me", status: .connected)

    private func job(approved: Bool = true) -> PostJob {
        PostJob(variationID: UUID(), accountID: account.id, status: .scheduled, scheduledAt: noon,
                approvedAt: approved ? noon : nil)
    }

    private func eval(_ rules: PublishRules = PublishRules(), job j: PostJob? = nil, account a: Account? = nil,
                      history: PublishHistory = PublishHistory(), system: SystemSnapshot = SystemSnapshot(),
                      at now: Date? = nil) -> PublishGate.Decision {
        PublishGate.evaluate(job: j ?? job(), account: a ?? account, rules: rules, history: history,
                             system: system, now: now ?? noon, calendar: cal)
    }

    func testAllowsByDefault() {
        XCTAssertEqual(eval(), .allow)
    }

    func testDraftsAreNeverAllowed() {
        XCTAssertFalse(eval(job: job(approved: false)).isAllowed)
    }

    func testKillSwitchAndPauses() {
        var r = PublishRules()
        r.killSwitch = true
        XCTAssertFalse(eval(r).isAllowed)

        var paused = account
        paused.isPaused = true
        XCTAssertFalse(eval(account: paused).isAllowed)

        var p = PublishRules()
        p.pausedPlatforms = [.instagram]
        XCTAssertFalse(eval(p).isAllowed)
        p.pausedPlatforms = [.tiktok]
        XCTAssertEqual(eval(p), .allow)
    }

    func testDisconnectedAccountIsHeld() {
        var a = account
        a.status = .error
        XCTAssertFalse(eval(account: a).isAllowed)
    }

    func testDailyCapsHoldUntilTomorrow() {
        var r = PublishRules()
        r.perAccountDailyCap = 2
        let d = eval(r, history: PublishHistory(accountPostsToday: 2))
        guard case .hold(_, let until) = d else { return XCTFail("expected hold") }
        XCTAssertEqual(until, cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: noon)))

        r.globalDailyCap = 5
        XCTAssertFalse(eval(r, history: PublishHistory(globalPostsToday: 5)).isAllowed)

        r.platformDailyCaps = [.instagram: 1]
        XCTAssertFalse(eval(r, history: PublishHistory(platformPostsToday: 1)).isAllowed)
    }

    func testMinimumGap() {
        var r = PublishRules()
        r.minGapMinutes = 60
        let last = noon.addingTimeInterval(-20 * 60)
        guard case .hold(_, let until) = eval(r, history: PublishHistory(accountLastPostedAt: last)) else {
            return XCTFail("expected hold")
        }
        XCTAssertEqual(until, last.addingTimeInterval(3600))
        XCTAssertEqual(eval(r, history: PublishHistory(accountLastPostedAt: noon.addingTimeInterval(-61 * 60))), .allow)
    }

    func testPostingWindowAndQuietHours() {
        var r = PublishRules()
        r.postingWindow = DailyWindow(start: (14, 0), end: (18, 0))
        guard case .hold(_, let until) = eval(r) else { return XCTFail("expected hold") }
        XCTAssertEqual(until, noon.addingTimeInterval(2 * 3600))

        var q = PublishRules()
        q.blackoutWindows = [DailyWindow(start: (23, 0), end: (7, 0))]
        XCTAssertEqual(eval(q), .allow)
        let lateNight = noon.addingTimeInterval(12 * 3600) // 00:00
        guard case .hold(_, let end) = eval(q, at: lateNight) else { return XCTFail("expected hold") }
        XCTAssertEqual(end, lateNight.addingTimeInterval(7 * 3600))
    }

    func testWindowCrossingMidnight() {
        let w = DailyWindow(start: (22, 0), end: (6, 0))
        XCTAssertTrue(w.crossesMidnight)
        XCTAssertTrue(w.contains(minute: 23 * 60))
        XCTAssertTrue(w.contains(minute: 3 * 60))
        XCTAssertFalse(w.contains(minute: 12 * 60))
    }

    func testSystemConditions() {
        XCTAssertFalse(eval(system: SystemSnapshot(online: false)).isAllowed)
        XCTAssertFalse(eval(system: SystemSnapshot(batteryPercent: 10, onBattery: true)).isAllowed)
        XCTAssertEqual(eval(system: SystemSnapshot(batteryPercent: 10, onBattery: false)), .allow)
        XCTAssertFalse(eval(system: SystemSnapshot(freeDiskGB: 0.5)).isAllowed)
    }

    func testSleepWindow() {
        XCTAssertTrue(PublishGate.isInLikelySleepWindow(noon.addingTimeInterval(-9 * 3600), calendar: cal)) // 03:00
        XCTAssertFalse(PublishGate.isInLikelySleepWindow(noon, calendar: cal))
    }
}

final class RedactorTests: XCTestCase {
    func testRedactsTokens() {
        let s = Redactor.redact("GET /me?access_token=EAAB123secret&fields=id Authorization: Bearer ya29.abcdefghijk {\"refresh_token\":\"1//xyz\"}")
        XCTAssertFalse(s.contains("EAAB123secret"))
        XCTAssertFalse(s.contains("ya29.abcdefghijk"))
        XCTAssertFalse(s.contains("1//xyz"))
        XCTAssertTrue(s.contains("fields=id"))
    }
}

final class SafePublishingStoreTests: XCTestCase {
    var store: LibraryStore!
    var account: Account!
    var variation: Variation!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try LibraryStore(root: dir)
        let a = SourceAsset(title: "clip", relativePath: "Sources/x.mov", originalFilename: "x.mov",
                            duration: 30, pixelWidth: 1080, pixelHeight: 1920, frameRate: 30)
        try store.insert(a)
        variation = Variation(assetID: a.id, name: "V1")
        try store.insert(variation)
        account = Account(platform: .tiktok, username: "me", remoteID: "1", status: .connected)
        try store.upsert(account)
    }

    func testAccountPauseFieldsRoundTrip() throws {
        account.isPaused = true
        account.pauseReason = "test"
        account.consecutiveFailures = 2
        account.tokenExpiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        try store.upsert(account)
        let back = try XCTUnwrap(try store.account(id: account.id))
        XCTAssertTrue(back.isPaused)
        XCTAssertEqual(back.pauseReason, "test")
        XCTAssertEqual(back.consecutiveFailures, 2)
        XCTAssertEqual(back.tokenExpiresAt, account.tokenExpiresAt)
        XCTAssertFalse(back.canPublish)
    }

    func testJobCheckpointApprovalAndHoldRoundTrip() throws {
        var j = PostJob(variationID: variation.id, accountID: account.id, status: .held,
                        approvedAt: Date(timeIntervalSince1970: 1_700_000_000), holdReason: "Quiet hours")
        try store.upsert(j)
        try store.saveCheckpoint(PublishCheckpoint(step: .uploaded, remoteID: "pub_1"), jobID: j.id)
        j = try XCTUnwrap(try store.job(id: j.id))
        XCTAssertEqual(j.checkpoint?.step, .uploaded)
        XCTAssertEqual(j.checkpoint?.remoteID, "pub_1")
        XCTAssertEqual(j.holdReason, "Quiet hours")
        XCTAssertTrue(j.isApproved)
        XCTAssertEqual(j.stateLabel, "Held")
    }

    func testClaimIsExclusive() throws {
        let draft = PostJob(variationID: variation.id, accountID: account.id)
        try store.upsert(draft)
        XCTAssertFalse(try store.claim(jobID: draft.id), "drafts can't be claimed")

        let j = PostJob(variationID: variation.id, accountID: account.id, status: .scheduled, approvedAt: Date())
        try store.upsert(j)
        XCTAssertTrue(try store.claim(jobID: j.id))
        XCTAssertFalse(try store.claim(jobID: j.id), "second claim must fail")
        XCTAssertEqual(try store.job(id: j.id)?.status, .uploading)
    }

    func testResetInterruptedKeepsCheckpointAndSkipsFreshJobs() throws {
        let now = Date()
        let stale = PostJob(variationID: variation.id, accountID: account.id, status: .uploading, approvedAt: now,
                            checkpoint: PublishCheckpoint(step: .created, remoteID: "c1"), updatedAt: now.addingTimeInterval(-3600))
        let fresh = PostJob(variationID: variation.id, accountID: account.id, status: .uploading, approvedAt: now, updatedAt: now)
        try store.upsert(stale)
        try store.upsert(fresh)
        try store.resetInterruptedJobs(now: now, staleAfter: 1800)
        XCTAssertEqual(try store.job(id: stale.id)?.status, .failed)
        XCTAssertEqual(try store.job(id: stale.id)?.checkpoint?.remoteID, "c1")
        XCTAssertEqual(try store.job(id: fresh.id)?.status, .uploading)
    }

    func testHeldJobsBecomeDueAtRecheckTime() throws {
        let now = Date()
        let j = PostJob(variationID: variation.id, accountID: account.id, status: .held,
                        scheduledAt: now.addingTimeInterval(-600), nextAttemptAt: now.addingTimeInterval(300), approvedAt: now)
        try store.upsert(j)
        XCTAssertTrue(try store.dueJobs(now: now).isEmpty)
        XCTAssertEqual(try store.dueJobs(now: now.addingTimeInterval(301)).count, 1)
        XCTAssertEqual(try XCTUnwrap(try store.nextWakeDate()).timeIntervalSince1970,
                       try XCTUnwrap(j.nextAttemptAt).timeIntervalSince1970, accuracy: 0.001)
    }

    func testPostedCountsAndLastPosted() throws {
        let now = Date()
        for i in 0..<3 {
            try store.upsert(PostJob(variationID: variation.id, accountID: account.id, status: .posted, approvedAt: now,
                                     postedAt: now.addingTimeInterval(Double(-i) * 3600)))
        }
        XCTAssertEqual(try store.postedCount(accountID: account.id, since: now.addingTimeInterval(-5400)), 2)
        XCTAssertEqual(try store.postedCount(since: now.addingTimeInterval(-86400)), 3)
        XCTAssertEqual(try XCTUnwrap(try store.lastPostedAt(accountID: account.id)).timeIntervalSince1970,
                       now.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRulesPersistInSettings() throws {
        var r = PublishRules()
        r.killSwitch = true
        r.perAccountDailyCap = 7
        r.pausedPlatforms = [.youtube]
        r.platformDailyCaps = [.instagram: 25]
        r.blackoutWindows = [DailyWindow(start: (23, 0), end: (6, 30))]
        try r.save(to: store)
        XCTAssertEqual(PublishRules.load(from: store), r)
    }

    func testEventLogRedactsAndPrunes() throws {
        store.log(.failure, "Failed: access_token=SECRET123", accountID: account.id)
        let e = try XCTUnwrap(try store.events().first)
        XCTAssertFalse(e.message.contains("SECRET123"))
        XCTAssertEqual(e.kind, .failure)
        XCTAssertEqual(e.accountID, account.id)
        try store.pruneEvents(now: Date().addingTimeInterval(91 * 24 * 3600))
        XCTAssertTrue(try store.events().isEmpty)
    }

    func testAttemptMessagesAreRedacted() throws {
        let j = PostJob(variationID: variation.id, accountID: account.id)
        try store.upsert(j)
        let id = try store.beginAttempt(jobID: j.id)
        try store.finishAttempt(id: id, succeeded: false, httpStatus: 400, message: "Bearer abcdefghijklmnop failed")
        XCTAssertFalse(try store.attempts(for: j.id).first?.message.contains("abcdefghijklmnop") ?? true)
    }

    func testPublisherLockIsExclusiveAcrossHandles() {
        let a = PublisherLock(directory: store.root)
        let b = PublisherLock(directory: store.root)
        XCTAssertTrue(a.tryAcquire())
        XCTAssertFalse(b.tryAcquire())
        a.release()
        XCTAssertTrue(b.tryAcquire())
        b.release()
    }
}

@MainActor
final class ApprovalGateTests: XCTestCase {
    var store: LibraryStore!
    var posting: PostingService!
    var account: Account!
    var variation: Variation!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try LibraryStore(root: dir)
        posting = PostingService(store: store, accounts: AccountService(store: store))
        let a = SourceAsset(title: "clip", relativePath: "Sources/x.mov", originalFilename: "x.mov",
                            duration: 30, pixelWidth: 1080, pixelHeight: 1920, frameRate: 30)
        try store.insert(a)
        variation = Variation(assetID: a.id, name: "V1")
        try store.insert(variation)
        account = Account(platform: .youtube, username: "chan", remoteID: "UC1", status: .connected)
        try store.upsert(account)
    }

    func testDraftsCannotBeScheduledOrSent() async throws {
        let draft = try XCTUnwrap(try posting.assign(variation: variation, to: [account], caption: "hi").first)
        XCTAssertFalse(draft.isApproved)
        try posting.schedule([draft], at: [Date()])
        XCTAssertEqual(try store.job(id: draft.id)?.status, .pending, "drafts are skipped by schedule")

        let sent = await posting.send(jobID: draft.id)
        XCTAssertEqual(sent?.status, .pending)
        XCTAssertTrue(try store.attempts(for: draft.id).isEmpty, "no attempt is made for a draft")

        try posting.approve([draft])
        try posting.schedule([draft], at: [Date()])
        XCTAssertEqual(try store.job(id: draft.id)?.status, .scheduled)
    }

    func testEditingAnApprovedPostNeedsApprovalAgain() throws {
        let j = try XCTUnwrap(try posting.assign(variation: variation, to: [account], caption: "one").first)
        try posting.approve([j])
        try posting.schedule([j], at: [Date().addingTimeInterval(3600)])
        _ = try posting.assign(variation: variation, to: [account], caption: "two")
        let back = try XCTUnwrap(try store.job(id: j.id))
        XCTAssertFalse(back.isApproved)
        XCTAssertEqual(back.status, .pending)
    }

    func testKillSwitchHoldsInsteadOfSending() async throws {
        var r = PublishRules()
        r.killSwitch = true
        try r.save(to: store)
        let j = try XCTUnwrap(try posting.assign(variation: variation, to: [account], caption: "x").first)
        try posting.approve([j])
        let out = await posting.send(jobID: j.id)
        XCTAssertEqual(out?.status, .held)
        XCTAssertTrue(try store.attempts(for: j.id).isEmpty)
    }

    func testPausedAccountHoldsInsteadOfSending() async throws {
        account.isPaused = true
        try store.upsert(account)
        let j = try XCTUnwrap(try posting.assign(variation: variation, to: [account], caption: "x").first)
        try posting.approve([j])
        let out = await posting.send(jobID: j.id)
        XCTAssertEqual(out?.status, .held)
    }

    func testNonPlatformFailuresDontTripBreaker() async throws {
        var r = PublishRules()
        r.failureLimit = 2
        try r.save(to: store)
        posting.automaticRetry = false
        let j = try XCTUnwrap(try posting.assign(variation: variation, to: [account], caption: "x").first)
        try posting.approve([j])
        // The variation was never exported, so each send fails before reaching
        // the platform; those don't count toward the breaker.
        _ = await posting.send(jobID: j.id)
        XCTAssertEqual(try store.account(id: account.id)?.consecutiveFailures, 0)
        XCTAssertEqual(try store.job(id: j.id)?.status, .failed)
    }
}
