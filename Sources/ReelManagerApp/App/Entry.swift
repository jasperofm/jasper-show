import Foundation

/// One executable, two modes: the normal app, or (when launchd starts it
/// with `--background-publisher`) the headless publisher.
@main
enum Entry {
    @MainActor static func main() {
        if CommandLine.arguments.contains(BackgroundPublisher.flag) {
            BackgroundPublisherMain.run()
        } else {
            ReelManagerApp.main()
        }
    }
}
