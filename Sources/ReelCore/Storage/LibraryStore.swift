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
            INSERT INTO accounts (id, platform, username, remote_id, status, status_message, last_sync_at, created_at)
            VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET username = excluded.username, remote_id = excluded.remote_id,
                status = excluded.status, status_message = excluded.status_message,
                last_sync_at = excluded.last_sync_at
            """, [a.id, a.platform.rawValue, a.username, a.remoteID, a.status.rawValue, a.statusMessage,
                  a.lastSyncAt, a.createdAt])
    }

    public func accounts() throws -> [Account] {
        try db.query("SELECT * FROM accounts ORDER BY platform, username") { r in
            Account(id: r.uuid("id"), platform: Platform(rawValue: r.string("platform")) ?? .instagram,
                    username: r.string("username"), remoteID: r.optString("remote_id"),
                    status: AccountStatus(rawValue: r.string("status")) ?? .error,
                    statusMessage: r.optString("status_message"), lastSyncAt: r.optDate("last_sync_at"),
                    createdAt: r.date("created_at"))
        }
    }

    public func deleteAccount(_ a: Account) throws {
        try db.run("DELETE FROM accounts WHERE id = ?", [a.id])
    }

    // MARK: Post jobs

    public func upsert(_ j: PostJob) throws {
        try db.run("""
            INSERT INTO post_jobs (id, variation_id, account_id, caption, title, privacy, status, scheduled_at,
                next_attempt_at, attempt_count, remote_post_id, remote_url, last_error, batch_id, created_at,
                updated_at, posted_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET caption = excluded.caption, title = excluded.title,
                privacy = excluded.privacy, status = excluded.status,
                scheduled_at = excluded.scheduled_at, next_attempt_at = excluded.next_attempt_at,
                attempt_count = excluded.attempt_count, remote_post_id = excluded.remote_post_id,
                remote_url = excluded.remote_url, last_error = excluded.last_error,
                batch_id = excluded.batch_id, updated_at = excluded.updated_at, posted_at = excluded.posted_at
            """, [j.id, j.variationID, j.accountID, j.caption, j.title, j.privacy.rawValue, j.status.rawValue, j.scheduledAt, j.nextAttemptAt,
                  j.attemptCount, j.remotePostID, j.remoteURL, j.lastError, j.batchID, j.createdAt,
                  j.updatedAt, j.postedAt])
    }

    public func jobs() throws -> [PostJob] {
        try db.query("SELECT * FROM post_jobs ORDER BY created_at DESC", map: mapJob)
    }

    public func job(id: UUID) throws -> PostJob? {
        try db.query("SELECT * FROM post_jobs WHERE id = ?", [id], map: mapJob).first
    }

    /// Jobs that are ready to run at `now`. Used by Phase 2's scheduler; Phase 1
    /// never sets scheduled_at/next_attempt_at so only manual sends happen.
    public func dueJobs(now: Date = Date()) throws -> [PostJob] {
        try db.query("""
            SELECT * FROM post_jobs
            WHERE (status = 'scheduled' AND scheduled_at <= ?)
               OR (status = 'failed' AND next_attempt_at IS NOT NULL AND next_attempt_at <= ?)
            ORDER BY COALESCE(next_attempt_at, scheduled_at)
            """, [now, now], map: mapJob)
    }

    public func deleteJob(_ j: PostJob) throws {
        try db.run("DELETE FROM post_jobs WHERE id = ?", [j.id])
    }

    private func mapJob(_ r: Row) -> PostJob {
        PostJob(id: r.uuid("id"), variationID: r.uuid("variation_id"), accountID: r.uuid("account_id"),
                caption: r.string("caption"), title: r.string("title"),
                privacy: PostPrivacy(rawValue: r.string("privacy")) ?? .publicAudience, status: PostStatus(rawValue: r.string("status")) ?? .failed,
                scheduledAt: r.optDate("scheduled_at"), nextAttemptAt: r.optDate("next_attempt_at"),
                attemptCount: r.int("attempt_count"), remotePostID: r.optString("remote_post_id"),
                remoteURL: r.optString("remote_url"), lastError: r.optString("last_error"),
                batchID: r.optUUID("batch_id"), createdAt: r.date("created_at"),
                updatedAt: r.date("updated_at"), postedAt: r.optDate("posted_at"))
    }

    // MARK: Attempts

    @discardableResult
    public func beginAttempt(jobID: UUID, at date: Date = Date()) throws -> Int64 {
        try db.insert("INSERT INTO post_attempts (job_id, started_at) VALUES (?, ?)", [jobID, date])
    }

    public func finishAttempt(id: Int64, succeeded: Bool, httpStatus: Int?, message: String, at date: Date = Date()) throws {
        try db.run("UPDATE post_attempts SET finished_at = ?, succeeded = ?, http_status = ?, message = ? WHERE id = ?",
                   [date, succeeded, httpStatus, message, id])
    }

    public func attempts(for jobID: UUID) throws -> [PostAttempt] {
        try db.query("SELECT * FROM post_attempts WHERE job_id = ? ORDER BY started_at DESC", [jobID]) { r in
            PostAttempt(id: r.int64("id"), jobID: r.uuid("job_id"), startedAt: r.date("started_at"),
                        finishedAt: r.optDate("finished_at"), succeeded: r.bool("succeeded"),
                        httpStatus: r.optInt("http_status"), message: r.string("message"))
        }
    }

    // MARK: Helpers

    private func json(_ s: EditSettings) throws -> String {
        String(decoding: try encoder.encode(s), as: UTF8.self)
    }
}
