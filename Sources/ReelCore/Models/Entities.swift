import Foundation

/// An imported original video. The file is copied into the app's library folder
/// so the source survives the user moving or deleting their copy.
public struct SourceAsset: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    /// Path relative to the library root.
    public var relativePath: String
    public var originalFilename: String
    public var duration: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var frameRate: Double
    public var importedAt: Date
    /// Relative path to a cached JPEG thumbnail.
    public var thumbnailPath: String?

    public init(id: UUID = UUID(), title: String, relativePath: String, originalFilename: String,
                duration: Double, pixelWidth: Int, pixelHeight: Int, frameRate: Double,
                importedAt: Date = Date(), thumbnailPath: String? = nil) {
        self.id = id; self.title = title; self.relativePath = relativePath
        self.originalFilename = originalFilename; self.duration = duration
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.frameRate = frameRate; self.importedAt = importedAt; self.thumbnailPath = thumbnailPath
    }
}

/// An edited version of a source asset.
public struct Variation: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var assetID: UUID
    public var name: String
    public var settings: EditSettings
    public var createdAt: Date
    public var updatedAt: Date
    /// Relative path of the last rendered file, if any.
    public var exportPath: String?
    public var exportPreset: ExportPreset?
    public var exportedAt: Date?
    public var thumbnailPath: String?

    public init(id: UUID = UUID(), assetID: UUID, name: String, settings: EditSettings = .identity,
                createdAt: Date = Date(), updatedAt: Date = Date(), exportPath: String? = nil,
                exportPreset: ExportPreset? = nil, exportedAt: Date? = nil, thumbnailPath: String? = nil) {
        self.id = id; self.assetID = assetID; self.name = name; self.settings = settings
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.exportPath = exportPath
        self.exportPreset = exportPreset; self.exportedAt = exportedAt; self.thumbnailPath = thumbnailPath
    }

    /// True when the settings changed after the last export.
    public var needsExport: Bool {
        guard let exportedAt else { return true }
        return updatedAt > exportedAt
    }
}

/// Snapshot of a variation's settings, written on every save. Pruned after 30 days.
public struct VariationRevision: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var variationID: UUID
    public var settings: EditSettings
    public var savedAt: Date
}

public enum Platform: String, Codable, CaseIterable, Identifiable, Sendable {
    case instagram, facebook, tiktok, youtube
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .instagram: return "Instagram"
        case .facebook: return "Facebook"
        case .tiktok: return "TikTok"
        case .youtube: return "YouTube"
        }
    }

    /// SF Symbol used in the sidebar. (Brand logos aren't bundled.)
    public var symbolName: String {
        switch self {
        case .instagram: return "camera.circle"
        case .facebook: return "f.square"
        case .tiktok: return "music.note"
        case .youtube: return "play.rectangle"
        }
    }
}

public enum AccountStatus: String, Codable, Sendable {
    case connected, pending, error, disconnected
}

/// A connected social account. Tokens are NOT stored here; they live in the
/// Keychain under `keychainKey`.
public struct Account: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var platform: Platform
    public var username: String
    /// Platform-side identifier (IG user id, TikTok open_id, YouTube channel id).
    public var remoteID: String?
    public var status: AccountStatus
    public var statusMessage: String?
    public var lastSyncAt: Date?
    public var createdAt: Date
    /// Paused accounts are skipped by the publisher until resumed.
    public var isPaused: Bool
    public var pauseReason: String?
    /// Failures in a row; reset by a success. Drives the auto-pause breaker.
    public var consecutiveFailures: Int
    /// When the stored sign-in expires, if the platform says.
    public var tokenExpiresAt: Date?

    public init(id: UUID = UUID(), platform: Platform, username: String, remoteID: String? = nil,
                status: AccountStatus = .pending, statusMessage: String? = nil,
                lastSyncAt: Date? = nil, createdAt: Date = Date(), isPaused: Bool = false,
                pauseReason: String? = nil, consecutiveFailures: Int = 0, tokenExpiresAt: Date? = nil) {
        self.id = id; self.platform = platform; self.username = username; self.remoteID = remoteID
        self.status = status; self.statusMessage = statusMessage
        self.lastSyncAt = lastSyncAt; self.createdAt = createdAt
        self.isPaused = isPaused; self.pauseReason = pauseReason
        self.consecutiveFailures = consecutiveFailures; self.tokenExpiresAt = tokenExpiresAt
    }

    /// Connected and not paused.
    public var canPublish: Bool { status == .connected && !isPaused }

    public var keychainKey: String { "account.\(id.uuidString)" }

    /// "@name" for social handles, plain name for Facebook Pages and channels.
    public var handle: String {
        platform == .instagram || platform == .tiktok ? "@\(username)" : username
    }
}

/// Post lifecycle. A pending job is a *draft* until `PostJob.approvedAt` is
/// set; only approved jobs can be scheduled or published.
///
///   pending (draft → approved) → scheduled → uploading → processing → posted
///                               ↘ held (rules/pauses) ↗     ↘ failed → (retry) ↗
public enum PostStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case scheduled
    /// Publishing: sending the file.
    case uploading
    /// Publishing: platform accepted it and is processing.
    case processing
    case posted
    case failed
    case cancelled
    /// Due, but a rule, pause or system condition is holding it back.
    case held

    public var isTerminal: Bool { self == .posted || self == .cancelled }
    public var isActive: Bool { self == .uploading || self == .processing }
}

