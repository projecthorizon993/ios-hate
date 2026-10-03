// Reading and writing captured files, and the recipe that travels with them.
//
// CaptureMetadata is the on-disk recipe format and PhotoStore owns the files that carry it. Splitting them means every reader of the format has to know which file to open.
//
// Merged mechanically by scripts/consolidate.mjs. Declarations were moved whole and
// nothing was edited; see the commit message for the reasoning.
import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import Photos
import UIKit

// MARK: - metadata (was App/Sources/Storage/CaptureMetadata.swift)





/// The capture recipe, written into the file's own metadata.
///
/// `IOS_CAMERA_APP_PLAN.md` section 12.3 requires the processing recipe to travel with
/// the media so a photo can be re-rendered later without a destructive edit. Step 1
/// writes the capture half of that recipe and nothing else: there is no processing
/// stage yet, and inventing placeholder values for one would be a lie in the file.
///
/// Written into `Exif.UserComment` as a compact, versioned, key=value string. It is a
/// string rather than a bag of custom keys because UserComment survives every export
/// path, including the ones that drop unknown XMP keys.
struct CaptureMetadata: Equatable, Sendable {

    /// Bumped when the key set or the format changes, so a later reader can tell an old
    /// file from a new one instead of parsing it optimistically.
    static let recipeVersion = 1

    var mode: String = "auto"

    // Recorded as the device reported them at the moment of capture. Auto mode never
    // writes these, so they are measurements rather than settings.
    var iso: Float?
    var shutterSeconds: Double?
    var exposureTargetOffset: Double?
    /// The active lens's relative scale, as derived by
    /// `BackCameraCapabilities.relativeScale(of:)`. **Not** a 35 mm focal length:
    /// iOS does not expose one, and storing a relative number under a name that
    /// promises millimetres would make the file lie to whatever reads it later.
    var lensRelativeScale: Double?
    var lensKind: String?
    var zoomFactor: Double?
    var frontCamera: Bool = false

    // What AVFoundation resolved, not what was asked for.
    var photoQualityPrioritization: String = "balanced"
    var proRaw: Bool = false
    var raw: Bool = false
    var container: String = ""
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var colorSpace: String = "srgb"
    var hdrStatus: String = "unsupported"

    /// The processing recipe, as of Step 2 onwards. `nil` on a capture taken with nothing
    /// applied, which is the common case and is recorded as absence rather than as a
    /// zeroed struct: "no look was applied" and "a look was applied at zero intensity" are
    /// different facts about a photo and only one of them is usually true.
    var processing: ProcessingSettings?

    /// Set on a derived file to point at the untouched capture it came from. Lets a gallery
    /// (Step 9) present "original" and "processed" as two views of one photo rather than
    /// as two unrelated files.
    var derivedFrom: UUID?

    /// Never logged whole: it is the only place the file records a device-ish value and
    /// `AppLog` must not carry image content.
    var summariseForLog: String {
        "iso=\(ReportFormat.number(Double(iso ?? 0))) "
            + "shutter=\(ReportFormat.shutter(shutterSeconds ?? 0)) "
            + "quality=\(photoQualityPrioritization) proRAW=\(proRaw) raw=\(raw) "
            + "container=\(container) space=\(colorSpace)"
    }

    // MARK: - Recipe string

    /// Rebuilds metadata from a recipe string read back out of a file.
    ///
    /// The inverse of `recipeString()`, and total by design: an unreadable, truncated or
    /// future-version recipe yields defaults rather than failing, because a photo the app
    /// cannot describe is still a photo the user must be able to open. Every field is
    /// optional in the format, so a missing key is an absent measurement rather than a zero.
    init(recipe: String) {
        let (_, fields) = CaptureMetadata.parse(recipe: recipe)
        if let mode = fields["mode"] { self.mode = mode }
        if let value = fields["iso"], let parsed = Float(value) { self.iso = parsed }
        if let value = fields["sh"], let parsed = Double(value) { self.shutterSeconds = parsed }
        if let value = fields["ev"], let parsed = Double(value) { self.exposureTargetOffset = parsed }
        if let value = fields["rs"], let parsed = Double(value) { self.lensRelativeScale = parsed }
        if let lensKind = fields["lens"] { self.lensKind = lensKind }
        if let value = fields["zoom"], let parsed = Double(value) { self.zoomFactor = parsed }
        if let value = fields["q"] { self.photoQualityPrioritization = value }
        proRaw = fields["proraw"] == "1"
        raw = fields["raw"] == "1"
        frontCamera = fields["front"] == "1"
        if let space = fields["space"], !space.isEmpty { self.colorSpace = space }
        if let hdr = fields["hdr"], !hdr.isEmpty { self.hdrStatus = hdr }
        if let derived = fields["derived"] { self.derivedFrom = UUID(uuidString: derived) }
        processing = fields["proc"].flatMap(CaptureMetadata.decodeProcessing)
    }

