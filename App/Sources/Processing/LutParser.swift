import Foundation

/// Why a `.cube` file was refused at import.
///
/// Refusal happens at import, loudly, with the reason — never at render time on a
/// frame the user is looking at. A table that cannot be proven correct is not
/// imported; there is no "best effort" path that renders a subtly wrong grade.
enum LutParseError: LocalizedError, Equatable {

    case empty
    case noSizeDirective
    case invalidSize(line: Int)
    case sizeOutOfRange(size: Int)
    case oneDimensional(size: Int)
    case unknownDirective(String, line: Int)
    case invalidDomain(line: Int)
    case nonUnitDomain
    case invalidSample(line: Int)
    case wrongSampleCount(expected: Int, found: Int)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "This file has no table data in it."
        case .noSizeDirective:
            return "This file declares no LUT_3D_SIZE, so its shape is unknown."
        case .invalidSize(let line):
            return "Line \(line): LUT_3D_SIZE is not a whole number."
        case .sizeOutOfRange(let size):
            return "Size \(size) is outside \(LutParser.minimumSize)…\(LutParser.maximumSize)."
        case .oneDimensional(let size):
            return "This is a 1D table of \(size) entries, which the 3D engine cannot apply."
        case .unknownDirective(let word, let line):
            return "Line \(line): \(word) is not a directive this importer knows."
        case .invalidDomain(let line):
            return "Line \(line): a domain needs three numbers per bound."
        case .nonUnitDomain:
            return "This table's domain is not 0…1, so it is log- or wide-encoded and has no colour space to be applied in."
        case .invalidSample(let line):
            return "Line \(line): a sample needs three numbers."
        case .wrongSampleCount(let expected, let found):
            return "This table holds \(found) samples but its size needs \(expected)."
        }
    }
}

/// Strict Adobe `.cube` parsing into engine tables.
///
/// Two deliberate generosities, both logged at the call site rather than hidden:
///
/// - `TITLE` accepts anything after the keyword, quoted or bare — real colourist
///   files put spaces in titles, and rejecting them rejects valid tables.
/// - Sample values are clamped to 0…1. Overshoot is common at the edges of
///   generated tables and is not information; non-finite values are refused.
enum LutParser {

    static let minimumSize = 2
    static let maximumSize = 64

    /// Parses `.cube` text into samples in file order (red varying fastest).
    ///
    /// The returned samples carry no colour space: the file cannot state one, so the
    /// space is declared by the importer and attached when the table is stored.
    static func parse(text: String) throws -> (size: Int, samples: [Float]) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LutParseError.empty
        }
        var size: Int?
        var domainMin: [Float]?
        var domainMax: [Float]?
        var samples: [Float] = []

        var lineNumber = 0
        for raw in text.components(separatedBy: .newlines) {
            lineNumber += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") { continue }
            // TITLE first: a title may contain anything, including words that look
            // like directives and a `#` that is not a comment.
            if line.uppercased().hasPrefix("TITLE") {
                let rest = line.dropFirst("TITLE".count).trimmingCharacters(in: .whitespaces)
                guard !rest.isEmpty else { throw LutParseError.invalidSample(line: lineNumber) }
                continue
            }

            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let head = tokens.first else { continue }
            let keyword = head.uppercased()

            switch keyword {
            case "LUT_3D_SIZE":
                guard tokens.count == 2, let value = Int(tokens[1]) else {
                    throw LutParseError.invalidSize(line: lineNumber)
                }
                guard value >= minimumSize, value <= maximumSize else {
                    throw LutParseError.sizeOutOfRange(size: value)
                }
                size = value
            case "LUT_1D_SIZE":
                // Refused the moment it is declared: a 1D table is a different
                // operation, not a smaller 3D one, and its data lines (one value
                // each) must never be validated as 3D samples first.
                guard tokens.count == 2, let value = Int(tokens[1]) else {
                    throw LutParseError.invalidSize(line: lineNumber)
                }
                throw LutParseError.oneDimensional(size: value)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard tokens.count == 4,
                      let x = Float(tokens[1]), let y = Float(tokens[2]), let z = Float(tokens[3]),
                      x.isFinite, y.isFinite, z.isFinite else {
                    throw LutParseError.invalidDomain(line: lineNumber)
                }
                if keyword == "DOMAIN_MIN" { domainMin = [x, y, z] } else { domainMax = [x, y, z] }
            case "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                // Adobe form is `KEYWORD min max`: anything outside 0…1 is a
                // log- or wide-encoded table with no colour space to apply in.
                guard tokens.count == 3,
                      let lo = Float(tokens[1]), let hi = Float(tokens[2]),
                      lo.isFinite, hi.isFinite else {
                    throw LutParseError.invalidDomain(line: lineNumber)
                }
                guard lo == 0, hi == 1 else { throw LutParseError.nonUnitDomain }
            default:
                // A data line is exactly three finite numbers. Anything else that
                // is not a known directive is malformed input — except a word
                // shaped like a directive (capitals, digits, underscores), which
                // is a newer directive failing by name rather than a bad sample.
                if tokens.count == 3,
                   let r = Float(tokens[0]),
                   let g = Float(tokens[1]),
                   let b = Float(tokens[2]),
                   r.isFinite, g.isFinite, b.isFinite {
                    samples.append(min(max(r, 0), 1))
                    samples.append(min(max(g, 0), 1))
                    samples.append(min(max(b, 0), 1))
                } else if tokens.count == 1, Self.isDirectiveShaped(head) {
                    throw LutParseError.unknownDirective(head, line: lineNumber)
                } else {
                    throw LutParseError.invalidSample(line: lineNumber)
                }
            }
        }

        guard let edge = size else { throw LutParseError.noSizeDirective }
        let min = domainMin ?? [0, 0, 0]
        let max = domainMax ?? [1, 1, 1]
        guard min == [0, 0, 0], max == [1, 1, 1] else { throw LutParseError.nonUnitDomain }
        let expected = edge * edge * edge * 3
        guard samples.count == expected else {
            throw LutParseError.wrongSampleCount(expected: expected / 3, found: samples.count / 3)
        }
        return (edge, samples)
    }

    /// Whether a word is shaped like a directive (capitals, digits, underscores)
    /// rather than data. Tested against the original case: "hello" has lowercase
    /// and is a bad sample, "FUTURE_DIRECTIVE" has none and is an unknown one.
    private static func isDirectiveShaped(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
    }
}
