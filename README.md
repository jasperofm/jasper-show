# Reel Manager

A native macOS app (Swift, SwiftUI, AVFoundation, SQLite) for making edited
variations of your videos, keeping track of which variation goes to which
account, and posting through the official Instagram, TikTok and YouTube APIs.

This is the **Phase 1 MVP**. It has not been compiled yet: it was written in a
Linux container with no Swift toolchain. Expect a handful of compiler fixes
on first build in Xcode (see "First build" below).

## What's in Phase 1

| Area | What it does |
|---|---|
| Import & library | Drag-and-drop or ⌘I. Files are copied into the library with a thumbnail, duration and import date. Sort by newest, oldest, title or most assigned. Click an account in the sidebar to filter the library to what's assigned to it. |
| Variation editor | Crop (draw a box on the preview), output aspect (9:16, 1:1, 4:5, 16:9), zoom, pan, rotate; brightness, contrast, saturation, color temperature; cuts at any point; speed 0.5× to 2×. |
| Live preview | Color and framing update the current frame immediately, via a Core Image handler that reads the live settings. Cuts and speed rebuild the timeline after a 200 ms pause. |
| Undo / redo | ⌘Z / ⇧⌘Z. A whole slider drag or crop drag counts as one step. |
| Version history | Every save, including the autosave 1.5 s after an edit, writes a snapshot. You can restore any snapshot from the last 30 days, and restoring can itself be undone. The whole database is also backed up at launch (`VACUUM INTO`), and those backups are kept for 30 days. |
| Export presets | Maximum (HEVC at source resolution, up to 4K), High (H.264 up to 1080p), Balanced (H.264 up to 720p). |
| Side-by-side comparison | Thumbnails of every variation. Pick up to 3 to play together in sync. Hover to see the list of edits. |
| Accounts | OAuth2 sign-in in a private browser session (PKCE where the platform supports it). Tokens are kept in the Keychain and never in SQLite. Status dot shows connected, pending, error or disconnected, with the last sync time. Tokens refresh automatically, and a failed refresh marks the account as needing reconnection. |
| Posting & tracker | Assign a variation to accounts with a caption and privacy, then post now or add it to the tracker. The tracker shows status, timestamps and attempt count, with a per-post attempt log. Failed posts show why they failed and stay in the tracker with a Retry button. |

## Deliberately not built

Some parts of the original spec were left out because their purpose is to get
past the platforms' duplicate-content and inauthentic-behavior detection:

- the "uniqueness score" and the "X% similar, add more crop" warnings
- the guidelines on which edits are "strong signals" for the algorithm
- auto-suggestions for making variations harder to match
- variation-to-account recommendations based on similarity detection

Instagram, TikTok and YouTube all forbid this, and accounts that do it can be
banned. The editing tools themselves are ordinary (crop, color, cuts, speed),
so they're all here. The comparison view is a plain visual comparison with no
scoring.

## Project layout

```
Package.swift
Sources/ReelCore/            # no UI; unit-testable
  Models/       EditSettings, SourceAsset, Variation, Account, PostJob, ExportPreset
  Storage/      SQLiteDatabase (thin C-API wrapper), Schema (migrations), LibraryStore
  Video/        FrameGeometry (pure math), VariationRenderer, VideoExporter, MediaImporter
  Editor/       EditHistory (undo/redo with drag coalescing)
  Accounts/     KeychainStore, OAuth (PKCE + ASWebAuthenticationSession), AccountService
  Platforms/    PlatformClient protocol, InstagramClient, TikTokClient, YouTubeClient, HTTP
  Posting/      PostingService, RetryPolicy, RateLimiter, Scheduling (Phase 2 seam)
Sources/ReelManagerApp/      # SwiftUI shell
  App/          ReelManagerApp, AppState, EditorModel, PreviewController
  Views/        sidebar, library, editor + crop overlay, comparison, tracker, post sheet, settings
Tests/ReelCoreTests/         # geometry, cuts, undo, SQLite store, retry policy, chunking
Config/                      # Info.plist + entitlements for a signed .app
```

Everything is stored in `~/Library/Application Support/ReelManager/`:
`library.sqlite`, `Sources/`, `Exports/`, `Thumbnails/`, `Backups/`.

## First build

Requires macOS 13+ and Xcode 15+. The spec asked for 10.14, but SwiftUI needs
10.15, and this UI uses `NavigationSplitView`, `Table` and `LabeledContent`,
which need 13.