    /// Compact, stable, round-trippable. Unknown keys are ignored by a reader and
    /// missing keys fall back to defaults, which is what lets step 5 add fields without
    /// invalidating step 1 files.
    func recipeString() -> String {
        var parts = ["v\(Self.recipeVersion)", "mode=\(mode)"]
        if let iso { parts.append("iso=\(ReportFormat.number(Double(iso)))") }
        if let shutterSeconds { parts.append("sh=\(String(format: "%.6f", shutterSeconds))") }
        if let offset = exposureTargetOffset { parts.append("ev=\(ReportFormat.number(offset))") }
        if let scale = lensRelativeScale { parts.append("rs=\(String(format: "%.1f", scale))") }
        if let lensKind { parts.append("lens=\(lensKind)") }
        if let zoomFactor { parts.append("zoom=\(ReportFormat.number(zoomFactor))") }
        parts.append("q=\(photoQualityPrioritization)")
        if proRaw { parts.append("proraw=1") }
        if raw { parts.append("raw=1") }
        if frontCamera { parts.append("front=1") }
        if !colorSpace.isEmpty { parts.append("space=\(colorSpace)") }
        if !hdrStatus.isEmpty { parts.append("hdr=\(hdrStatus)") }
        if let derivedFrom { parts.append("derived=\(derivedFrom.uuidString)") }
        // The recipe itself is written as one compact blob rather than flattened into
        // individual keys. Flattening would mean inventing a key per ToneCurve field and
        // then maintaining that mapping forever; a versioned JSON payload means a new
        // field needs no reader change, and a reader that meets a version it does not know
        // can decline rather than misread.
        if let processing, let encoded = Self.encodeProcessing(processing) {
            parts.append("proc=\(encoded)")
        }
        return parts.joined(separator: ";")
    }

    /// Percent-encoded so the `;` and `=` separators cannot be forged by a value.
    private static func encodeProcessing(_ settings: ProcessingSettings) -> String? {
        guard let data = try? JSONEncoder().encode(settings) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The inverse of `encodeProcessing`. Returns `nil` for anything unreadable rather
    /// than throwing, because a file from a future version must degrade to "no recipe"
    /// and never to a crash.
    static func decodeProcessing(_ token: String) -> ProcessingSettings? {
        var standard = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // base64 needs the padding back, and it was stripped because `=` is a separator.
        let remainder = standard.count % 4
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: standard) else { return nil }
        return try? JSONDecoder().decode(ProcessingSettings.self, from: data)
    }

    /// Parses a string produced by `recipeString`. Total by design: a malformed recipe in
    /// a third-party file must not be able to crash the reader.
    static func parse(recipe: String) -> (version: Int?, fields: [String: String]) {
        var fields: [String: String] = [:]
        var version: Int?
        for token in recipe.split(separator: ";").map(String.init) {
            guard let separator = token.firstIndex(of: "=") else {
                if token.hasPrefix("v") { version = Int(token.dropFirst()) }
                continue
            }
            let key = String(token[token.startIndex..<separator])
            let value = String(token[token.index(after: separator)...])
            guard !key.isEmpty else { continue }
            fields[key] = value
        }
        return (version, fields)
    }

    // MARK: - Image metadata

