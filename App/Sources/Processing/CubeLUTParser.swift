import Foundation

/// Parser for Adobe `.cube` files.
///
/// Kept free of Core Image, UIKit and file access so the whole of it is exercised by
/// unit tests on text alone. `LUTProcessor` consumes what this produces.
///
/// Two rules that shape the code:
///
/// - **Total.** Every input either produces a table or an error. There is no path that
///   returns a half-filled table, because a half-filled table is how you get a crash in
///   the render loop rather than a message in an import dialog.
/// - **No silent repair.** A sample outside the declared domain is an error, not a
///   clamped value. A LUT that needed clamping was authored against a domain this app
///   does not implement, and quietly accepting it would bake a wrong look into every
///   photo taken with that style.
enum CubeLUTParser {

    /// Hard ceiling on a table edge. A 65³ table is 2.7 M samples and roughly 11 MB of
    /// texture; 33³ is 36 k samples and is what shipping LUTs actually use.
    static let maximumSize = 33

    /// Smallest table that can be interpolated at all.
    static let minimumSize = 2

    /// The entry point a file import uses.
    ///
    /// Decoding lives here rather than at the call site so the failure has one honest
    /// name. A `.cube` is a text format; a JPEG renamed to `.cube` is the common way to
    /// arrive with bytes that are not text, and "not valid UTF-8" is the answer.
    static func parse(data: Data) throws -> CubeLUT {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CubeLUTError.notUTF8
        }
        return try parse(text: text)
    }

    static func parse(text: String) throws -> CubeLUT {
        var size: Int?
        var kind: CubeLUT.Kind?
        var title: String?
        var domainMin: [Float]?
        var domainMax: [Float]?
        var samples: [Float] = []
        /// The source line of each sample, so a per-sample error can name a real line
        /// rather than an offset the user has to count.
        var sampleLines: [Int] = []

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let line = stripComment(rawLine)
            guard !line.isEmpty else { continue }

            // A data line is one where every token parses as a number. Deciding it that
            // way rather than by looking for a leading keyword means a lowercase
            // directive and a data line that happens to start with a digit are both
            // handled correctly. No throwing here: meeting a directive is expected, not
            // an error, so detection is a question and not a failure.
            if let values = allNumbers(in: line) {
                try validate(values: values, on: lineNumber)
                samples.append(contentsOf: values)
                for _ in values { sampleLines.append(lineNumber) }
                continue
            }

            guard let keyword = leadingToken(in: line) else {
                throw CubeLUTError.malformedNumber(token: line, line: lineNumber)
            }
            switch keyword.uppercased() {
            case "TITLE":
                title = quotedValue(of: line)
            case "LUT_1D_SIZE":
                guard size == nil else { throw CubeLUTError.conflictingSizeDirectives(line: lineNumber) }
                size = try validatedSize(after: keyword, in: line, lineNumber)
                kind = .oneDimensional
            case "LUT_3D_SIZE":
                guard size == nil else { throw CubeLUTError.conflictingSizeDirectives(line: lineNumber) }
                size = try validatedSize(after: keyword, in: line, lineNumber)
                kind = .threeDimensional
            case "DOMAIN_MIN":
                domainMin = try values(after: keyword, in: line, lineNumber)
            case "DOMAIN_MAX":
                domainMax = try values(after: keyword, in: line, lineNumber)
            default:
                // An unknown **uppercase** keyword is a vendor extension and is skipped:
                // real `.cube` files carry them, and refusing them would reject valid
                // LUTs over a directive this app does not implement. The Adobe spec puts
                // every directive in caps, so casing is what separates a vendor keyword
                // from a corrupted sample. A lower-case token that is not a number and
                // not a known directive is data that has been damaged, and is reported.
                guard keyword == keyword.uppercased() else {
                    throw CubeLUTError.malformedNumber(token: keyword, line: lineNumber)
                }
                continue
            }
        }

        guard let size, let kind else {
            throw samples.isEmpty ? CubeLUTError.empty : CubeLUTError.noSizeDirective(line: 1)
        }
        guard !samples.isEmpty else { throw CubeLUTError.empty }

        // A DOMAIN pair only counts when both halves are present; one on its own is
        // ignored rather than half-applied, which is the same reasoning as the
        // conflicting-size rule.
        let declared = (domainMin != nil) && (domainMax != nil)
        if let domainMin, let domainMax,
           zip(domainMin, domainMax).contains(where: { $0 > $1 }) {
            throw CubeLUTError.domainBoundsInverted(line: 1)
        }

        let lut = CubeLUT(size: size,
                          kind: kind,
                          title: title,
                          domainMin: domainMin ?? [0, 0, 0],
                          domainMax: domainMax ?? [1, 1, 1],
                          domainWasDeclared: declared,
                          samples: samples)

        // Only checked when the file actually declared a domain. A table with no
        // DOMAIN lines is assumed to be 0…1, and refusing samples outside that would
        // reject perfectly ordinary tables that simply omit the line.
        if declared {
            let min = lut.domainMin
            let max = lut.domainMax
            guard min.count == 3, max.count == 3 else { throw CubeLUTError.domainBoundsInverted(line: 1) }
            for (offset, value) in samples.enumerated() {
                let channel = offset % 3
                if value < min[channel] || value > max[channel] {
                    throw CubeLUTError.sampleOutsideDeclaredDomain(line: sampleLines[offset])
                }
            }
        }

        guard lut.sampleCountMatchesSize else {
            throw CubeLUTError.sampleCountMismatch(expected: expectedSampleCount(for: lut),
                                                  found: lut.sampleCount)
        }
        return lut
    }

    static func expectedSampleCount(for lut: CubeLUT) -> Int {
        switch lut.kind {
        case .oneDimensional: return lut.size
        case .threeDimensional: return lut.size * lut.size * lut.size
        }
    }

    // MARK: - Line handling

    private static func stripComment(_ line: Substring) -> String {
        guard let hash = line.firstIndex(of: "#") else {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return line[line.startIndex..<hash].trimmingCharacters(in: .whitespaces)
    }

    private static func leadingToken(in line: String) -> String? {
        let head = line.prefix { !$0.isWhitespace }
        guard !head.isEmpty, head.allSatisfy({ $0.isLetter || $0 == "_" || $0.isNumber }) else {
            return nil
        }
        return String(head)
    }

    private static func quotedValue(of line: String) -> String {
        guard let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""),
              first < last else {
            return line
        }
        return String(line[line.index(after: first)..<last])
    }

    private static func validatedSize(after directive: String,
                                      in line: String,
                                      _ lineNumber: Int) throws -> Int {
        let rest = line.dropFirst(directive.count)
        guard let token = rest.split(whereSeparator: { $0.isWhitespace }).first else {
            throw CubeLUTError.malformedNumber(token: "", line: lineNumber)
        }
        guard let value = Int(token) else {
            throw CubeLUTError.malformedNumber(token: String(token), line: lineNumber)
        }
        guard value >= minimumSize, value <= maximumSize else {
            throw CubeLUTError.unsupportedSize(size: value, line: lineNumber)
        }
        return value
    }

    /// Every token on the line as a float, or `nil` when any token is not a number.
    private static func allNumbers(in line: String) -> [Float]? {
        let tokens = line.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return nil }
        var values: [Float] = []
        values.reserveCapacity(tokens.count)
        for token in tokens {
            guard let value = Float(token) else { return nil }
            values.append(value)
        }
        return values
    }

    /// The numbers that follow a directive keyword on the same line.
    ///
    /// The keyword itself is dropped first. Parsing the whole line would fail on
    /// `DOMAIN_MIN 0.0 0.0 0.0` because the keyword is not a number, which is how the
    /// first version of this parser rejected every table it was given.
    private static func values(after keyword: String,
                               in line: String,
                               _ lineNumber: Int) throws -> [Float] {
        let rest = line.dropFirst(keyword.count)
        return try floats(in: String(rest), lineNumber)
    }

    private static func floats(in line: String, _ lineNumber: Int) throws -> [Float] {
        let tokens = line.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return [] }
        return try tokens.map { token in
            guard let value = Float(token) else {
                throw CubeLUTError.malformedNumber(token: String(token), line: lineNumber)
            }
            return value
        }
    }

    /// Every data line is an RGB triplet. A file that emits anything else has been
    /// truncated, padded or hand-edited, and each of those produces a table that
    /// indexes past its own buffer at apply time — so it is rejected here instead.
    private static func validate(values: [Float], on lineNumber: Int) throws {
        guard values.count == CubeLUT.channelsPerSample else {
            throw CubeLUTError.wrongValueCount(expected: CubeLUT.channelsPerSample,
                                               found: values.count,
                                               line: lineNumber)
        }
        for value in values {
            guard value.isFinite else {
                throw CubeLUTError.malformedNumber(token: "\(value)", line: lineNumber)
            }
            guard value >= -65_504, value <= 65_504 else {
                throw CubeLUTError.valueOutOfRange(value: value, line: lineNumber)
            }
        }
    }
}
