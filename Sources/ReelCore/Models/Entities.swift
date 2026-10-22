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
    case instagram, tiktok, youtube
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .instagram: return "Instagram"
        case .tiktok: return "TikTok"
        case .youtube: return "YouTube"
        }
    }

    /// SF Symbol used in the sidebar. (Brand logos aren't bundled.)
    public var symbolName: String {
        switch self {
        case .instagram: return "camera.circle"
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

    public init(id: UUID = UUID(), platform: Platform, username: String, remoteID: String? = nil,
                status: AccountStatus = .pending, statusMessage: String? = nil,
                lastSyncAt: Date? = nil, createdAt: Date = Date()) {
        self.id = id; self.platform = platform; self.username = username; self.remoteID = remoteID
        self.status = status; self.statusMessage = statusMessage
        self.lastSyncAt = lastSyncAt; self.createdAt = createdAt
    }

    public var keychainKey: String { "account.\(id.uuidString)" }
}

public enum PostStatus: String, Codable, CaseIterable, Sendable {
    /// Assigned but not yet sent. Phase 2: has a `scheduledAt` the scheduler waits for.
    case pending
    case scheduled
    case uploading
    /// Upload accepted, platform still processing.
    case processing
    case posted
    /// Last attempt failed; may be retried automatically (Phase 2) or manually.
    case failed
    case cancelled

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
    public var createdAt: Date
    public var updatedAt: Date
    public var postedAt: Date?

    public init(id: UUID = UUID(), variationID: UUID, accountID: UUID, caption: String = "",
                title: String = "", privacy: PostPrivacy = .publicAudience, status: PostStatus = .pending, scheduledAt: Date? = nil, nextAttemptAt: Date? = nil,
                attemptCount: Int = 0, remotePostID: String? = nil, remoteURL: String? = nil,
                lastError: String? = nil, batchID: UUID? = nil, createdAt: Date = Date(),
                updatedAt: Date = Date(), postedAt: Date? = nil) {
        self.id = id; self.variationID = variationID; self.accountID = accountID
        self.caption = caption; self.title = title; self.privacy = privacy; self.status = status; self.scheduledAt = scheduledAt
        self.nextAttemptAt = nextAttemptAt; self.attemptCount = attemptCount
        self.remotePostID = remotePostID; self.remoteURL = remoteURL; self.lastError = lastError
        self.batchID = batchID; self.createdAt = createdAt; self.updatedAt = updatedAt; self.postedAt = postedAt
    }
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