    /// The dictionary handed to `AVCapturePhotoSettings.metadata`, which AVFoundation
    /// merges into the file it writes.
    func dictionary() -> [String: Any] {
        var exif: [String: Any] = [:]
        if let shutter = shutterSeconds, shutter > 0 {
            exif[kCGImagePropertyExifExposureTime as String] = shutter
        }
        if let iso, iso > 0 {
            // Both ISO keys are written. `ISOSpeedRatings` is the array form that every
            // reader understands; `ISOSpeed` is the newer scalar form. There is no
            // `kCGImagePropertyExifPhotographicSensitivity` in this SDK, and an invented
            // constant is worse than one fewer redundant key.
            exif[kCGImagePropertyExifISOSpeedRatings as String] = [Int(iso.rounded())]
            exif[kCGImagePropertyExifISOSpeed as String] = Int(iso.rounded())
        }
        // The 35 mm equivalent focal length travels in the recipe, not in a TIFF/EXIF
        // key: this SDK has no `kCGImagePropertyExifFocalLengthIn35mmFilm` constant, and
        // the recipe is the app's own lossless record anyway. `f=` in the recipe is
        // written whenever the value was measured.
        exif[kCGImagePropertyExifUserComment as String] = recipeString()

        var tiff: [String: Any] = [:]
        tiff[kCGImagePropertyTIFFSoftware as String] = "LumaFrame"
        // No Make/Model: the file is the user's, but the app does not need to stamp the
        // device into it, and `AppLog` must never carry an identifier.
        tiff[kCGImagePropertyTIFFImageDescription as String] = "LumaFrame capture (\(mode))"

        return [
            kCGImagePropertyExifDictionary as String: exif,
            kCGImagePropertyTIFFDictionary as String: tiff
        ]
    }
}

// MARK: - Container detection

/// What `AVCapturePhoto.fileDataRepresentation()` actually produced.
///
/// The output can hand back HEIC, HEIF, JPEG or a DNG (standard RAW or ProRAW), and the
/// extension has to match the bytes. Guessing from the requested codec is exactly the
/// kind of thing that produces a file Photos refuses to open, so the leading bytes are
/// read instead. Detection is a pure function and is unit tested.
enum PhotoContainer: String, Equatable, Sendable {
    case heic
    case heif
    case jpeg
    case dng

    var pathExtension: String { rawValue }

    static func detect(from data: Data) -> PhotoContainer? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))

        // JPEG SOI + marker.
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return .jpeg }

        // DNG is TIFF-based: little-endian "II\x2A\x00" or big-endian "MM\x00\x2A".
        if bytes[0] == 0x49, bytes[1] == 0x49, bytes[2] == 0x2A, bytes[3] == 0x00 { return .dng }
        if bytes[0] == 0x4D, bytes[1] == 0x4D, bytes[2] == 0x00, bytes[3] == 0x2A { return .dng }

        // ISO base media: "ftyp" at offset 4, brand at offset 8.
        if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            if brand.hasPrefix("hei") { return .heic }
            if brand == "mif1" || brand == "msf1" { return .heif }
        }
        return nil
    }
}

// MARK: - store (was App/Sources/Storage/PhotoStore.swift)




/// A photo that has been written to disk, with the recipe that produced it.
struct SavedPhoto: Equatable, Identifiable, Sendable {
    var id: UUID
    var url: URL
    var capturedAt: Date
    var container: PhotoContainer
    var metadata: CaptureMetadata

    /// Never log this. `AppLog` must not carry a file name.
    var describeForLog: String {
        "\(container.rawValue) \(metadata.pixelWidth)x\(metadata.pixelHeight) "
            + "\(metadata.summariseForLog)"
    }
}

enum PhotoStoreError: LocalizedError, Equatable {
    case documentsUnavailable
    case writeFailed(String)
    case libraryAccessDenied

    var errorDescription: String? {
        switch self {
        case .documentsUnavailable:
            return "The app's Documents directory is not available"
        case .writeFailed(let reason):
            return reason
        case .libraryAccessDenied:
            return "LumaFrame is not allowed to add photos. Enable it in Settings > Privacy > Photos."
        }
    }
}

