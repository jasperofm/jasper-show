import SwiftUI
import AVFoundation
import ReelCore

/// All variations of a source as thumbnails; pick up to 3 to play side by
/// side in sync. Hover a thumbnail to see its edits.
struct ComparisonView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let asset: SourceAsset
    @State private var picked: [UUID] = []
    @State private var players: [UUID: AVPlayer] = [:]
    @State private var playing = false

    private var variations: [Variation] { app.variations(of: asset.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare variations of \(asset.title)").font(.title3.bold())
                Spacer()
                Button(playing ? "Pause All" : "Play All") { togglePlay() }.disabled(picked.isEmpty)
                Button("Restart") { restart() }.disabled(picked.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(variations) { v in
                        VStack(spacing: 4) {
                            Thumb(image: app.thumbnail(v.thumbnailPath ?? asset.thumbnailPath))
                                .frame(width: 150)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(picked.contains(v.id) ? Color.accentColor : .clear, lineWidth: 3))
                            Text(v.name).font(.caption).lineLimit(1)
                        }
                        .help(v.settings.changeSummary.joined(separator: "\n"))
                        .onTapGesture { toggle(v) }
                    }
                }
                .padding(4)
            }
            Text("Click up to 3 thumbnails to play them side by side. Hover for the edit list.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(picked, id: \.self) { id in
                    VStack {
                        ZStack {
                            Color.black
                            if let p = players[id] { PlayerLayerView(player: p) } else { ProgressView() }
                        }
                        if let v = app.variation(id: id) {
                            Text(v.name).font(.caption.bold())
                            Text(v.settings.changeSummary.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(18)
        .frame(minWidth: 960, minHeight: 620)
        .onDisappear { players.values.forEach { $0.pause() } }
    }

    private func toggle(_ v: Variation) {
        if let i = picked.firstIndex(of: v.id) {
            picked.remove(at: i)
            players[v.id]?.pause()
            players[v.id] = nil
            return
        }
        guard picked.count < 3 else { return }
        picked.append(v.id)
        Task { await load(v) }
    }

    /// Plays the exported file when it's current, otherwise renders live
    /// from the source at full quality.
    private func load(_ v: Variation) async {
        let player = AVPlayer()
        player.isMuted = picked.first != v.id
        if !v.needsExport, let path = v.exportPath {
            player.replaceCurrentItem(with: AVPlayerItem(url: app.store.url(forRelative: path)))
        } else {
            let source = AVURLAsset(url: app.store.url(forRelative: asset.relativePath))
            guard let plan = try? await VariationRenderer.plan(source: source, settings: v.settings,
                                                               maxLongEdge: ExportPreset.high.maxLongEdge) else { return }
            let item = AVPlayerItem(asset: plan.composition)
            item.videoComposition = plan.videoComposition
            item.audioTimePitchAlgorithm = .spectral
            player.replaceCurrentItem(with: item)
        }
        players[v.id] = player
        if playing { player.play() }
    }

    private func togglePlay() {
        playing.toggle()
        players.values.forEach { playing ? $0.play() : $0.pause() }
    }

    private func restart() {
        players.values.forEach { $0.seek(to: .zero) }
        if playing { players.values.forEach { $0.play() } }
    }
}
