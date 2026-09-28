import Foundation

/// A `.cube` parse failure, with the line that caused it.
///
/// The line number is the whole point. A LUT that will not import is useless to a user
/// who cannot tell *why*, so every message either names a line or names the count that
/// did not match. `IOS_CAMERA_APP_PLAN.md` section 14 requires imported LUTs to be
/// validated and the plan's own rules require the failure to be recoverable rather than
/// fatal.
enum CubeLUTError: LocalizedError, Equatable {

    case empty
    case notUTF8
    case noSizeDirective(line: Int)
    case conflictingSizeDirectives(line: Int)
    case unsupportedSize(size: Int, line: Int)
    case malformedNumber(token: String, line: Int)
    case wrongValueCount(expected: Int, found: Int, line: Int)
    case sampleOutsideDeclaredDomain(line: Int)
    case domainBoundsInverted(line: Int)
    case sampleCountMismatch(expected: Int, found: Int)
    case valueOutOfRange(value: Float, line: Int)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The file contains no LUT data."
        case .notUTF8:
            return "The file is not valid UTF-8 text. A .cube is a plain text format, so a binary file with this extension cannot be read."
        case .noSizeDirective(let line):
            return "Line \(line): neither LUT_1D_SIZE nor LUT_3D_SIZE was declared, so the table size is unknown."
        case .conflictingSizeDirectives(let line):
            return "Line \(line): LUT_1D_SIZE and LUT_3D_SIZE are both declared. A table is one or the other."
        case .unsupportedSize(let size, let line):
            return "Line \(line): a \(size)-entry table is outside the range this app can apply. "
                + "Use between \(CubeLUTParser.minimumSize) and \(CubeLUTParser.maximumSize)."
        case .malformedNumber(let token, let line):
            return "Line \(line): \"\(token)\" is neither a number nor a known directive."
        case .wrongValueCount(let expected, let found, let line):
            return "Line \(line): every data line must hold \(expected) values, and this one holds \(found)."
        case .sampleOutsideDeclaredDomain(let line):
            return "Line \(line): a sample falls outside the DOMAIN_MIN…DOMAIN_MAX range the file itself declared."
        case .domainBoundsInverted(let line):
            return "Line \(line): DOMAIN_MIN is greater than DOMAIN_MAX."
        case .sampleCountMismatch(let expected, let found):
            return "The table declares \(expected) samples but contains \(found). The file looks truncated."
        case .valueOutOfRange(let value, let line):
            return "Line \(line): \(value) is outside the range a texture sample can hold."
        }
    }

    /// The line the failure is on, when there is one. Used to point at the offending
    /// line in the import preview.
    var line: Int? {
        switch self {
        case .empty, .notUTF8, .sampleCountMismatch:
            return nil
        case .noSizeDirective(let line),
             .conflictingSizeDirectives(let line),
             .unsupportedSize(_, let line),
             .malformedNumber(_, let line),
             .wrongValueCount(_, _, let line),
             .sampleOutsideDeclaredDomain(let line),
             .domainBoundsInverted(let line),
             .valueOutOfRange(_, let line):
            return line
        }
    }
}
