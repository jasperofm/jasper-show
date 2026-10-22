import Foundation
import ServiceManagement
import ReelCore

/// Registers the launch agent that keeps publishing when the app is quit.
///
/// The agent (Contents/Library/LaunchAgents/com.reelmanager.app.publisher.plist)
/// runs this same executable with `--background-publisher`. launchd starts
/// it at login and restarts it if it crashes. It publishes only approved
/// posts whose time has come, under the same rules as the app; whichever of
/// the two holds the publisher lock does the publishing.
@MainActor
final class BackgroundPublisher: ObservableObject {
    static let flag = "--background-publisher"
    static let plistName = "com.reelmanager.app.publisher.plist"

    @Published private(set) var status: Status = .off
    @Published private(set) var lastError: String?

    enum Status: Equatable {
        case off, on, needsApproval, unavailable
        var label: String {
            switch self {
            case .off: return "Off"
            case .on: return "On"
            case .needsApproval: return "Waiting for your approval in System Settings › Login Items"
            case .unavailable: return "Only available when Reel Manager is installed as an app"
            }
        }
    }

    private var service: SMAppService { SMAppService.agent(plistName: Self.plistName) }

    init() { refresh() }

    func refresh() {
        guard Bundle.main.bundleIdentifier != nil else { status = .unavailable; return }
        switch service.status {
        case .enabled: status = .on
        case .requiresApproval: status = .needsApproval
        case .notFound: status = .unavailable
        default: status = .off
        }
    }

    func setEnabled(_ on: Bool) {
        lastError = nil
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

/// The headless publisher process. No windows and no Dock icon: it ticks
/// the scheduler and posts notifications, and exits cleanly on SIGTERM.
enum BackgroundPublisherMain {
    @MainActor private static var keep: [AnyObject] = []

    @MainActor static func run() -> Never {
        do {
            let store: LibraryStore
            do { store = try LibraryStore() } catch {
                FileHandle.standardError.write(Data("Could not open the library: \(error)\n".utf8))
                exit(1)
            }
            let accounts = AccountService(store: store)
            let posting = PostingService(store: store, accounts: accounts)
            let scheduler = PostScheduler(store: store, posting: posting, conditions: SystemConditions(diskURL: store.root))
            let notifier = Notifier()
            posting.onFinished = { job in
                let who = (try? store.account(id: job.accountID)).map { "\($0.platform.displayName) \($0.handle)" } ?? "account"
                switch job.status {
                case .posted: notifier.send(title: "Posted to \(who)", body: "Published by the background publisher.")
                case .failed:
                    let next = job.nextAttemptAt.map { "Retrying at \($0.formatted(date: .omitted, time: .shortened))." }
                        ?? "Open Reel Manager to retry."
                    notifier.send(title: "Post to \(who) failed", body: "\(job.lastError ?? "Unknown error")\n\(next)")
                default: break
                }
            }
            let paused: (Account) -> Void = { a in
                notifier.send(title: "Paused \(a.platform.displayName) \(a.handle)", body: a.pauseReason ?? "Publishing paused.")
            }
            posting.onAccountPaused = paused
            accounts.onPaused = paused
            scheduler.onAlert = { alert in
                switch alert {
                case .morningDigest(let t): notifier.send(title: "Today in Reel Manager", body: t)
                case .queueRunningLow(let t): notifier.send(title: "Queue running low", body: t)
                case .signInExpiring(let t): notifier.send(title: "Sign-in expiring", body: t)
                }
            }
            scheduler.start(observeWake: false)

            signal(SIGTERM, SIG_IGN)
            let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            term.setEventHandler {
                Task { @MainActor in
                    scheduler.stop()
                    store.log(.system, "Background publisher stopped.")
                    exit(0)
                }
            }
            term.resume()
            keep = [store, accounts, posting, scheduler, notifier, term as AnyObject]
        }
        dispatchMain()
    }
}
