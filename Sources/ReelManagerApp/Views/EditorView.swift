import SwiftUI
import AVKit
import UniformTypeIdentifiers
import ReelCore

/// Split screen: controls on the left, live preview on the right.
struct EditorView: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var preview: PreviewController

    var body: some View {
        HSplitView {
            EditorControls(editor: editor, preview: preview)
                .frame(minWidth: 280, idealWidth: 310, maxWidth: 380)
            PreviewPane(editor: editor, preview: preview)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Controls

struct EditorControls: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var editor: EditorModel
    @ObservedObject var preview: PreviewController
    @State private var name = ""
    @State private var showHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField("Name", text: $name, onCommit: { editor.rename(name) })
                        .textFieldStyle(.roundedBorder)
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .help("Version history (30 days)")
                }

                section("Framing", reset: { editor.reset("Framing", [\.crop, \.pan, \.zoom, \.rotation, \.outputAspect]) }) {
                    Toggle("Draw crop on preview", isOn: $preview.showFullFrame)
                    Picker("Aspect", selection: editor.binding(\.outputAspect, label: "Aspect")) {
                        ForEach(OutputAspect.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    slider("Zoom", \.zoom, EditSettings.zoomRange, format: "%.2f×")
                    slider("Pan X", \.pan.x, -1...1, format: "%.2f")
                    slider("Pan Y", \.pan.y, -1...1, format: "%.2f")
                    slider("Rotate", \.rotation, EditSettings.rotationRange, format: "%.0f°")
                }

                section("Color", reset: { editor.reset("Color", [\.brightness, \.contrast, \.saturation, \.temperature,
                                                                  \.vignette, \.sharpness, \.lutID, \.lutIntensity]) }) {
                    HStack {
                        Menu("Looks") {
                            ForEach(LookPreset.allCases) { look in
                                Button(look.title) { editor.update("Look \(look.title)") { look.apply(to: &$0) } }
                            }
                        }
                        .fixedSize()
                        Spacer()
                        Toggle("Before", isOn: $preview.showOriginalColors)
                            .toggleStyle(.button).controlSize(.small)
                            .help("Show the original colors to compare")
                    }
                    slider("Brightness", \.brightness, EditSettings.brightnessRange, format: "%+.2f")
                    slider("Contrast", \.contrast, EditSettings.contrastRange, format: "%.2f")
                    slider("Saturation", \.saturation, EditSettings.saturationRange, format: "%.2f")
                    slider("Temperature", \.temperature, EditSettings.temperatureRange, format: "%.0fK")
                    slider("Vignette", \.vignette, EditSettings.unitRange, format: "%.2f")
                    slider("Sharpen", \.sharpness, EditSettings.unitRange, format: "%.2f")
                    LUTPicker(editor: editor)
                    if editor.settings.lutID != nil {
                        slider("LUT strength", \.lutIntensity, EditSettings.unitRange, format: "%.0f%%", scale: 100)
                    }
                }

                section("Audio", reset: { editor.reset("Audio", [\.volume, \.fadeIn, \.fadeOut]) }) {
                    Toggle("Mute", isOn: Binding(get: { editor.settings.volume == 0 },
                                                 set: { m in editor.update(m ? "Mute" : "Unmute") { $0.volume = m ? 0 : 1 } }))
                    slider("Volume", \.volume, EditSettings.volumeRange, format: "%.0f%%", scale: 100)
                    slider("Fade in", \.fadeIn, EditSettings.fadeRange, format: "%.1fs")
                    slider("Fade out", \.fadeOut, EditSettings.fadeRange, format: "%.1fs")
                }

                section("Cover", reset: { editor.update("Clear Cover") { $0.coverTime = nil } }) {
                    HStack {
                        Button("Use Current Frame") {
                            let t = preview.currentTime
                            editor.update("Cover") { $0.coverTime = t }
                        }
                        if let t = editor.settings.coverTime {
                            Button(String(format: "Go to cover (%.1fs)", t)) { preview.seek(to: t) }.buttonStyle(.link)
                        }
                    }
                    Text(editor.settings.coverTime == nil
                         ? "No cover chosen; each platform picks a frame."
                         : "Sent as the cover to Instagram and TikTok. YouTube uses it if your channel can set custom thumbnails.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                section("On-screen text", reset: { editor.update("Remove Text") { $0.overlay = nil } }) {
                    OverlayEditor(overlay: Binding(get: { editor.settings.overlay ?? TextOverlay() },
                                                   set: { o in editor.update("Text") { $0.overlay = o.isEmpty ? nil : o } }),
                                  placeholder: "Add text on the video")
                    Text("You can also set different text per account when you compose a post.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("Timing", reset: { editor.reset("Timing", [\.cuts, \.speed]) }) {
                    slider("Speed", \.speed, EditSettings.speedRange, format: "%.2f×")
                    CutsEditor(editor: editor, preview: preview)
                }

                PrivacyInfo(editor: editor)

                section("Export", reset: nil) {
                    Picker("Quality", selection: $editor.exportPreset) {
                        ForEach(ExportPreset.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text(editor.exportPreset.detail).font(.caption).foregroundStyle(.secondary)
                    if let p = editor.exportProgress {
                        ProgressView(value: p) { Text("Rendering…") }
                    } else {
                        HStack {
                            Button("Export") { editor.export() }
                            Button("Compose Post…") { app.openCompose(editor.variation) }
                                .disabled(editor.variation.needsExport)
                                .help(editor.variation.needsExport ? "Export the latest edits first" : "Assign to accounts and post")
                        }
                        if !editor.variation.needsExport, let d = editor.variation.exportedAt {
                            Text("Exported \(d.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let saved = editor.lastSavedAt {
                    Text("Saved \(saved.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(12)
        }
        .onAppear { name = editor.variation.name }
        .sheet(isPresented: $showHistory) { HistorySheet(editor: editor) }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, reset: (() -> Void)?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let reset { Button("Reset", action: reset).buttonStyle(.link).font(.caption) }
            }
            content()
        }
        Divider()
    }

    private func slider<V: BinaryFloatingPoint>(_ label: String, _ kp: WritableKeyPath<EditSettings, V>,
                                                _ range: ClosedRange<V>, format: String, scale: Double = 1) -> some View
    where V.Stride: BinaryFloatingPoint, V: CVarArg {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(String(format: format, Double(editor.settings[keyPath: kp]) * scale))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: editor.binding(kp, label: label), in: range, onEditingChanged: { editor.gesture($0) })
        }
    }
}

struct CutsEditor: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var preview: PreviewController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Cuts").font(.callout)
                Spacer()
                Button("Cut 1s at Playhead") {
                    editor.addCut(atSource: editor.sourceTime(forOutput: preview.currentTime))
                }
            }
            HStack {
                Button("Trim Start to Here") {
                    let t = editor.sourceTime(forOutput: preview.currentTime)
                    editor.update("Trim Start") { $0.cuts.append(TimeRange(start: 0, end: t)) }
                }
                .help("Remove everything before the playhead")
                Button("Trim End from Here") {
                    let t = editor.sourceTime(forOutput: preview.currentTime)
                    let d = editor.asset.duration
                    editor.update("Trim End") { $0.cuts.append(TimeRange(start: t, end: d)) }
                }
                .help("Remove everything after the playhead")
            }
            .controlSize(.small)
            ForEach(editor.settings.cuts) { cut in
                HStack(spacing: 6) {
                    timeField(cut.start) { editor.updateCut(cut.id, start: $0, end: cut.end) }
                    Text("–")
                    timeField(cut.end) { editor.updateCut(cut.id, start: cut.start, end: $0) }
                    Spacer()
                    Button { editor.removeCut(cut.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
                .font(.caption.monospacedDigit())
            }
            let out = editor.settings.outputDuration(sourceDuration: editor.asset.duration)
            Text(String(format: "Source %.1fs → output %.1fs", editor.asset.duration, out))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func timeField(_ value: Double, _ set: @escaping (Double) -> Void) -> some View {
        TextField("", value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(2)))
            .frame(width: 60)
            .textFieldStyle(.roundedBorder)
    }
}

struct HistorySheet: View {
    @ObservedObject var editor: EditorModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text("Version History").font(.title3.bold())
            Text("Snapshots from every save, kept for 30 days. Restoring can be undone.")
                .font(.caption).foregroundStyle(.secondary)
            List(editor.revisions()) { r in
                HStack {
                    VStack(alignment: .leading) {
                        Text(r.savedAt.formatted(date: .abbreviated, time: .standard))
                        Text(r.settings.changeSummary.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Restore") { editor.restore(r); dismiss() }
                }
            }
            .frame(minHeight: 260)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(18)
        .frame(width: 520, height: 420)
    }
}

// MARK: - Preview

struct PreviewPane: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var preview: PreviewController
    @AppStorage("editor.safeZone") private var safeZoneRaw = ""
    private var safeZone: Platform? { Platform(rawValue: safeZoneRaw) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.black
                PlayerLayerView(player: preview.player)
                if preview.showFullFrame {
                    CropOverlay(editor: editor, sourceSize: preview.sourcePixelSize)
                } else if let p = safeZone {
                    SafeZoneOverlay(zone: SafeZone.for(p), aspect: outputAspect, label: p.displayName)
                }
                if let err = preview.error {
                    Text(err).foregroundStyle(.white).padding().background(.red.opacity(0.7)).cornerRadius(6)
                }
            }
            HStack {
                Button { preview.togglePlay() } label: {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                }
                .keyboardShortcut(.space, modifiers: [])
                Slider(value: Binding(get: { preview.currentTime }, set: { preview.seek(to: $0) }),
                       in: 0...max(preview.duration, 0.01))
                Text("\(formatDuration(preview.currentTime)) / \(formatDuration(preview.duration))")
                    .font(.caption.monospacedDigit())
                Picker("", selection: $safeZoneRaw) {
                    Text("No guides").tag("")
                    ForEach(Platform.allCases) { Text("\($0.displayName) safe zone").tag($0.rawValue) }
                }
                .labelsHidden().fixedSize()
                .help("Shows where each app's buttons and captions usually cover the video (approximate)")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }
}

extension PreviewPane {
    /// Width / height of the rendered output.
    var outputAspect: Double {
        let size = preview.sourcePixelSize
        guard size.width > 0 else { return 9.0 / 16.0 }
        let w = FrameGeometry(sourceSize: size, settings: editor.settings).window
        return w.width / max(w.height, 1)
    }
}

/// Shades the edges a platform's buttons and captions usually cover.
struct SafeZoneOverlay: View {
    let zone: SafeZone
    let aspect: Double
    let label: String

    var body: some View {
        GeometryReader { geo in
            let frame = fit(aspect, in: geo.size)
            let safe = zone.safeRect
            let box = CGRect(x: frame.minX + safe.minX * frame.width, y: frame.minY + safe.minY * frame.height,
                             width: safe.width * frame.width, height: safe.height * frame.height)
            ZStack(alignment: .topLeading) {
                Path { p in p.addRect(frame); p.addRect(box) }
                    .fill(Color.red.opacity(0.18), style: FillStyle(eoFill: true))
                Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                Text("\(label) safe area (approx.)").font(.caption2).foregroundStyle(.white)
                    .padding(3).background(.black.opacity(0.5))
                    .offset(x: box.minX + 4, y: box.minY + 4)
            }
            .allowsHitTesting(false)
        }
    }

    private func fit(_ aspect: Double, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        var w = size.width, h = size.width / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

/// Pick or import a .cube LUT.
struct LUTPicker: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var editor: EditorModel
    @State private var luts: [String] = []

    var body: some View {
        HStack {
            Picker("LUT", selection: Binding(get: { editor.settings.lutID ?? "" },
                                             set: { id in editor.update("LUT") { $0.lutID = id.isEmpty ? nil : id } })) {
                Text("None").tag("")
                ForEach(luts, id: \.self) { Text(($0 as NSString).deletingPathExtension).tag($0) }
            }
            Button("Import…") { importLUT() }.controlSize(.small)
        }
        .onAppear { luts = LUTLibrary.shared.available() }
    }

    private func importLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let id = try LUTLibrary.shared.importCube(from: url)
            luts = LUTLibrary.shared.available()
            editor.update("LUT") { $0.lutID = id }
        } catch {
            app.report(error, title: "Couldn't import the LUT")
        }
    }
}

/// Shows location and device info in the source file, which export leaves out.
struct PrivacyInfo: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var editor: EditorModel
    @State private var items: [MediaMetadata.Item] = []
    @AppStorage("export.stripMetadata") private var strip = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("File info").font(.headline)
            if items.isEmpty {
                Text("No location or device info found in this file.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(items, id: \.self) { i in
                    HStack(alignment: .top) {
                        Text(i.label).font(.caption).frame(width: 90, alignment: .leading)
                        Text(i.value).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                }
            }
            Toggle("Remove location and device info when exporting", isOn: $strip).font(.caption)
        }
        .task(id: editor.asset.id) {
            items = await MediaMetadata.privateInfo(of: app.store.url(forRelative: editor.asset.relativePath))
        }
        Divider()
    }
}

/// AVPlayerLayer host. Plain layer instead of AVPlayerView so the crop
/// overlay can sit on top and match the video rect exactly (aspect fit).
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        v.layer = layer       // layer-hosting view: set the layer before wantsLayer
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVPlayerLayer)?.player = player
    }
}

