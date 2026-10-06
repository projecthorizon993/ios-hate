import Foundation

/// Imported color tables on disk, owned by the engine.
///
/// `Documents/LUTs/` holds one validated `.cube` per file. The recipe records a
/// `LutReference` (file name, intensity, declared space); the samples are resolved
/// here at render time, so recipes stay small and a replaced file does not orphan
/// every photo that used it.
enum LutStore {

    static let directoryName = "LUTs"

    /// The store directory, created on first use. `nil` when the sandbox gives no
    /// Documents directory, in which case import is refused rather than guessed at.
    static func directory() -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else {
            return nil
        }
        let url = documents.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url,
                                                     withIntermediateDirectories: true)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Validates parsed samples and files them under a sanitised name.
    ///
    /// The space is declared by the importer (sRGB unless the user says otherwise):
    /// a `.cube` file cannot state one, and the engine bans inferring it.
    static func importTable(size: Int,
                            samples: [Float],
                            filename: String,
                            space: ColorSpace) -> LutReference? {
        guard let safe = sanitised(filename: filename),
              let directory = directory() else { return nil }
        let table = LutTable(size: size, samples: samples, space: space)
        guard table.isUsable else { return nil }
        let url = uniqueURL(for: safe, in: directory)
        guard let text = canonicalText(size: size, samples: samples),
              (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return LutReference(filename: url.lastPathComponent, intensity: 1, space: space)
    }

    /// Resolves a recipe reference to a table, or `nil` with a logged reason.
    ///
    /// Never throws: a missing or damaged file degrades to "no table", and the
    /// pipeline renders the original rather than the frame.
    static func resolve(_ reference: LutReference) -> LutTable? {
        guard let directory = directory() else { return nil }
        let url = directory.appendingPathComponent(reference.filename)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            AppLog.warn(AppLog.processing,
                         "color table missing: \(reference.filename); rendering original")
            return nil
        }
        guard let parsed = try? LutParser.parse(text: text) else {
            AppLog.warn(AppLog.processing,
                         "color table unreadable: \(reference.filename); rendering original")
            return nil
        }
        return LutTable(size: parsed.size, samples: parsed.samples, space: reference.space)
    }

    /// Deletes an imported table. Missing files are fine — the user asked for it
    /// gone, and it is.
    static func remove(_ reference: LutReference) {
        guard let directory = directory() else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(reference.filename))
    }

    /// A file name that cannot escape the store, collide silently, or smuggle a path.
    ///
    /// Pure so the traversal rule is unit tested: `../Shared/photo.jpg` must come out
    /// a flat name inside `LUTs/`, never a path.
    static func sanitised(filename: String) -> String? {
        var name = URL(fileURLWithPath: filename).lastPathComponent
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_ ."))
        name = String(name.unicodeScalars.filter(allowed.contains).map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if !name.lowercased().hasSuffix(".cube") { name += ".cube" }
        return name
    }

    /// A non-colliding destination: `table.cube`, then `table-2.cube`, and so on.
    /// Importing the same file twice must not silently replace the first copy.
    static func uniqueURL(for filename: String, in directory: URL) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(index).\(ext)")
            index += 1
        }
        return candidate
    }

    /// Re-emits validated samples as canonical `.cube` text, so the store holds
    /// exactly what the parser accepted — never the user's original bytes, which may
    /// carry directives the parser tolerated but did not need.
    static func canonicalText(size: Int, samples: [Float]) -> String? {
        guard size >= LutParser.minimumSize, samples.count == size * size * size * 3 else {
            return nil
        }
        var lines = ["TITLE \"LumaFrame imported table\"", "LUT_3D_SIZE \(size)"]
        var i = 0
        while i < samples.count {
            lines.append("\(samples[i]) \(samples[i + 1]) \(samples[i + 2])")
            i += 3
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