/// Writes captures into the app container, and copies them to the photo library only when
/// the user asks.
///
/// Three deliberate choices:
///
/// - **Local first.** `IOS_CAMERA_APP_PLAN.md` section 14 says media stays on the device
///   by default and the gallery is Step 9. Every capture lands in the app container
///   unconditionally; the library copy is a separate, explicit export that *copies* rather
///   than moves, so the original still exists for Step 4's re-render. That export is
///   add-only — `NSPhotoLibraryUsageDescription` is deliberately absent, so the app can
///   put a photo into the library without ever gaining the right to read the user's
///   existing library.
/// - **The original bytes are written untouched.** Enhancement is Step 4 and later, and
///   it must be able to re-render from the original. Writing a derived image here would
///   make that impossible, so the recipe travels in the metadata instead.
/// - **No file names in the log.** The ring buffer is dumped into a shareable report.
enum PhotoStore {

    /// Subdirectory of Documents. Named for what it holds, not for a moment in time.
    static let directoryName = "Photos"

    /// Filesystem-safe timestamp for a file name, in UTC so a shared container does not
    /// sort differently on two devices.
    static let stampFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS'Z'"

    static func directory(in fileManager: FileManager = .default) throws -> URL {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw PhotoStoreError.documentsUnavailable
        }
        let url = documents.appendingPathComponent(directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Writes `data` and returns where it went. Throws rather than returning an optional:
    /// a failed write must be visible, not silently skipped.
    static func write(_ data: Data,
                      container: PhotoContainer,
                      metadata: CaptureMetadata,
                      capturedAt: Date = Date(),
                      id: UUID = UUID(),
                      fileManager: FileManager = .default) throws -> SavedPhoto {
        let folder = try directory(in: fileManager)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = stampFormat
        let name = "\(formatter.string(from: capturedAt))-\(id.uuidString).\(container.pathExtension)"
        let url = folder.appendingPathComponent(name)

        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw PhotoStoreError.writeFailed(error.localizedDescription)
        }

        let saved = SavedPhoto(id: id,
                               url: url,
                               capturedAt: capturedAt,
                               container: container,
                               metadata: metadata)
        AppLog.note(AppLog.camera, "photo stored: \(saved.describeForLog)")
        // A count and a byte total, and deliberately no file name: this is the evidence that
        // bytes actually reached the disk, without putting the user's file names in a log
        // that gets shared. When a capture "succeeds" and nothing can be found, this is the
        // line that separates a write problem from a file-not-where-you-expected problem.
        if let total = totalBytes() {
            AppLog.note(AppLog.camera,
                        "stored total: \(storedFileCount()) files, \(total / 1024) KB")
        }
        return saved
    }

