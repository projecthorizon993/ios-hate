// The looks library: the value type, the built-in looks, the resolver and the thumbnailer.
//
// Look is what everything else depends on, so it leads. LookLibrary resolves a look to its table; GeneratedLooks holds the bundled ones; LookThumbnailer renders a chip image.
//
// Merged mechanically by scripts/consolidate.mjs. Declarations were moved whole and
// nothing was edited; see the commit message for the reasoning.
import Foundation
import CoreImage
import UIKit

// MARK: - model (was App/Sources/Looks/Look.swift)


/// A named look the user can apply, and where its table comes from.
///
/// A `Look` is a **reference**, not the table itself. The recipe in the capture metadata
/// stores a `Look`, and the table is resolved from disk when it is needed. Two reasons:
///
/// - The samples are a few hundred kilobytes of floats, and a photo's recipe has to be
///   small enough to live in image metadata.
/// - The recipe must survive the look being renamed or removed. A recipe that embedded
///   its samples would re-render fine forever, including for looks that no longer exist
///   in the app, which is the more useful behaviour for a photo.
struct Look: Equatable, Codable, Sendable, Identifiable, Hashable {

    /// Where the table lives.
    enum Source: Equatable, Codable, Sendable, Hashable {
        /// A table generated in code. There is no file, so nothing can go missing.
        case generated(Generated)
        /// A `.cube` file in the user's own Looks folder, by file name.
        case imported(filename: String)
    }

    /// The built-in tables, generated rather than shipped as assets.
    enum Generated: String, Equatable, Codable, Sendable, CaseIterable {
        case warmth
        case coolness
        case fadedFilm
        case noColour
        case liftedShadows
    }

    var name: String
    var source: Source

    /// `true` for a table the user brought, so the UI can group them and offer removal.
    var isImported: Bool {
        if case .imported = source { return true }
        return false
    }

    /// Stable across a rename, so a recipe keeps resolving after the user renames a look.
    var id: String {
        switch source {
        case .generated(let which): return "builtin:" + which.rawValue
        case .imported(let filename): return "imported:" + filename
        }
    }
}

extension Look.Generated {

    /// Display name. Separate from the raw value so the identifier stays stable if the
    /// wording changes, which it will.
    var displayName: String {
        switch self {
        case .warmth: return "Warmth"
        case .coolness: return "Coolness"
        case .fadedFilm: return "Faded Film"
        case .noColour: return "No Colour"
        case .liftedShadows: return "Lifted Shadows"
        }
    }

    /// A one-line description of what it does, for the looks grid.
    var blurb: String {
        switch self {
        case .warmth: return "Warmer midtones and highlights"
        case .coolness: return "Cooler shadows, neutral skin"
        case .fadedFilm: return "Raised blacks, softened contrast"
        case .noColour: return "Luminance only"
        case .liftedShadows: return "Shadow detail, flat highlights"
        }
    }

    var look: Look { Look(name: displayName, source: .generated(self)) }
}

// MARK: - library (was App/Sources/Looks/LookLibrary.swift)


/// Resolves a `Look` to a usable `CubeLUT`, and keeps the user's own tables.
///
/// Three jobs:
///
/// - Generate the built-in tables, once.
/// - Watch a folder of imported `.cube` files. iOS does not offer a document picker that
///   hands over a file the app may keep, and a copy into the app's own folder is both
///   simpler and survives the original being deleted.
/// - Cache, because a 17³ table is 49 KB of floats and rebuilding it per preview frame
///   would be the pipeline's dominant cost.
final class LookLibrary {

    /// Subdirectory of Documents for imported tables. Named for what is in it.
    static let directoryName = "Looks"

    /// The instance the app uses. `ProcessingPipeline` resolves looks through this, so
    /// the preview and the saved photo cannot end up reading different tables.
    static let shared = LookLibrary()

    private(set) var imported: [Look] = []
    private var cache: [Look: CubeLUT] = [:]
    private let lock = NSLock()

