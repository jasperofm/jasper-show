import SwiftUI
import AVFoundation
import ReelCore

/// State for the variation currently open in the editor.
@MainActor
final class EditorModel: ObservableObject {
    unowned let app: AppState
    let asset: SourceAsset
    @Published private(set) var variation: Variation
    @Published private(set) var history: EditHistory
    let preview: PreviewController

    @Published var exportPreset: ExportPreset = .high
    @Published private(set) var exportProgress: Double?
    @Published private(set) var lastSavedAt: Date?

    private var autosaveTask: Task<Void, Never>?

    init(app: AppState, asset: SourceAsset, variation: Variation) {
        self.app = app
        self.asset = asset
        self.variation = variation
        let settings = variation.settings.normalized(sourceDuration: asset.duration)
        history = EditHistory(settings)
        preview = PreviewController(sourceURL: app.store.url(forRelative: asset.relativePath), settings: settings)
        exportPreset = variation.exportPreset ?? .high
    }

    var settings: EditSettings { history.current }
    var undoTitle: String { history.undoLabel.map { "Undo \($0)" } ?? "Undo" }
    var redoTitle: String { history.redoLabel.map { "Redo \($0)" } ?? "Redo" }

    // MARK: Editing

    /// Applies an edit as one undo step (or part of the current drag).
    func update(_ label: String, _ change: (inout EditSettings) -> Void) {
        var s = history.current
        change(&s)
        s = s.normalized(sourceDuration: asset.duration)
        history.apply(s, label: label)
        changed()
    }

    /// Binding for a slider. Pair with `beginGesture`/`endGesture` (via
    /// `onEditingChanged`) so one drag is one undo step.
    func binding<T>(_ keyPath: WritableKeyPath<EditSettings, T>, label: String) -> Binding<T> {
        Binding(get: { self.history.current[keyPath: keyPath] },
                set: { v in self.update(label) { $0[keyPath: keyPath] = v } })
    }

    func gesture(_ editing: Bool) {
        if editing { history.beginCoalescing() } else { history.endCoalescing(); objectWillChange.send() }
    }

    func reset(_ label: String, _ keyPaths: [PartialKeyPath<EditSettings>]) {
        update("Reset \(label)") { s in
            let d = EditSettings.identity
            for kp in keyPaths {
                switch kp {
                case let k as WritableKeyPath<EditSettings, Double>: s[keyPath: k] = d[keyPath: k]
                case let k as WritableKeyPath<EditSettings, CGRect>: s[keyPath: k] = d[keyPath: k]
                case let k as WritableKeyPath<EditSettings, CGPoint>: s[keyPath: k] = d[keyPath: k]
                case let k as WritableKeyPath<EditSettings, OutputAspect>: s[keyPath: k] = d[keyPath: k]
                case let k as WritableKeyPath<EditSettings, [TimeRange]>: s[keyPath: k] = d[keyPath: k]
                case let k as WritableKeyPath<EditSettings, String?>: s[keyPath: k] = d[keyPath: k]
                case let k as WritableKeyPath<EditSettings, Double?>: s[keyPath: k] = d[keyPath: k]
                default: break
                }
            }
        }
    }

    func undo() { if history.undo() { changed() } }
    func redo() { if history.redo() { changed() } }

    private func changed() {
        preview.apply(history.current)
        objectWillChange.send()
        scheduleAutosave()
    }

    // MARK: Cuts

    /// Adds a cut at the playhead (source time), 1 second long by default.
    func addCut(atSource t: Double, length: Double = 1) {
        update("Add Cut") { $0.cuts.append(TimeRange(start: t, end: min(asset.duration, t + length))) }
    }

    func updateCut(_ id: UUID, start: Double, end: Double) {
        update("Edit Cut") { s in
            if let i = s.cuts.firstIndex(where: { $0.id == id }) { s.cuts[i] = TimeRange(id: id, start: start, end: end) }
        }
    }

    func removeCut(_ id: UUID) {
        update("Remove Cut") { $0.cuts.removeAll { $0.id == id } }
    }

    /// Converts the preview's playhead (output time) back to source time.
    func sourceTime(forOutput t: Double) -> Double {
        var remaining = t * settings.speed
        for r in settings.keptRanges(sourceDuration: asset.duration) {
            if remaining <= r.duration { return r.start + remaining }
            remaining -= r.duration
        }
        return asset.duration
    }

    // MARK: Saving

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes settings and a revision snapshot. Cheap and idempotent.
    func save() {
        autosaveTask?.cancel()
        guard variation.settings != history.current else { return }
        variation.settings = history.current
        variation.updatedAt = Date()
        do {
            try app.store.save(variation)
            lastSavedAt = Date()
            app.variationDidChange(variation)
        } catch {
            app.report(error, title: "Couldn't save")
        }
    }

    func rename(_ name: String) {
        variation.name = name
        try? app.store.save(variation)
        app.variationDidChange(variation)
    }

    // MARK: History

    func revisions() -> [VariationRevision] {
        (try? app.store.revisions(for: variation.id)) ?? []
    }

    func restore(_ r: VariationRevision) {
        update("Restore Version") { $0 = r.settings }
    }

    // MARK: Export

    func export() {
        save()
        let preset = exportPreset
        let settings = history.current
        let sourceURL = app.store.url(forRelative: asset.relativePath)
        let relative = "Exports/\(variation.id.uuidString).mp4"
        let out = app.store.url(forRelative: relative)
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".\(variation.id.uuidString)-rendering.mp4")
        exportProgress = 0

        Task {
            do {
                try await VideoExporter().export(sourceURL: sourceURL, settings: settings, preset: preset, to: tmp) { p in
                    Task { @MainActor [weak self] in self?.exportProgress = p }
                }
                // Swap in the new file only after a successful render.
                _ = try? FileManager.default.removeItem(at: out)
                try FileManager.default.moveItem(at: tmp, to: out)

                let thumbRel = "Thumbnails/\(variation.id.uuidString).jpg"
                let rendered = AVURLAsset(url: out)
                try? await Thumbnailer.writeThumbnail(for: rendered, at: settings.coverTime ?? min(1, settings.outputDuration(sourceDuration: asset.duration) / 2),
                                                      to: app.store.url(forRelative: thumbRel))
                variation.exportPath = relative
                variation.exportPreset = preset
                variation.exportedAt = Date()
                variation.thumbnailPath = thumbRel
                try app.store.save(variation)
                app.variationDidChange(variation)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                app.report(error, title: "Export failed")
            }
            exportProgress = nil
        }
    }
}

