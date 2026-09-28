import Foundation
import ImageIO
import UIKit

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

    var errorDescription: String? {
        switch self {
        case .documentsUnavailable:
            return "The app's Documents directory is not available"
        case .writeFailed(let reason):
            return reason
        }
    }
}

/// Writes captures into the app container and nothing else.
///
/// Three deliberate choices:
///
/// - **Local only.** `IOS_CAMERA_APP_PLAN.md` section 14 says media stays on the device
///   by default and the gallery is Step 9, so nothing is added to the photo library here
///   and no library permission is needed.
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
        return saved
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