    /// Injected so tests can use a scratch directory.
    private let fileManager: FileManager
    private let documents: URL?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        refreshImported()
    }

    /// Every available look, built-ins first.
    var all: [Look] {
        Look.Generated.allCases.map(\.look) + imported
    }

    // There is deliberately no "Original" Look value. Original is the *absence* of a look
    // — `ProcessingSettings.look == nil` — and giving it a Look would mean an identity
    // table that has to be generated, resolved and applied at full intensity to produce
    // the unprocessed image. The version that existed briefly pointed at
    // `.liftedShadows`, which would have made the one control that must return the photo
    // to how it was captured apply a graded look instead.

    /// Resolves a look to a table, or `nil` with a logged reason.
    ///
    /// Never throws: a look that cannot be resolved has to degrade to "no look" rather
    /// than take the capture down with it.
    func resolve(_ look: Look) -> CubeLUT? {
        lock.lock()
        if let hit = cache[look] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let table: CubeLUT?
        switch look.source {
        case .generated(let which):
            table = GeneratedLooks.table(for: which)
        case .imported(let filename):
            table = loadImported(filename)
        }

        if let table, !table.isUsable {
            AppLog.fail(AppLog.processing, "look \(look.name) resolved to an unusable table")
            return nil
        }
        if table == nil {
            AppLog.fail(AppLog.processing, "look \(look.name) could not be resolved")
            return nil
        }

        lock.lock()
        cache[look] = table
        lock.unlock()
        return table
    }

    // MARK: - Import

    /// Copies an imported `.cube` into the app's own folder and returns the `Look`.
    ///
    /// Copies rather than references: the user picked the file out of Files or iCloud and
    /// has no expectation that deleting it there should break a look they already added,
    /// and a reference would need a security-scoped bookmark that stops working when the
    /// app is not running.
    @discardableResult
    func addImported(cube data: Data, filename: String) -> Look? {
        guard let directory = try? folder() else {
            AppLog.fail(AppLog.processing, "no folder for imported looks")
            return nil
        }
        // Only the last path component reaches the filesystem. An imported name is
        // untrusted input and a path with `../` in it must not escape the folder.
        let safe = (filename as NSString).lastPathComponent
        guard !safe.isEmpty, safe != ".", safe != ".." else {
            AppLog.fail(AppLog.processing, "rejected imported look name")
            return nil
        }
        let url = directory.appendingPathComponent(safe)

        // Validate before it is stored, so a broken file cannot sit in the library
        // looking importable and fail later on every capture.
        let parsed: CubeLUT
        do {
            parsed = try CubeLUTParser.parse(text: String(decoding: data, as: UTF8.self))
        } catch {
            AppLog.fail(AppLog.processing, "imported look \(safe) did not parse: \(error)")
            return nil
        }
        guard parsed.isUsable, parsed.kind == .threeDimensional else {
            AppLog.fail(AppLog.processing, "imported look \(safe) is not a usable 3D table")
            return nil
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.fail(AppLog.processing, "could not store imported look: \(error.localizedDescription)")
            return nil
        }

        let look = Look(name: parsed.title ?? (safe as NSString).deletingPathExtension,
                        source: .imported(filename: safe))
        lock.lock()
        cache[look] = parsed
        lock.unlock()

        AppLog.note(AppLog.processing,
                    "imported look \(look.name) as \(safe) at \(parsed.size)^3")
        refreshImported()
        return look
    }

    func removeImported(_ look: Look) {
        guard case .imported(let filename) = look.source, let directory = try? folder() else {
            return
        }
        let url = directory.appendingPathComponent((filename as NSString).lastPathComponent)
        try? fileManager.removeItem(at: url)
        lock.lock()
        cache[look] = nil
        lock.unlock()
        refreshImported()
    }

    // MARK: - Folder

    /// Re-reads the folder. Called at launch and after every import or removal.
    func refreshImported() {
        guard let directory = try? folder(),
              let names = try? fileManager.contentsOfDirectory(atPath: directory.path)
        else {
            imported = []
            return
        }
        imported = names
            .filter { $0.lowercased().hasSuffix(".cube") }
            .sorted()
            .map { Look(name: ($0 as NSString).deletingPathExtension,
                        source: .imported(filename: $0)) }
    }

    private func folder() throws -> URL {
        guard let documents else { throw PhotoStoreError.documentsUnavailable }
        let url = documents.appendingPathComponent(Self.directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    private func loadImported(_ filename: String) -> CubeLUT? {
        guard let directory = try? folder() else { return nil }
        let url = directory.appendingPathComponent((filename as NSString).lastPathComponent)
        guard let data = try? Data(contentsOf: url) else {
            AppLog.fail(AppLog.processing, "imported look \(filename) is missing from disk")
            return nil
        }
        return try? CubeLUTParser.parse(text: String(decoding: data, as: UTF8.self))
    }
}

// MARK: - generated (was App/Sources/Looks/GeneratedLooks.swift)


/// The built-in look tables, generated in code rather than shipped as `.cube` assets.
///
/// Three reasons this is not a folder of asset files:
///
/// - The app has working looks on first launch with nothing to download and no asset
///   pipeline to get wrong.
/// - A generated table can be exactly the size the pipeline wants and exactly the sample
///   order `CIColorCube` wants, so there is no byte-order question to get wrong per file.
/// - It is testable. "Warmth actually warms" is an assertion; "the asset is present" is
///   not.
///
/// All of them are 3D tables over the **unit sRGB domain**, which is what `LUTProcessor`
/// accepts. A generator that produced a non-unit domain would be refused at apply time,
/// so none of them do.
enum GeneratedLooks {

    /// Small enough to be free at preview rate, large enough not to band. 17 is the
    /// size the .cube format's own tooling defaults to.
    static let size = 17

    /// Builds the table for a generated look.
    static func table(for which: Look.Generated) -> CubeLUT? {
        let size = self.size
        var samples: [Float] = []
        samples.reserveCapacity(size * size * size * CubeLUT.channelsPerSample)
        let denominator = Float(max(1, size - 1))

        // Red varies fastest, which is the order `CIColorCube` expects and the order the
        // parser preserves. Getting this wrong produces a plausible-looking image with
        // the channels transposed, so it is stated here rather than left to the loops.
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let red = Float(r) / denominator
                    let green = Float(g) / denominator
                    let blue = Float(b) / denominator
                    samples.append(contentsOf: transform(red, green, blue, which))
                }
            }
        }

        let table = CubeLUT(size: size,
                            kind: .threeDimensional,
                            title: which.displayName,
                            domainMin: [0, 0, 0],
                            domainMax: [1, 1, 1],
                            domainWasDeclared: true,
                            samples: samples)
        return table.isUsable ? table : nil
    }

    /// The per-pixel transform, in gamma-encoded sRGB because that is the unit domain the
    /// table is declared over and the space `LUTProcessor` will apply it in.
    ///
    /// Every intermediate is a named `Float` with an explicit type. Written as nested
    /// expressions these are `Float` / `CGFloat` literals being multiplied by inferred
    /// doubles, and the compiler's type checker gives up on them — the error is
    /// "unable to type-check this expression in reasonable time" pointing at arithmetic
    /// that is arithmetically trivial. Naming the intermediates is also what makes the
    /// intent of each look readable.
    private static func transform(_ red: Float, _ green: Float, _ blue: Float,
                                  _ which: Look.Generated) -> [Float] {
        switch which {
        case .warmth:
            let r: Float = red + 0.045
            let g: Float = green + 0.012
            let b: Float = blue - 0.030
            return [clamp01(r), clamp01(g), clamp01(b)]

        case .coolness:
            let r: Float = red - 0.030
            let g: Float = green + 0.005
            let b: Float = blue + 0.050
            return [clamp01(r), clamp01(g), clamp01(b)]

        case .fadedFilm:
            // Pulled toward mid grey, which is what "lifted blacks, softened contrast"
            // means, plus a small warmth so it does not go dead.
            let lift: Float = 0.07
            let keep: Float = 1 - lift
            let r: Float = red * keep + lift + 0.012
            let g: Float = green * keep + lift + 0.004
            let b: Float = blue * keep + lift - 0.006
            return [clamp01(r), clamp01(g), clamp01(b)]

        case .noColour:
            // Rec. 709 luma, then a touch of lift so it is not crushed.
            let luma: Float = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            let value: Float = clamp01(luma * 0.94 + 0.03)
            return [value, value, value]

        case .liftedShadows:
            // Shadows lifted, highlights rolled off rather than clipped.
            let shadow: Float = shadowWeight(red, green, blue) * 0.10
            let highlight: Float = highlightWeight(red, green, blue) * 0.16
            let r: Float = red + shadow - highlight
            let g: Float = green + shadow - highlight
            let b: Float = blue + shadow - highlight
            return [clamp01(r), clamp01(g), clamp01(b)]
        }
    }

    /// 1 in the deepest shadows, 0 in the midtones and above.
    private static func shadowWeight(_ red: Float, _ green: Float, _ blue: Float) -> Float {
        let luma: Float = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let scaled: Float = luma / 0.35
        return max(0, 1 - scaled)
    }

    /// 1 in the highlights, 0 below the midpoint.
    private static func highlightWeight(_ red: Float, _ green: Float, _ blue: Float) -> Float {
        let luma: Float = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let scaled: Float = (luma - 0.55) / 0.45
        return max(0, scaled)
    }

    /// Samples must land inside 0…1. `CIColorCube` does not clamp, and an out-of-range
    /// table produces a black or blown frame rather than an error.
    private static func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}

