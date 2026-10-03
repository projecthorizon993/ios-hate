import Photos
import SwiftUI
import UIKit

/// The photo library: every capture, newest first.
///
/// This is the gallery the rest of the app has been promising. It reads the directory
/// `PhotoStore` writes rather than keeping its own list, so a photo the user deleted in
/// Files.app disappears from here too instead of leaving a thumbnail that opens nothing.
///
/// Thumbnails are produced on demand and cached by URL, because decoding a full-resolution
/// capture to fill a 120 pt cell is what makes a grid stutter, and holding every full image
/// in memory to avoid that is a worse trade on a long library.
struct GalleryView: View {

    /// Dismissal, owned by the presenting screen.
    var onClose: () -> Void

    @State private var photos: [SavedPhoto] = []
    @State private var selected: SavedPhoto?
    @State private var banner: String?
    @State private var isExporting = false

    /// Columns for the grid. Three is deliberate: at two the cells are large enough to crop
    /// a 4:3 photo awkwardly, and at four the shots stop being recognisable at a glance,
    /// which is the only thing a grid like this has to do.
    private let columns = [GridItem(.flexible(), spacing: Theme.Space.xs),
                           GridItem(.flexible(), spacing: Theme.Space.xs),
                           GridItem(.flexible(), spacing: Theme.Space.xs)]

    var body: some View {
        NavigationStack {
            Group {
                if photos.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .background(Theme.ColorToken.surfaceBase)
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { onClose() }
                        .foregroundStyle(Theme.ColorToken.accentActive)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { storageSummary }
            }
        }
        .task { await reload() }
        .sheet(item: $selected) { photo in
            PhotoDetailView(photo: photo,
                            onDelete: { delete(photo) },
                            onSaveToPhotos: { saveToPhotos(photo) },
                            onDismiss: { selected = nil })
        }
        .overlay(alignment: .bottom) {
            if let banner {
                Text(banner)
                    .font(.system(size: Theme.TypeSize.label))
                    .foregroundStyle(Theme.ColorToken.textPrimary)
                    .padding(Theme.Space.s)
                    .background(Theme.ColorToken.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
                    .padding(Theme.Space.l)
                    .transition(.opacity)
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.Space.xs) {
                ForEach(photos) { photo in
                    Button {
                        selected = photo
                    } label: {
                        GalleryCell(photo: photo)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Space.xs)
        }
    }

    /// Nothing here yet. Says where captures go, because "empty" on a camera that has just
    /// taken a photo reads as data loss rather than as an empty folder.
    private var emptyState: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34))
                .foregroundStyle(Theme.ColorToken.textDisabled)
            Text("No photos yet")
                .font(.system(size: Theme.TypeSize.title))
                .foregroundStyle(Theme.ColorToken.textPrimary)
            Text("Captures are saved on this device in LumaFrame › Photos.")
                .font(.system(size: Theme.TypeSize.label))
                .foregroundStyle(Theme.ColorToken.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var storageSummary: some View {
        if let bytes = PhotoStore.totalBytes() {
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.textSecondary)
        }
    }

    // MARK: - Loading

    /// Reads the directory off the main actor: this walks every file and decodes metadata.
    private func reload() async {
        let loaded = await Task.detached(priority: .userInitiated) {
            PhotoStore.loadAll()
        }.value
        photos = Self.entries(from: loaded)
    }

    /// One entry per capture: the graded file when there is one, otherwise the original.
    ///
    /// A look writes a *second* file beside the original rather than replacing it, because
    /// the untouched original is what a later re-render needs. Both files are real and both
    /// stay on disk, but a single shutter press filling two cells in the grid reads as two
    /// photos having been taken, so they are collapsed here.
    ///
    /// The processed file records which original it came from, which is what makes the
    /// pairing possible without a filename convention. Pure, and unit tested.
    static func entries(from photos: [SavedPhoto]) -> [SavedPhoto] {
        // `derivedFrom` points at the original, so grouping by it puts an original and its
        // processed version in one bucket; an original with no processed version is its own
        // bucket because its own id is the key.
        var representative: [UUID: SavedPhoto] = [:]
        for photo in photos {
            let key = photo.metadata.derivedFrom ?? photo.id
            // Input is newest-first, so the first writer for a key is the newest file for
            // that capture — which is the graded one, since it is written second.
            if representative[key] == nil {
                representative[key] = photo
            }
        }
        // Re-sorted rather than left in dictionary order, which would shuffle the grid.
        return representative.values.sorted { $0.capturedAt > $1.capturedAt }
    }

    // MARK: - Actions

    /// Saves to the library, then says so. The file in the app is untouched either way.
    private func saveToPhotos(_ photo: SavedPhoto) {
        guard !isExporting else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                try await PhotoStore.addToLibrary(photo)
                say("Saved to Photos")
            } catch {
                say(error.localizedDescription)
            }
        }
    }

    /// Deletes the file and drops it from the list. `reload` is not used here: re-reading
    /// the whole directory to remove one row would make a tap feel like it cost something.
    private func delete(_ photo: SavedPhoto) {
        do {
            try PhotoStore.delete(photo)
            photos.removeAll { $0.id == photo.id }
            selected = nil
            say("Deleted")
        } catch {
            say(error.localizedDescription)
        }
    }

    private func say(_ message: String) {
        withAnimation(Theme.Motion.animation(Theme.Motion.overlay)) {
            banner = message
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(Theme.Motion.animation(Theme.Motion.overlay)) {
                if banner == message { banner = nil }
            }
        }
    }
}

