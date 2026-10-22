import Foundation

/// All persistence for the app: one SQLite file plus a folder of media.
///
/// Layout under `root`:
///   library.sqlite
///   Sources/<asset-id>.<ext>
///   Exports/<variation-id>.mp4
///   Thumbnails/<id>.jpg
///   Backups/library-<timestamp>.sqlite
public final class LibraryStore: @unchecked Sendable {
    public let root: URL
    public let db: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// How long revisions and database backups are kept.
    public static let historyRetention: TimeInterval = 30 * 24 * 3600

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReelManager", isDirectory: true)
    }

    public init(root: URL = LibraryStore.defaultRoot) throws {
        self.root = root
        for dir in ["Sources", "Exports", "Thumbnails", "Backups"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        db = try SQLiteDatabase(path: root.appendingPathComponent("library.sqlite").path)
        try Schema.migrate(db)
        encoder.outputFormatting = .sortedKeys
    }

    /// In-memory store for tests and previews.
    public init(inMemoryWithRoot root: URL) throws {
        self.root = root
        db = try SQLiteDatabase(path: nil)
        try Schema.migrate(db)
        encoder.outputFormatting = .sortedKeys
    }

    public func url(forRelative path: String) -> URL { root.appendingPathComponent(path) }
    public var sourcesDir: URL { root.appendingPathComponent("Sources") }
    public var exportsDir: URL { root.appendingPathComponent("Exports") }
    public var thumbnailsDir: URL { root.appendingPathComponent("Thumbnails") }
    public var backupsDir: URL { root.appendingPathComponent("Backups") }

    // MARK: Assets

    public func insert(_ a: SourceAsset) throws {
        try db.run("""
            INSERT INTO assets (id, title, relative_path, original_filename, duration, pixel_width,
                pixel_height, frame_rate, imported_at, thumbnail_path) VALUES (?,?,?,?,?,?,?,?,?,?)
            """, [a.id, a.title, a.relativePath, a.originalFilename, a.duration, a.pixelWidth,
                  a.pixelHeight, a.frameRate, a.importedAt, a.thumbnailPath])
    }

    public func update(_ a: SourceAsset) throws {
        try db.run("UPDATE assets SET title = ?, thumbnail_path = ? WHERE id = ?", [a.title, a.thumbnailPath, a.id])
    }

    public func assets() throws -> [SourceAsset] {
        try db.query("SELECT * FROM assets ORDER BY imported_at DESC") { r in
            SourceAsset(id: r.uuid("id"), title: r.string("title"), relativePath: r.string("relative_path"),
                        originalFilename: r.string("original_filename"), duration: r.double("duration"),
                        pixelWidth: r.int("pixel_width"), pixelHeight: r.int("pixel_height"),
                        frameRate: r.double("frame_rate"), importedAt: r.date("imported_at"),
                        thumbnailPath: r.optString("thumbnail_path"))
        }
    }

    /// Deletes the row (cascading to variations and jobs) and the media files.
    public func deleteAsset(_ a: SourceAsset) throws {
        let vars = try variations(for: a.id)
        try db.run("DELETE FROM assets WHERE id = ?", [a.id])
        let fm = FileManager.default
        try? fm.removeItem(at: url(forRelative: a.relativePath))
        a.thumbnailPath.map { try? fm.removeItem(at: url(forRelative: $0)) }
        for v in vars {
            v.exportPath.map { try? fm.removeItem(at: url(forRelative: $0)) }
            v.thumbnailPath.map { try? fm.removeItem(at: url(forRelative: $0)) }
        }
    }

    // MARK: Variations

    public func insert(_ v: Variation) throws {
        try db.run("""
            INSERT INTO variations (id, asset_id, name, settings_json, created_at, updated_at,
                export_path, export_preset, exported_at, thumbnail_path) VALUES (?,?,?,?,?,?,?,?,?,?)
            """, [v.id, v.assetID, v.name, try json(v.settings), v.createdAt, v.updatedAt,
                  v.exportPath, v.exportPreset?.rawValue, v.exportedAt, v.thumbnailPath])
        try recordRevision(v)
    }

    /// Saves a variation and appends a revision snapshot (the "auto-backup on save").
    public func save(_ v: Variation) throws {
        try db.transaction {
            try db.run("""
                UPDATE variations SET name = ?, settings_json = ?, updated_at = ?, export_path = ?,
                    export_preset = ?, exported_at = ?, thumbnail_path = ? WHERE id = ?
                """, [v.name, try json(v.settings), v.updatedAt, v.exportPath, v.exportPreset?.rawValue,
                      v.exportedAt, v.thumbnailPath, v.id])
            try recordRevision(v)
        }
    }

    public func variations(for assetID: UUID) throws -> [Variation] {
        try db.query("SELECT * FROM variations WHERE asset_id = ? ORDER BY created_at", [assetID], map: mapVariation)
    }

    public func allVariations() throws -> [Variation] {
        try db.query("SELECT * FROM variations ORDER BY created_at", map: mapVariation)
    }

    public func variation(id: UUID) throws -> Variation? {
        try db.query("SELECT * FROM variations WHERE id = ?", [id], map: mapVariation).first
    }

    public func deleteVariation(_ v: Variation) throws {
        try db.run("DELETE FROM variations WHERE id = ?", [v.id])
        v.exportPath.map { try? FileManager.default.removeItem(at: url(forRelative: $0)) }
    }

    private func mapVariation(_ r: Row) throws -> Variation {
        Variation(id: r.uuid("id"), assetID: r.uuid("asset_id"), name: r.string("name"),
                  settings: try decoder.decode(EditSettings.self, from: Data(r.string("settings_json").utf8)),
                  createdAt: r.date("created_at"), updatedAt: r.date("updated_at"),
                  exportPath: r.optString("export_path"),
                  exportPreset: r.optString("export_preset").flatMap(ExportPreset.init(rawValue:)),
                  exportedAt: r.optDate("exported_at"), thumbnailPath: r.optString("thumbnail_path"))
    }

    // MARK: Version history

    private func recordRevision(_ v: Variation) throws {
        // Skip if identical to the latest revision, so repeated saves don't pile up.
        let latest = try revisions(for: v.id, limit: 1).first
        if latest?.settings == v.settings { return }
        try db.run("INSERT INTO variation_revisions (variation_id, settings_json, saved_at) VALUES (?,?,?)",
                   [v.id, try json(v.settings), Date()])
    }

    public func revisions(for variationID: UUID, limit: Int = 200) throws -> [VariationRevision] {
        try db.query("""
            SELECT * FROM variation_revisions WHERE variation_id = ? ORDER BY saved_at DESC, id DESC LIMIT ?
            """, [variationID, limit]) { r in
            VariationRevision(id: r.int64("id"), variationID: r.uuid("variation_id"),
                              settings: try decoder.decode(EditSettings.self, from: Data(r.string("settings_json").utf8)),
                              savedAt: r.date("saved_at"))
        }
    }

    /// Drops revisions and database backups older than 30 days.
    public func pruneHistory(now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-Self.historyRetention)
        try db.run("DELETE FROM variation_revisions WHERE saved_at < ?", [cutoff])
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for f in files {
            let created = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            if created < cutoff { try? fm.removeItem(at: f) }
        }
    }

    /// Copies the database to Backups/ using SQLite's VACUUM INTO (consistent
    /// snapshot even while the WAL is active). Called once per app launch and
    /// on explicit saves at most hourly.
    public func backupDatabase(now: Date = Date()) throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dest = backupsDir.appendingPathComponent("library-\(f.string(from: now)).sqlite")
        try? FileManager.default.removeItem(at: dest)
        try db.run("VACUUM INTO ?", [dest.path])
        return dest
    }

    // MARK: Accounts

    public func upsert(_ a: Account) throws {
        try db.run("""
            INSERT INTO accounts (id, platform, username, remote_id, status, status_message, last_sync_at, created_at,
                paused, pause_reason, consecutive_failures, token_expires_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET username = excluded.username, remote_id = excluded.remote_id,
                status = excluded.status, status_message = excluded.status_message,
                last_sync_at = excluded.last_sync_at, paused = excluded.paused,
                pause_reason = excluded.pause_reason, consecutive_failures = excluded.consecutive_failures,
                token_expires_at = excluded.token_expires_at
            """, [a.id, a.platform.rawValue, a.username, a.remoteID, a.status.rawValue, a.statusMessage,
                  a.lastSyncAt, a.createdAt, a.isPaused, a.pauseReason, a.consecutiveFailures, a.tokenExpiresAt])
    }

    public func accounts() throws -> [Account] {
        try db.query("SELECT * FROM accounts ORDER BY platform, username", map: mapAccount)
    }

    public func account(id: UUID) throws -> Account? {
        try db.query("SELECT * FROM accounts WHERE id = ?", [id], map: mapAccount).first
    }

    private func mapAccount(_ r: Row) -> Account {
        Account(id: r.uuid("id"), platform: Platform(rawValue: r.string("platform")) ?? .instagram,
                username: r.string("username"), remoteID: r.optString("remote_id"),
                status: AccountStatus(rawValue: r.string("status")) ?? .error,
                statusMessage: r.optString("status_message"), lastSyncAt: r.optDate("last_sync_at"),
                createdAt: r.date("created_at"), isPaused: r.bool("paused"),
                pauseReason: r.optString("pause_reason"), consecutiveFailures: r.int("consecutive_failures"),
                tokenExpiresAt: r.optDate("token_expires_at"))
    }

    public func deleteAccount(_ a: Account) throws {
        try db.run("DELETE FROM accounts WHERE id = ?", [a.id])
    }

    // MARK: Post jobs

    public func upsert(_ j: PostJob) throws {
        try db.run("""
            INSERT INTO post_jobs (id, variation_id, account_id, caption, title, privacy, status, scheduled_at,
                next_attempt_at, attempt_count, remote_post_id, remote_url, last_error, batch_id, created_at,
                updated_at, posted_at, overlay_json, approved_at, checkpoint_json, hold_reason)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET caption = excluded.caption, title = excluded.title,
                privacy = excluded.privacy, status = excluded.status, overlay_json = excluded.overlay_json,
                scheduled_at = excluded.scheduled_at, next_attempt_at = excluded.next_attempt_at,
                attempt_count = excluded.attempt_count, remote_post_id = excluded.remote_post_id,
                remote_url = excluded.remote_url, last_error = excluded.last_error,
                batch_id = excluded.batch_id, updated_at = excluded.updated_at, posted_at = excluded.posted_at,
                approved_at = excluded.approved_at, checkpoint_json = excluded.checkpoint_json,
                hold_reason = excluded.hold_reason
            """, [j.id, j.variationID, j.accountID, j.caption, j.title, j.privacy.rawValue, j.status.rawValue, j.scheduledAt, j.nextAttemptAt,
                  j.attemptCount, j.remotePostID, j.remoteURL, j.lastError, j.batchID, j.createdAt,
                  j.updatedAt, j.postedAt, j.overlay.flatMap { try? json($0) }, j.approvedAt,
                  j.checkpoint.flatMap { try? json($0) }, j.holdReason])
    }

    public func jobs() throws -> [PostJob] {
        try db.query("SELECT * FROM post_jobs ORDER BY created_at DESC", map: mapJob)
    }

    public func job(id: UUID) throws -> PostJob? {
        try db.query("SELECT * FROM post_jobs WHERE id = ?", [id], map: mapJob).first
    }

    /// Approved jobs that are ready to run at `now`: scheduled or held posts
    /// whose time has come, and failed posts whose retry time has passed.
    /// Drafts are never returned.
    public func dueJobs(now: Date = Date()) throws -> [PostJob] {
        try db.query("""
            SELECT * FROM post_jobs
            WHERE approved_at IS NOT NULL AND (
                (status IN ('scheduled', 'held') AND COALESCE(next_attempt_at, scheduled_at) <= ?)
                OR (status = 'failed' AND next_attempt_at IS NOT NULL AND next_attempt_at <= ?))
            ORDER BY COALESCE(next_attempt_at, scheduled_at)
            """, [now, now], map: mapJob)
    }

    /// Posts that went out (or are going out) for an account since `since`.
    /// Used for daily caps.
    public func postedCount(accountID: UUID? = nil, since: Date) throws -> Int {
        if let accountID {
            return try db.query("SELECT COUNT(*) AS n FROM post_jobs WHERE account_id = ? AND posted_at >= ?",
                                [accountID, since]) { $0.int("n") }.first ?? 0
        }
        return try db.query("SELECT COUNT(*) AS n FROM post_jobs WHERE posted_at >= ?", [since]) { $0.int("n") }.first ?? 0
    }

    /// When the account last published, for the minimum gap between posts.
    public func lastPostedAt(accountID: UUID? = nil) throws -> Date? {
        if let accountID {
            return try db.query("SELECT MAX(posted_at) AS t FROM post_jobs WHERE account_id = ?", [accountID]) { $0.optDate("t") }.first ?? nil
        }
        return try db.query("SELECT MAX(posted_at) AS t FROM post_jobs") { $0.optDate("t") }.first ?? nil
    }

    /// Atomically marks a job as publishing. Returns false if another send
    /// (in this process or the background publisher) already has it, or it
    /// is already posted or cancelled. This is the double-post guard.
    public func claim(jobID: UUID, now: Date = Date()) throws -> Bool {
        try db.run("""
            UPDATE post_jobs SET status = 'uploading', updated_at = ?
            WHERE id = ? AND approved_at IS NOT NULL AND status NOT IN ('uploading', 'processing', 'posted', 'cancelled')
            """, [now, jobID]) == 1
    }

    /// Saves only the checkpoint column, so it can be written mid-upload.
    public func saveCheckpoint(_ cp: PublishCheckpoint?, jobID: UUID) throws {
        try db.run("UPDATE post_jobs SET checkpoint_json = ?, updated_at = ? WHERE id = ?", [cp.flatMap { try? json($0) }, Date(), jobID])
    }

    public func deleteJob(_ j: PostJob) throws {
        try db.run("DELETE FROM post_jobs WHERE id = ?", [j.id])
    }

    private func mapJob(_ r: Row) -> PostJob {
        PostJob(id: r.uuid("id"), variationID: r.uuid("variation_id"), accountID: r.uuid("account_id"),
                caption: r.string("caption"), title: r.string("title"),
                privacy: PostPrivacy(rawValue: r.string("privacy")) ?? .publicAudience,
                overlay: r.optString("overlay_json").flatMap { try? decoder.decode(TextOverlay.self, from: Data($0.utf8)) },
                status: PostStatus(rawValue: r.string("status")) ?? .failed,
                scheduledAt: r.optDate("scheduled_at"), nextAttemptAt: r.optDate("next_attempt_at"),
                attemptCount: r.int("attempt_count"), remotePostID: r.optString("remote_post_id"),
                remoteURL: r.optString("remote_url"), lastError: r.optString("last_error"),
                batchID: r.optUUID("batch_id"),
                approvedAt: r.optDate("approved_at"),
                checkpoint: r.optString("checkpoint_json").flatMap { try? decoder.decode(PublishCheckpoint.self, from: Data($0.utf8)) },
                holdReason: r.optString("hold_reason"),
                createdAt: r.date("created_at"), updatedAt: r.date("updated_at"), postedAt: r.optDate("posted_at"))
    }

    /// Jobs left mid-upload by a quit or crash go back to failed so they can
    /// be retried. Their checkpoint is kept, so the retry first asks the
    /// platform whether the post already went out. Only jobs untouched for
    /// `staleAfter` are reset, so a send still running in the other process
    /// isn't disturbed.
    public func resetInterruptedJobs(now: Date = Date(), staleAfter: TimeInterval = 0) throws {
        try db.run("""
            UPDATE post_jobs SET status = 'failed', last_error = 'Interrupted (the app was closed during upload).',
                next_attempt_at = ?, updated_at = ? WHERE status IN ('uploading', 'processing') AND updated_at <= ?
            """, [now, now, now.addingTimeInterval(-staleAfter)])
    }

    /// Next time the scheduler has something to do, if anything.
    public func nextWakeDate() throws -> Date? {
        try db.query("""
            SELECT MIN(t) AS t FROM (
                SELECT COALESCE(next_attempt_at, scheduled_at) AS t FROM post_jobs
                    WHERE status IN ('scheduled', 'held') AND approved_at IS NOT NULL
                UNION ALL
                SELECT next_attempt_at AS t FROM post_jobs WHERE status = 'failed' AND next_attempt_at IS NOT NULL)
            """) { $0.optDate("t") }.first ?? nil
    }

    // MARK: Stats

    public func upsert(_ s: PostStats) throws {
        try db.run("""
            INSERT INTO post_stats (job_id, views, likes, comments, shares, reach, fetched_at, error)
            VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(job_id) DO UPDATE SET views = excluded.views, likes = excluded.likes,
                comments = excluded.comments, shares = excluded.shares, reach = excluded.reach,
                fetched_at = excluded.fetched_at, error = excluded.error
            """, [s.jobID, s.views, s.likes, s.comments, s.shares, s.reach, s.fetchedAt, s.error])
    }

    public func stats() throws -> [UUID: PostStats] {
        let rows = try db.query("SELECT * FROM post_stats") { r in
            PostStats(jobID: r.uuid("job_id"), views: r.optInt("views"), likes: r.optInt("likes"),
                      comments: r.optInt("comments"), shares: r.optInt("shares"), reach: r.optInt("reach"),
                      fetchedAt: r.date("fetched_at"), error: r.optString("error"))
        }
        return Dictionary(rows.map { ($0.jobID, $0) }, uniquingKeysWith: { $1 })
    }

    // MARK: Attempts

    @discardableResult
    public func beginAttempt(jobID: UUID, at date: Date = Date()) throws -> Int64 {
        try db.insert("INSERT INTO post_attempts (job_id, started_at) VALUES (?, ?)", [jobID, date])
    }

    public func finishAttempt(id: Int64, succeeded: Bool, httpStatus: Int?, message: String, at date: Date = Date()) throws {
        try db.run("UPDATE post_attempts SET finished_at = ?, succeeded = ?, http_status = ?, message = ? WHERE id = ?",
                   [date, succeeded, httpStatus, Redactor.redact(message), id])
    }

    public func attempts(for jobID: UUID) throws -> [PostAttempt] {
        try db.query("SELECT * FROM post_attempts WHERE job_id = ? ORDER BY started_at DESC", [jobID]) { r in
            PostAttempt(id: r.int64("id"), jobID: r.uuid("job_id"), startedAt: r.date("started_at"),
                        finishedAt: r.optDate("finished_at"), succeeded: r.bool("succeeded"),
                        httpStatus: r.optInt("http_status"), message: r.string("message"))
        }
    }

    // MARK: Settings

    public func setting(_ key: String) throws -> String? {
        try db.query("SELECT value FROM settings WHERE key = ?", [key]) { $0.string("value") }.first
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        if let value {
            try db.run("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       [key, value])
        } else {
            try db.run("DELETE FROM settings WHERE key = ?", [key])
        }
    }

    public func setting<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let s = try? setting(key) else { return nil }
        return try? decoder.decode(T.self, from: Data(s.utf8))
    }

    public func setSetting<T: Encodable>(_ key: String, encoding value: T) throws {
        try setSetting(key, try json(value))
    }

    // MARK: Event log

    public func log(_ kind: AppEvent.Kind, _ message: String, jobID: UUID? = nil, accountID: UUID? = nil,
                    at date: Date = Date()) {
        _ = try? db.insert("INSERT INTO events (at, kind, message, job_id, account_id) VALUES (?,?,?,?,?)",
                           [date, kind.rawValue, Redactor.redact(message), jobID, accountID])
    }

    public func events(limit: Int = 500, since: Date? = nil) throws -> [AppEvent] {
        try db.query("SELECT * FROM events WHERE at >= ? ORDER BY at DESC, id DESC LIMIT ?",
                     [since ?? Date.distantPast, limit]) { r in
            AppEvent(id: r.int64("id"), at: r.date("at"), kind: AppEvent.Kind(rawValue: r.string("kind")) ?? .system,
                     message: r.string("message"), jobID: r.optUUID("job_id"), accountID: r.optUUID("account_id"))
        }
    }

    /// Keeps the log to 90 days.
    public func pruneEvents(now: Date = Date()) throws {
        try db.run("DELETE FROM events WHERE at < ?", [now.addingTimeInterval(-90 * 24 * 3600)])
    }

    // MARK: Helpers

    public func asset(id: UUID) throws -> SourceAsset? {
        try assets().first { $0.id == id }
    }

    private func json<T: Encodable>(_ s: T) throws -> String {
        String(decoding: try encoder.encode(s), as: UTF8.self)
    }
}
