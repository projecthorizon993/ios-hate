import Foundation

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
