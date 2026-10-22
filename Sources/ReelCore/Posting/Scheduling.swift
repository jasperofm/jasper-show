import Foundation

/// Something that runs due posts. `PostScheduler` is the implementation;
/// tests or a future background helper can provide another.
@MainActor
public protocol PostScheduling: AnyObject {
    /// Runs every job that is due at `now`, one at a time.
    func tick(now: Date) async
}