// MARK: - Cell

/// One photo in the grid.
///
/// The thumbnail is decoded by `.task`, never inside `body`: reading and decoding a file
/// during a view update blocks the main thread, and doing it here would also decode the
/// same file again on every re-render.
private struct GalleryCell: View {
    var photo: SavedPhoto
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                // Placeholder rather than a spinner: the cell is small, and a grid of
                // twenty spinners is noise for something that resolves in milliseconds.
                Theme.ColorToken.surfaceRaised
            }
            Text(photo.metadata.pixelWidth > 0
                 ? "\(photo.metadata.pixelWidth)×\(photo.metadata.pixelHeight)"
                 : photo.container.rawValue.uppercased())
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.textPrimary)
                .padding(.horizontal, Theme.Space.xxs)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(Theme.Space.xxs)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(Theme.ColorToken.strokeSubtle, lineWidth: 1)
        }
        .accessibilityLabel(photo.container.rawValue)
        .accessibilityValue("\(photo.metadata.pixelWidth) by \(photo.metadata.pixelHeight) pixels")
        .task(id: photo.url) {
            thumbnail = await GalleryThumbnailCache.shared.image(for: photo)
        }
    }
}

/// Decodes cell-sized thumbnails once and keeps them.
///
/// Bounded on purpose. An unbounded cache of every thumbnail in a long library is the same
/// mistake as holding the full images, only smaller; the cap is generous enough that a
/// normal session never reaches it and small enough that a long one cannot grow without
/// limit. Eviction is oldest-first because the newest cells are the ones on screen.
private final class GalleryThumbnailCache: @unchecked Sendable {

    static let shared = GalleryThumbnailCache()

    private let limit = 120
    private var images: [URL: UIImage] = [:]
    private var order: [URL] = []
    private let lock = NSLock()

    /// A cache hit is a dictionary read; a miss decodes off the main actor.
    func image(for photo: SavedPhoto) async -> UIImage? {
        if let cached = cached(photo.url) { return cached }
        let url = photo.url
        let decoded = await Task.detached(priority: .utility) { [weak self] in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return PhotoStore.thumbnail(from: data, maxPixelSize: 400)
        }.value
        guard let decoded else { return nil }
        store(decoded, for: url)
        return decoded
    }

    private func cached(_ url: URL) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let image = images[url] else { return nil }
        touch(url)
        return image
    }

    private func store(_ image: UIImage, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard images[url] == nil else { return }
        images[url] = image
        order.append(url)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            images[oldest] = nil
        }
    }

    /// Keeps the recency order honest without re-sorting on every hit.
    private func touch(_ url: URL) {
        if let index = order.firstIndex(of: url) {
            order.remove(at: index)
            order.append(url)
        }
    }
}

// MARK: - Detail

/// One photo, full screen, with what it is and what can be done to it.
private struct PhotoDetailView: View {
    var photo: SavedPhoto
    var onDelete: () -> Void
    var onSaveToPhotos: () -> Void
    var onDismiss: () -> Void

