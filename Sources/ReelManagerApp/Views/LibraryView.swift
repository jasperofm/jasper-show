import SwiftUI
import UniformTypeIdentifiers
import ReelCore

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @State private var dropTargeted = false
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library").font(.headline)
                if app.isImporting { ProgressView().controlSize(.small) }
                Spacer()
                Picker("Account", selection: $app.selectedAccountFilter) {
                    Text("All accounts").tag(UUID?.none)
                    ForEach(app.accounts) { Text($0.handle).tag(UUID?.some($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Show only videos assigned to an account")
                Picker("Sort", selection: $app.librarySort) {
                    ForEach(AppState.LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(10)
            Divider()

            ScrollView {
                if app.sortedAssets.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down").font(.largeTitle)
                        Text(app.selectedAccountFilter == nil ? "Drop videos here or press ⌘I" : "Nothing assigned to this account yet")
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(app.sortedAssets) { asset in
                        AssetCell(asset: asset, selected: app.selectedAssetID == asset.id)
                            .onTapGesture { app.selectedAssetID = asset.id }
                            .contextMenu {
                                Button("New Variation") { app.selectedAssetID = asset.id; app.newVariation() }
                                Button("Delete Video", role: .destructive) { app.deleteAsset(asset) }
                            }
                    }
                }
                .padding(10)

                if let asset = app.selectedAsset {
                    VariationList(asset: asset)
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers)
            return true
        }
    }

    private func loadURLs(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for p in providers {
                if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let u = URL(dataRepresentation: url, relativeTo: nil),
                   let type = UTType(filenameExtension: u.pathExtension), type.conforms(to: .movie) {
                    urls.append(u)
                }
            }
            app.importFiles(urls)
        }
    }
}

struct AssetCell: View {
    @EnvironmentObject var app: AppState
    let asset: SourceAsset
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Thumb(image: app.thumbnail(asset.thumbnailPath))
                .overlay(alignment: .bottomTrailing) {
                    Text(formatDuration(asset.duration))
                        .font(.caption2.monospacedDigit()).padding(3)
                        .background(.black.opacity(0.6)).foregroundStyle(.white).cornerRadius(3).padding(4)
                }
            Text(asset.title).font(.callout).lineLimit(1)
            Text("\(asset.importedAt.formatted(date: .abbreviated, time: .omitted)) · \(app.variations(of: asset.id).count) variations")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(6)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear)
        .cornerRadius(8)
    }
}

struct VariationList: View {
    @EnvironmentObject var app: AppState
    let asset: SourceAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Variations of \(asset.title)").font(.subheadline.bold())
                Spacer()
                Button { app.newVariation() } label: { Image(systemName: "plus") }
                    .help("New variation (⌘N)")
            }
            ForEach(app.variations(of: asset.id)) { v in
                VariationRow(variation: v, selected: app.selectedVariationID == v.id)
                    .onTapGesture { app.selectedVariationID = v.id }
                    // Drag onto an account in the sidebar to post it there.
                    .draggable(v.id.uuidString)
                    .contextMenu {
                        Button("Duplicate") { app.newVariation(from: v) }
                        Button("Compose Post…") { app.openCompose(v) }.disabled(v.needsExport)
                        Divider()
                        Button("Delete", role: .destructive) { app.deleteVariation(v) }
                    }
            }
        }
        .padding(10)
    }
}

struct VariationRow: View {
    @EnvironmentObject var app: AppState
    let variation: Variation
    let selected: Bool

    var body: some View {
        HStack {
            Thumb(image: app.thumbnail(variation.thumbnailPath ?? app.asset(id: variation.assetID)?.thumbnailPath))
                .frame(width: 56)
            VStack(alignment: .leading) {
                Text(variation.name).lineLimit(1)
                Text(variation.needsExport ? "Not exported" : "Exported · \(variation.exportPreset?.displayName ?? "")")
                    .font(.caption).foregroundStyle(variation.needsExport ? .orange : .secondary)
            }
            Spacer()
            let jobs = app.jobs(for: variation.id).filter { $0.status != .cancelled }
            if !jobs.isEmpty {
                Text("\(jobs.filter { $0.status == .posted }.count)/\(jobs.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("Posted / assigned accounts")
            }
        }
        .padding(4)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear)
        .cornerRadius(6)
        .help(variation.settings.changeSummary.joined(separator: "\n"))
    }
}

struct Thumb: View {
    let image: NSImage?
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .cornerRadius(4)
    }
}

func formatDuration(_ s: Double) -> String {
    let t = Int(s.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
}