/// Lets the user drag a crop rectangle over the full source frame.
/// Drag inside the box to move it, outside to draw a new one.
struct CropOverlay: View {
    @ObservedObject var editor: EditorModel
    let sourceSize: CGSize
    @State private var dragStart: CGRect?
    @State private var mode: Mode = .draw
    private enum Mode { case draw, move }

    var body: some View {
        GeometryReader { geo in
            let frame = videoRect(in: geo.size)
            let crop = editor.settings.crop
            let box = CGRect(x: frame.minX + crop.minX * frame.width, y: frame.minY + crop.minY * frame.height,
                             width: crop.width * frame.width, height: crop.height * frame.height)
            ZStack(alignment: .topLeading) {
                // Dim outside the crop.
                Path { p in
                    p.addRect(frame)
                    p.addRect(box)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                Rectangle().stroke(Color.yellow, lineWidth: 2)
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { g in
                    if dragStart == nil {
                        dragStart = crop
                        mode = box.contains(g.startLocation) ? .move : .draw
                        editor.gesture(true)
                    }
                    guard let start = dragStart, frame.width > 0 else { return }
                    var r: CGRect
                    switch mode {
                    case .move:
                        let dx = g.translation.width / frame.width, dy = g.translation.height / frame.height
                        r = start.offsetBy(dx: dx, dy: dy)
                        r.origin.x = min(max(0, r.origin.x), 1 - r.width)
                        r.origin.y = min(max(0, r.origin.y), 1 - r.height)
                    case .draw:
                        let a = normalized(g.startLocation, in: frame), b = normalized(g.location, in: frame)
                        r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                        if let ratio = editor.settings.outputAspect.ratio, sourceSize.height > 0 {
                            // Keep the drawn box at the output aspect (in pixels).
                            let srcAspect = sourceSize.width / sourceSize.height
                            r.size.height = min(1 - r.minY, r.width * srcAspect / ratio)
                        }
                    }
                    editor.update("Crop") { $0.crop = r }
                }
                .onEnded { _ in
                    dragStart = nil
                    editor.gesture(false)
                })
        }
    }

    private func videoRect(in size: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / sourceSize.width, size.height / sourceSize.height)
        let w = sourceSize.width * scale, h = sourceSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func normalized(_ p: CGPoint, in f: CGRect) -> CGPoint {
        CGPoint(x: min(max(0, (p.x - f.minX) / f.width), 1), y: min(max(0, (p.y - f.minY) / f.height), 1))
    }
}