    @State private var isConfirmingDelete = false
    @State private var isSharing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.m) {
                image
                facts
                actions
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ColorToken.surfaceBase)
            .navigationTitle(photo.container.rawValue.uppercased())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { onDismiss() }
                        .foregroundStyle(Theme.ColorToken.accentActive)
                }
            }
        }
        .confirmationDialog("Delete this photo?",
                            isPresented: $isConfirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is removed from this device. Anything already saved to Photos stays.")
        }
        .sheet(isPresented: $isSharing) {
            // `UIImage` is not `Sendable`, and the share sheet wants the object rather than
            // a URL because the file may be a format the receiving app cannot open.
            ShareSheet(items: [ShareableImage(url: photo.url)])
        }
    }

    /// The photo, fitted rather than cropped: this is the view a user checks a shot in, and
    /// a cropped one would misrepresent what was taken.
    private var image: some View {
        Group {
            if let data = try? Data(contentsOf: photo.url),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                // The file is gone or unreadable — deleted in Files.app, for instance. Saying
                // so beats an empty frame that looks like a loading state.
                VStack(spacing: Theme.Space.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.ColorToken.stateWarn)
                    Text("This file can no longer be opened")
                        .font(.system(size: Theme.TypeSize.label))
                        .foregroundStyle(Theme.ColorToken.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    /// What the shot was, read from the recipe in the file's own metadata.
    ///
    /// Rows are dropped when the value was never recorded rather than shown as zero: an ISO
    /// of 0 is not a measurement, and printing one would be a small lie about the photo.
    private var facts: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            ForEach(Fact.rows(for: photo), id: \.label) { fact in
                HStack {
                    Text(fact.label)
                        .font(.system(size: Theme.TypeSize.caption))
                        .foregroundStyle(Theme.ColorToken.textSecondary)
                    Spacer(minLength: Theme.Space.s)
                    Text(fact.value)
                        .font(.system(size: Theme.TypeSize.mono, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.textPrimary)
                }
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ColorToken.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            Button {
                onSaveToPhotos()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: Theme.Space.minTouch)
            }
            .buttonStyle(.bordered)

            Button {
                isSharing = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: Theme.Space.minTouch)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: Theme.Space.minTouch)
            }
            .buttonStyle(.bordered)
        }
    }
}

/// One label/value pair for the detail sheet.
private struct Fact: Identifiable {
    var label: String
    var value: String
    var id: String { label }

    /// Built from a photo's own metadata, skipping anything never recorded.
    static func rows(for photo: SavedPhoto) -> [Fact] {
        let metadata = photo.metadata
        var rows: [Fact] = []

        if metadata.pixelWidth > 0, metadata.pixelHeight > 0 {
            rows.append(Fact(label: "Size",
                             value: "\(metadata.pixelWidth)×\(metadata.pixelHeight)"))
        }
        if let iso = metadata.iso, iso > 0 {
            rows.append(Fact(label: "ISO", value: String(format: "%.0f", iso)))
        }
        if let shutter = metadata.shutterSeconds, shutter > 0 {
            rows.append(Fact(label: "Shutter", value: ReportFormat.shutter(shutter)))
        }
        if let zoom = metadata.zoomFactor, zoom > 0 {
            rows.append(Fact(label: "Zoom", value: String(format: "%.2f", zoom) + "x"))
        }
        if let lens = metadata.lensKind, !lens.isEmpty {
            // Resolved from the recipe's raw device type rather than stored as a `Kind`,
            // which is what lets the file outlive a rename of the app's own enum.
            let kind = BackCameraCapabilities.kind(ofRawValue: lens)
            rows.append(Fact(label: "Lens",
                             value: kind == .unknown ? lens : kind.zoomLabel))
        }
        if metadata.frontCamera {
            rows.append(Fact(label: "Camera", value: "Front"))
        }
        if !metadata.photoQualityPrioritization.isEmpty {
            rows.append(Fact(label: "Quality", value: metadata.photoQualityPrioritization))
        }
        if !metadata.colorSpace.isEmpty {
            rows.append(Fact(label: "Colour", value: metadata.colorSpace))
        }
        if let look = metadata.processing, let name = look.look?.name {
            rows.append(Fact(label: "Look", value: name))
        }
        return rows
    }
}

// MARK: - Sharing

/// A file wrapped for `UIActivityViewController`.
///
/// The URL is passed rather than the image data because it can be large and this sheet is
/// presented on the main actor; Photos reads it lazily and the share extension gets a real
/// file with its original name and format.
private struct ShareableImage: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// `UIActivityViewController`, which SwiftUI does not wrap.
private struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}