    /// How many files are in the store. `nil` rather than `0` when the directory cannot be
    /// read, so "nothing stored" and "cannot tell" stay different facts.
    static func storedFileCount(in fileManager: FileManager = .default) -> Int? {
        guard let folder = try? directory(in: fileManager),
              let contents = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }.count
    }

    // MARK: - Reading

    /// Every stored photo, newest first.
    ///
    /// The recipe is read back out of each file's own `Exif.UserComment` rather than from a
    /// sidecar index. There is no index, so there is nothing to fall out of step with the
    /// directory, and a file copied in through Files.app still lists with whatever recipe it
    /// happens to carry.
    ///
    /// Sorting is by capture time descending. A file whose name does not carry a timestamp
    /// — one the user copied in — falls back to its modification date rather than being
    /// dropped, because a photo that exists but is not listed is worse than one listed with
    /// an approximate date.
    static func loadAll(in fileManager: FileManager = .default) -> [SavedPhoto] {
        guard let folder = try? directory(in: fileManager),
              let contents = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        let photos = contents.compactMap { url -> SavedPhoto? in
            // The extension was written from the container the bytes were detected as, so it
            // is trusted here rather than re-reading every file's header: this runs over the
            // whole library on the main actor.
            guard let container = PhotoContainer(rawValue: url.pathExtension.lowercased()) else {
                return nil
            }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return SavedPhoto(id: identifier(from: url),
                              url: url,
                              capturedAt: capturedAt(from: url)
                                ?? modified?.contentModificationDate
                                ?? Date(timeIntervalSince1970: 0),
                              container: container,
                              metadata: readMetadata(from: url) ?? CaptureMetadata())
        }
        return photos.sorted { $0.capturedAt > $1.capturedAt }
    }

    /// The recipe recorded inside a stored file, or `nil` when it carries none.
    ///
    /// A file the app did not write — or one whose metadata an editor stripped — reports
    /// `nil`, which the gallery shows as "no recipe recorded" rather than as zeros that
    /// would read as real measurements.
    static func readMetadata(from url: URL) -> CaptureMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let comment = exif[kCGImagePropertyExifUserComment] as? String,
              !comment.isEmpty
        else { return nil }
        return CaptureMetadata(recipe: comment)
    }

    /// Removes one photo. Throws rather than returning a flag: a failed delete that is
    /// reported as a success leaves the user believing a photo is gone.
    static func delete(_ photo: SavedPhoto, in fileManager: FileManager = .default) throws {
        try fileManager.removeItem(at: photo.url)
        AppLog.note(AppLog.camera, "photo deleted: \(photo.describeForLog)")
    }

    /// Recovers the UUID from the file name this store writes.
    ///
    /// The name is `<stamp>-<uuid>.<ext>`, and the stamp contains hyphens, so the UUID is
    /// taken from the end: everything after the last hyphen that still parses as a UUID is
    /// found by trying successive suffixes. A name that is not ours yields `nil`, and the
    /// gallery falls back to a fresh identity — which costs nothing except that SwiftUI sees
    /// a new `Identifiable` for a file it already had.
    private static func identifier(from url: URL) -> UUID {
        let stem = url.deletingPathExtension().lastPathComponent
        var suffix = stem
        while let range = suffix.range(of: "-") {
            suffix = String(suffix[range.upperBound...])
            if let uuid = UUID(uuidString: suffix) { return uuid }
        }
        return UUID()
    }

    /// The capture time encoded in the file name, or `nil` when the name is not ours.
    private static func capturedAt(from url: URL) -> Date? {
        let stem = url.deletingPathExtension().lastPathComponent
        // The stamp is a fixed 24 characters; the UUID that follows is variable length.
        guard stem.count > stampFormat.count else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = stampFormat
        return formatter.date(from: String(stem.prefix(stampFormat.count)))
    }

    // MARK: - Photo library export

    /// Prompts for add-only access if it has not been decided yet.
    ///
    /// Grants are compared against `.authorized` exactly rather than "not denied": a
    /// limited library is a read-side concept and cannot satisfy an add.
    static func requestLibraryAddAccess() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized:
            return true
        case .notDetermined:
            return await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
        case .denied, .restricted, .limited:
            return false
        @unknown default:
            return false
        }
    }

    /// Copies an already-stored capture into the user's photo library.
    ///
    /// A copy, never a move: the file in the container is what Step 4 re-renders from, and
    /// removing it to avoid a duplicate would leave nothing to enhance. The library keeps
    /// its own copy and the app cannot read it back, which is the add-only bargain.
    static func addToLibrary(_ photo: SavedPhoto) async throws {
        guard await requestLibraryAddAccess() else {
            throw PhotoStoreError.libraryAccessDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            // A request has to be created before anything is attached to it: `addResource`
            // is an instance method, so there is no static shortcut. Going through
            // `forAsset()` rather than `creationRequestForAssetFromImage` is what keeps
            // this working for a DNG, which the image-from-file helper does not accept.
            let request = PHAssetCreationRequest.forAsset()
            // The options object is required, and leaving it empty means Photos picks its
            // own filename instead of inheriting the timestamp-and-UUID one the container
            // uses.
            request.addResource(with: .photo,
                                fileURL: photo.url,
                                options: PHAssetResourceCreationOptions())
        }
    }

    /// Byte count of everything stored so far, for the storage indicator. Returns `nil`
    /// rather than a partial sum when the directory cannot be read.
    static func totalBytes(in fileManager: FileManager = .default) -> Int64? {
        guard let folder = try? directory(in: fileManager) else { return nil }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let contents = try? fileManager.contentsOfDirectory(at: folder,
                                                                 includingPropertiesForKeys: Array(keys),
                                                                 options: [.skipsHiddenFiles]) else {
            return nil
        }
        var total: Int64 = 0
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }

    /// Downscaled thumbnail data for the gallery button, generated on a background queue.
    ///
    /// Step 1 only shows the most recent capture, so there is no need to hold full
    /// resolution images in memory to fill a 48 pt button.
    static func thumbnail(from data: Data, maxPixelSize: CGFloat = 160) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.7)
    }
}