// MARK: - thumbnails (was App/Sources/Looks/LookThumbnailer.swift)




/// Renders a small preview of each look, so the carousel shows the looks rather than
/// naming them.
///
/// The design spec asks for "live thumbnails" in the style carousel. The honest
/// interpretation is **live enough, not per frame**: each thumbnail is the current frame
/// pushed through one look at full strength, recomputed when the recipe or the source
/// frame changes, on a background queue.
///
/// Not per frame, and deliberately. There are five built-ins plus whatever the user has
/// imported, each needing a full `CIColorCube` pass over a small image. Doing that 30 times
/// a second to animate a thumbnail strip would cost more than the preview itself, and the
/// thumbnails would still look identical between updates — the user is choosing a look, not
/// tracking a moving subject.
enum LookThumbnailer {

    /// Square thumbnails; the carousel is a fixed-size strip so a non-square crop would
    /// change every tile's aspect as looks are added.
    static let size: CGFloat = 96

    /// Below this, recomputing is not worth the queue hop.
    static let minimumInterval: Double = 0.5

    private static let queue = DispatchQueue(label: "com.example.LumaFrame.thumbnails",
                                             qos: .utility)

    private static var lastRun: Double = 0
    private static let stateLock = NSLock()

    /// Renders `looks` against `source` and calls `onResult` on the main queue.
    ///
    /// Rate-limited rather than debounced: a debounce would postpone the update until the
    /// user stopped dragging, which is exactly when they are looking at the strip least.
    static func render(looks: [Look],
                       source: CIImage,
                       recipe: ProcessingSettings,
                       library: LookLibrary = .shared,
                       now: Double = Date().timeIntervalSince1970,
                       completion: @escaping ([Look: UIImage]) -> Void) {
        stateLock.lock()
        if now - lastRun < minimumInterval {
            stateLock.unlock()
            return
        }
        lastRun = now
        stateLock.unlock()

        let target = source.transformed(by: CGAffineTransform(
            scaleX: size / max(1, source.extent.width),
            y: size / max(1, source.extent.height)))
        let cropped = target.cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let settings = looks.map { look -> (Look, ProcessingSettings) in
            var one = recipe
            one.look = look
            // Full strength: a thumbnail at the user's current intensity would show every
            // tile identically dark and tell them nothing about which is which.
            one.lookIntensity = 1
            one.subjectMask = nil
            one.grain = 0
            one.sharpen = 0
            return (look, one)
        }

        queue.async {
            let pipeline = ProcessingPipeline(library: library)
            let context = CIContext(options: [.cacheIntermediates: false])
            var images: [Look: UIImage] = [:]
            for (look, one) in settings {
                let rendered = pipeline.renderOrOriginal(cropped,
                                                        settings: one,
                                                        inputSpace: .sRGB,
                                                        outputSpace: .sRGB)
                guard let cgImage = context.createCGImage(rendered, from: rendered.extent) else {
                    continue
                }
                images[look] = UIImage(cgImage: cgImage)
            }
            DispatchQueue.main.async { completion(images) }
        }
    }

    /// A neutral placeholder tile, so a look whose table is missing still occupies a slot
    /// instead of collapsing the strip and moving every other tile under the finger.
    ///
    /// `UIColor(_:)` rather than reaching for a colour method directly: the theme's tokens
    /// are `SwiftUI.Color`, because that is what the rest of the UI needs, and
    /// `UIGraphicsImageRenderer` wants a `UIColor`. Keeping one source of truth for the
    /// colour means this has to convert rather than re-declaring the hex.
    static func placeholder() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            UIColor(Theme.ColorToken.surfaceRaised).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }
}
