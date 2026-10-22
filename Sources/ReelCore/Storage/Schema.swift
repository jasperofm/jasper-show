import Foundation

/// Ordered migrations. Append only; never edit a shipped migration.
enum Schema {
    static let migrations: [String] = [
        // 1: Phase 1 tables. Columns used only by the Phase 2 scheduler
        // (scheduled_at, next_attempt_at, batch_id) are created now so the
        // scheduler needs no migration.
        """
        CREATE TABLE assets (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            original_filename TEXT NOT NULL,
            duration REAL NOT NULL,
            pixel_width INTEGER NOT NULL,
            pixel_height INTEGER NOT NULL,
            frame_rate REAL NOT NULL,
            imported_at REAL NOT NULL,
            thumbnail_path TEXT
        );

        CREATE TABLE variations (
            id TEXT PRIMARY KEY,
            asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            settings_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            export_path TEXT,
            export_preset TEXT,
            exported_at REAL,
            thumbnail_path TEXT
        );
        CREATE INDEX idx_variations_asset ON variations(asset_id);

        CREATE TABLE variation_revisions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            variation_id TEXT NOT NULL REFERENCES variations(id) ON DELETE CASCADE,
            settings_json TEXT NOT NULL,
            saved_at REAL NOT NULL
        );
        CREATE INDEX idx_revisions_variation ON variation_revisions(variation_id, saved_at);

        CREATE TABLE accounts (
            id TEXT PRIMARY KEY,
            platform TEXT NOT NULL,
            username TEXT NOT NULL,
            remote_id TEXT,
            status TEXT NOT NULL,
            status_message TEXT,
            last_sync_at REAL,
            created_at REAL NOT NULL
        );

        CREATE TABLE post_jobs (
            id TEXT PRIMARY KEY,
            variation_id TEXT NOT NULL REFERENCES variations(id) ON DELETE CASCADE,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            caption TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            privacy TEXT NOT NULL DEFAULT 'publicAudience',
            status TEXT NOT NULL,
            scheduled_at REAL,
            next_attempt_at REAL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            remote_post_id TEXT,
            remote_url TEXT,
            last_error TEXT,
            batch_id TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            posted_at REAL
        );
        CREATE INDEX idx_jobs_status_due ON post_jobs(status, scheduled_at, next_attempt_at);
        CREATE INDEX idx_jobs_variation ON post_jobs(variation_id);

        CREATE TABLE post_attempts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id TEXT NOT NULL REFERENCES post_jobs(id) ON DELETE CASCADE,
            started_at REAL NOT NULL,
            finished_at REAL,
            succeeded INTEGER NOT NULL DEFAULT 0,
            http_status INTEGER,
            message TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX idx_attempts_job ON post_attempts(job_id, started_at);
        """,
        // 2: Analytics snapshots, one row per post (latest numbers win).
        """
        CREATE TABLE post_stats (
            job_id TEXT PRIMARY KEY REFERENCES post_jobs(id) ON DELETE CASCADE,
            views INTEGER,
            likes INTEGER,
            comments INTEGER,
            shares INTEGER,
            reach INTEGER,
            fetched_at REAL NOT NULL,
            error TEXT
        );
        ALTER TABLE post_jobs ADD COLUMN overlay_json TEXT;
        """,
        // 3: Approval gate, resumable publishing, account pauses, settings, audit log.
        """
        ALTER TABLE post_jobs ADD COLUMN approved_at REAL;
        ALTER TABLE post_jobs ADD COLUMN checkpoint_json TEXT;
        ALTER TABLE post_jobs ADD COLUMN hold_reason TEXT;
        UPDATE post_jobs SET approved_at = updated_at WHERE status <> 'pending';
        ALTER TABLE accounts ADD COLUMN paused INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE accounts ADD COLUMN pause_reason TEXT;
        ALTER TABLE accounts ADD COLUMN consecutive_failures INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE accounts ADD COLUMN token_expires_at REAL;
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            at REAL NOT NULL,
            kind TEXT NOT NULL,
            message TEXT NOT NULL,
            job_id TEXT,
            account_id TEXT
        );
        CREATE INDEX idx_events_at ON events(at);
        """,
    ]

    static func migrate(_ db: SQLiteDatabase) throws {
        let current = try db.query("PRAGMA user_version") { $0.int("user_version") }.first ?? 0
        guard current < migrations.count else { return }
        for version in current..<migrations.count {
            try db.transaction {
                try db.execute(migrations[version])
                try db.execute("PRAGMA user_version = \(version + 1)")
            }
        }
    }
}
