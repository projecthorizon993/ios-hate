import AVFoundation
import CoreMedia
import Foundation
import ImageIO

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

    /// Never logged whole: it is the only place the file records a device-ish value and
    /// `AppLog` must not carry image content.
    var summariseForLog: String {
        "iso=\(ReportFormat.number(Double(iso ?? 0))) "
            + "shutter=\(ReportFormat.shutter(shutterSeconds ?? 0)) "
            + "quality=\(photoQualityPrioritization) proRAW=\(proRaw) raw=\(raw) "
            + "container=\(container) space=\(colorSpace)"
    }

    // MARK: - Recipe string

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
        return parts.joined(separator: ";")
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
