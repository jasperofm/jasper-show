import AVFoundation
import Combine
import ReelCore

/// Owns the editor's AVPlayer and keeps it showing the current edits.
///
/// Color and framing are read live from a `SettingsBox` by the Core Image
/// handler, so those changes only need a redraw. Cuts and speed change the
/// timeline and need a new player item, which is debounced.
@MainActor
final class PreviewController: ObservableObject {
    let player = AVPlayer()
    let box: SettingsBox
    private let source: AVURLAsset
    private var sourceSize: CGSize = .zero
    private var timingKey: TimingKey?
    private var rebuildTask: Task<Void, Never>?
    private var timeObserver: Any?

    /// When true the preview ignores crop/zoom/pan/rotation so the user can
    /// draw a crop box over the whole frame.
    @Published var showFullFrame = false { didSet { apply(lastSettings, force: true) } }
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var error: String?
    private(set) var lastSettings: EditSettings

    /// Longest edge of preview frames. Lower than export for responsiveness.
    static let previewLongEdge = 1280

    private struct TimingKey: Equatable { let cuts: [TimeRange]; let speed: Double }

    init(sourceURL: URL, settings: EditSettings) {
        source = AVURLAsset(url: sourceURL)
        lastSettings = settings
        box = SettingsBox(settings)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = t.seconds.isFinite ? t.seconds : 0
                self.isPlaying = self.player.rate != 0
            }
        }
        Task { await rebuild(settings) }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    var sourcePixelSize: CGSize { sourceSize }

    /// Call on every settings change.
    func apply(_ settings: EditSettings, force: Bool = false) {
        lastSettings = settings
        let visible = visibleSettings(settings)
        let oldGeometryAspect = aspect(of: box.value)
        box.value = visible

        let key = TimingKey(cuts: settings.cuts, speed: settings.speed)
        if key != timingKey {
            rebuildTask?.cancel()
            rebuildTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                await self?.rebuild(settings)
            }
            return
        }
        guard let item = player.currentItem else { return }
        if force || abs(aspect(of: visible) - oldGeometryAspect) > 0.001 {
            // Output size changed: needs a new video composition.
            item.videoComposition = VariationRenderer.makeVideoComposition(
                for: item.asset, sourceSize: sourceSize, box: box, maxLongEdge: Self.previewLongEdge)
        } else if player.rate == 0 {
            // Paused: re-seek to the same frame so the handler redraws it.
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func togglePlay() {
        if player.rate != 0 { player.pause(); return }
        if currentTime >= duration - 0.05 { player.seek(to: .zero) }
        player.play()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func rebuild(_ settings: EditSettings) async {
        do {
            if sourceSize == .zero { sourceSize = try await VariationRenderer.orientedSize(of: source) }
            let keepTime = currentTime
            let comp = try await VariationRenderer.makeComposition(source: source, settings: settings)
            let item = AVPlayerItem(asset: comp)
            item.audioTimePitchAlgorithm = .spectral
            box.value = visibleSettings(lastSettings)
            item.videoComposition = VariationRenderer.makeVideoComposition(
                for: comp, sourceSize: sourceSize, box: box, maxLongEdge: Self.previewLongEdge)
            let wasPlaying = player.rate != 0
            player.replaceCurrentItem(with: item)
            timingKey = TimingKey(cuts: settings.cuts, speed: settings.speed)
            duration = comp.duration.seconds
            seek(to: min(keepTime, max(0, duration - 0.05)))
            if wasPlaying { player.play() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func visibleSettings(_ s: EditSettings) -> EditSettings {
        guard showFullFrame else { return s }
        var v = s
        v.crop = EditSettings.identity.crop
        v.zoom = 1
        v.pan = .zero
        v.rotation = 0
        v.outputAspect = .source
        return v
    }

    private func aspect(of s: EditSettings) -> Double {
        guard sourceSize != .zero else { return 0 }
        let w = FrameGeometry(sourceSize: sourceSize, settings: s).window
        return w.width / max(w.height, 1)
    }
}