```sh
swift build            # compile
swift test             # ReelCore unit tests
swift run ReelManager  # launch (unsigned, no sandbox: fine for development)
```

To ship a real `.app`, open the folder in Xcode (File > Open > `Package.swift`),
or create a macOS App target that depends on `ReelCore`, and use
`Config/Info.plist` and `Config/ReelManager.entitlements`. Keychain access
and the `reelmanager://` URL scheme behave properly only in a signed bundle.

Things to check on the first run:

1. **Portrait phone videos.** `AVMutableVideoComposition(asset:applyingCIFiltersWithHandler:)`
   should hand the handler frames that are already upright. If portrait clips
   show up sideways, apply the track's `preferredTransform` in
   `VariationRenderer.apply`.
2. **Deprecation warnings** on macOS 15 SDKs (`AVAssetExportSession.export()`,
   the synchronous video-composition initializer). These are safe to ignore
   for now.
3. **Strict concurrency.** The code targets Swift 5 language mode. Swift 6
   mode will raise Sendable diagnostics around AVFoundation types.

## Connecting accounts

You register your own developer app on each platform and paste its
credentials into **Settings** (⌘,). Client IDs go to UserDefaults, and secrets
go to the Keychain.

| Platform | Setup | Notes |
|---|---|---|
| YouTube | Google Cloud project → enable YouTube Data API v3 → OAuth client (iOS type works for a Mac app). Redirect: `com.googleusercontent.apps.<id>:/oauth2redirect`. | Until Google audits the project, uploads are locked to private. Each upload costs about 1,600 of the default 10,000 daily quota units. |
| TikTok | TikTok for Developers app with Login Kit (desktop) and Content Posting API (Direct Post). Scopes: `user.info.basic`, `video.publish`. | Until TikTok audits the app, posts can only be `SELF_ONLY`. TikTok's Direct Post UX rules require the user to choose privacy on every post, so the post sheet has no preselected privacy. |
| Instagram | Meta app with "Instagram API with Instagram Login". Scopes: `instagram_business_basic`, `instagram_business_content_publish`. Professional (business or creator) accounts only. | Instagram requires an **https** redirect URI. Host a small page at that URI that forwards its query string to `reelmanager://oauth`. Posting uses resumable Reels upload, so no public video URL is needed. The daily publishing cap is read from `content_publishing_limit` before each post. |

**Production note.** The TikTok and Instagram token exchanges need the client
secret. Keeping it on the user's Mac is fine while you develop alone. Before
you distribute the app, move the code exchange and refresh to a small
backend, so the secret never ships inside the app.

The endpoints follow each platform's published docs, and the Instagram
client is pinned to Graph `v21.0` (`InstagramClient.graphVersion`). These
APIs change often, so check the current docs when you register your apps.

## Rate limits and retries

- `RateLimiter` spaces calls to the same account at least 30 s apart, and
  blocks an account for the `Retry-After` time, or 15 min, after an HTTP 429.
  Manual posting waits up to 90 s for the limiter, and fails the post with a
  clear message if it would have to wait longer.
- Posts run one after another, never in parallel.
- Every attempt goes into `post_attempts` with timestamps, the HTTP status and
  a message.
- `RetryPolicy` already contains the 1 / 5 / 15 minute backoff. It honors
  `Retry-After` and never retries 4xx errors or auth failures. In Phase 1,
  `PostingService.automaticRetry` is `false`, so a failed post waits for you
  to click Retry.

## How Phase 2 plugs in

The schema and services already have what the scheduler needs, so Phase 2
needs no migration:

- `post_jobs.scheduled_at`, `next_attempt_at`, `batch_id`, plus the
  `idx_jobs_status_due` index
- `LibraryStore.dueJobs(now:)` returns scheduled posts that are due, and
  failed posts whose retry time has passed
- `PostingService.send(jobID:)` is the single entry point for manual,
  scheduled and retried posts, so they all share one rate limiter and one
  attempt log
- `PostScheduling` (in `Posting/Scheduling.swift`) is the protocol to
  implement. Tick it from a timer and on wake from sleep, and set
  `automaticRetry = true`.
- Staggered posting: give each job in a `batchID` an increasing
  `scheduledAt` (start + i × interval) and set its status to `.scheduled`.
  The UI needs a date picker and an interval field in `PostSheet`.