/// One variation going to one account.
public struct PostJob: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var variationID: UUID
    public var accountID: UUID
    public var caption: String
    /// YouTube title (other platforms ignore it). Empty = variation name.
    public var title: String
    public var privacy: PostPrivacy
    /// On-screen text for this account's copy. When set, the video is
    /// rendered again with this text before upload.
    public var overlay: TextOverlay?
    public var status: PostStatus
    /// Phase 2 scheduler: earliest time the job may run. Nil = run on demand.
    public var scheduledAt: Date?
    /// Phase 2 retry: when the next automatic attempt is due.
    public var nextAttemptAt: Date?
    public var attemptCount: Int
    public var remotePostID: String?
    public var remoteURL: String?
    public var lastError: String?
    /// Groups jobs created together (Phase 2 batch / staggered queue).
    public var batchID: UUID?
    /// Set when the user approves the post. Nil = draft. Nothing is
    /// scheduled or published without it.
    public var approvedAt: Date?
    /// Publish progress saved after each step, so a restart resumes
    /// instead of posting twice.
    public var checkpoint: PublishCheckpoint?
    /// Why the post is held, when status is `.held`.
    public var holdReason: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var postedAt: Date?

    public init(id: UUID = UUID(), variationID: UUID, accountID: UUID, caption: String = "",
                title: String = "", privacy: PostPrivacy = .publicAudience, overlay: TextOverlay? = nil,
                status: PostStatus = .pending, scheduledAt: Date? = nil, nextAttemptAt: Date? = nil,
                attemptCount: Int = 0, remotePostID: String? = nil, remoteURL: String? = nil,
                lastError: String? = nil, batchID: UUID? = nil, approvedAt: Date? = nil,
                checkpoint: PublishCheckpoint? = nil, holdReason: String? = nil, createdAt: Date = Date(),
                updatedAt: Date = Date(), postedAt: Date? = nil) {
        self.id = id; self.variationID = variationID; self.accountID = accountID
        self.caption = caption; self.title = title; self.privacy = privacy; self.overlay = overlay; self.status = status; self.scheduledAt = scheduledAt
        self.nextAttemptAt = nextAttemptAt; self.attemptCount = attemptCount
        self.remotePostID = remotePostID; self.remoteURL = remoteURL; self.lastError = lastError
        self.batchID = batchID; self.approvedAt = approvedAt; self.checkpoint = checkpoint
        self.holdReason = holdReason; self.createdAt = createdAt; self.updatedAt = updatedAt; self.postedAt = postedAt
    }
}

extension PostJob {
    public var isApproved: Bool { approvedAt != nil }

    /// The state names from the product spec, for display.
    public var stateLabel: String {
        switch status {
        case .pending: return isApproved ? "Approved" : "Draft"
        case .scheduled: return "Scheduled"
        case .uploading, .processing: return "Publishing"
        case .posted: return "Published"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .held: return "Held"
        }
    }
}

/// Where a publish got to. Saved before each next step.
public struct PublishCheckpoint: Codable, Hashable, Sendable {
    public enum Step: String, Codable, Sendable {
        /// Platform-side container/upload session exists (id in `remoteID`).
        case created
        /// File fully uploaded.
        case uploaded
        /// Publish call sent; waiting for the platform to confirm.
        case publishRequested

        public var label: String {
            switch self {
            case .created: return "upload started"
            case .uploaded: return "uploaded"
            case .publishRequested: return "publish requested"
            }
        }
    }
    public var step: Step
    /// Container / publish / video id the platform gave us.
    public var remoteID: String
    public var savedAt: Date

    public init(step: Step, remoteID: String, savedAt: Date = Date()) {
        self.step = step; self.remoteID = remoteID; self.savedAt = savedAt
    }
}

/// Audit log entry.
public struct AppEvent: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case publish, failure, pause, resume, hold, approval, schedule, auth, system
    }
    public var id: Int64
    public var at: Date
    public var kind: Kind
    public var message: String
    public var jobID: UUID?
    public var accountID: UUID?
}

/// Latest engagement numbers for a posted job, read from the platform's API.
/// Nil means the platform doesn't report that number (or not to this app).
public struct PostStats: Identifiable, Equatable, Sendable {
    public var id: UUID { jobID }
    public var jobID: UUID
    public var views: Int?
    public var likes: Int?
    public var comments: Int?
    public var shares: Int?
    public var reach: Int?
    public var fetchedAt: Date
    public var error: String?

    public init(jobID: UUID, views: Int? = nil, likes: Int? = nil, comments: Int? = nil, shares: Int? = nil,
                reach: Int? = nil, fetchedAt: Date = Date(), error: String? = nil) {
        self.jobID = jobID; self.views = views; self.likes = likes; self.comments = comments
        self.shares = shares; self.reach = reach; self.fetchedAt = fetchedAt; self.error = error
    }

    /// Likes + comments + shares, the simple engagement total shown in the dashboard.
    public var engagement: Int { (likes ?? 0) + (comments ?? 0) + (shares ?? 0) }
}

/// Append-only log of every attempt, success or failure.
public struct PostAttempt: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var jobID: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    public var succeeded: Bool
    public var httpStatus: Int?
    public var message: String
}
