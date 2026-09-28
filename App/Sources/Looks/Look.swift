import Foundation

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
