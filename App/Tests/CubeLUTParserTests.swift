import XCTest
@testable import LumaFrame

/// Step 2's parser tests. Every case is text-only, so none of this needs a device,
/// which is the point: a `.cube` that is going to be rejected should be rejected by CI.
final class CubeLUTParserTests: XCTestCase {

    /// A minimal but genuinely valid 2x2x2 table, which is the smallest thing a LUT
    /// can be. Written out rather than generated so a change to the format is visible
    /// in the test rather than hidden in a loop.
    private let valid2x2x2 = """
    # LumaFrame test table
    TITLE "2x2x2 identity"
    LUT_3D_SIZE 2
    DOMAIN_MIN 0.0 0.0 0.0
    DOMAIN_MAX 1.0 1.0 1.0
    0.0 0.0 0.0
    1.0 0.0 0.0
    0.0 1.0 0.0
    1.0 1.0 0.0
    0.0 0.0 1.0
    1.0 0.0 1.0
    0.0 1.0 1.0
    1.0 1.0 1.0
    """

    // MARK: - Happy path

    func testParsesAValidTable() throws {
        let lut = try CubeLUTParser.parse(text: valid2x2x2)

        XCTAssertEqual(lut.kind, .threeDimensional)
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.title, "2x2x2 identity")
        XCTAssertTrue(lut.domainWasDeclared)
        XCTAssertEqual(lut.domain, .unit)
        XCTAssertEqual(lut.sampleCount, 8)
        XCTAssertTrue(lut.isUsable)
    }

    func testRedChannelVariesFastest() throws {
        // CIColorCube expects exactly this ordering. If it ever changed, the LUT would
        // still parse and still report itself usable, and every photo would come out
        // subtly wrong — so the ordering is asserted directly.
        let lut = try CubeLUTParser.parse(text: valid2x2x2)

        XCTAssertEqual(Array(lut.samples.prefix(6)), [0, 0, 0, 1, 0, 0])
    }

    func testCommentsAndBlankLinesAreIgnored() throws {
        var text = valid2x2x2
        text += "\n\n   \n# trailing comment\n"

        let lut = try CubeLUTParser.parse(text: text)

        XCTAssertEqual(lut.sampleCount, 8)
    }

    /// A `.cube` with no DOMAIN lines is the common case and means sRGB 0…1. That is an
    /// assumption, so it has to be visible rather than implied.
    func testAbsentDomainDefaultsToUnitAndSaysItWasAssumed() throws {
        let text = """
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """

        let lut = try CubeLUTParser.parse(text: text)

        XCTAssertFalse(lut.domainWasDeclared)
        XCTAssertEqual(lut.domain, .unit)
        XCTAssertEqual(lut.domainMin, [0, 0, 0])
        XCTAssertEqual(lut.domainMax, [1, 1, 1])
    }

    func testLowercaseDirectivesStillParse() throws {
        let text = """
        lut_3d_size 2
        title "lowercase"
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """

        let lut = try CubeLUTParser.parse(text: text)

        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.title, "lowercase")
    }

    func testUnknownVendorDirectivesAreTolerated() throws {
        // Real .cube files carry vendor extensions. Refusing them would reject valid
        // LUTs over a keyword this app simply does not implement.
        let text = """
        TITLE "with vendor block"
        LUT_3D_SIZE 2
        VENDOR_3D_LUT "whatever"
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """

        let lut = try CubeLUTParser.parse(text: text)

        XCTAssertTrue(lut.isUsable)
    }

    func testParsesAOneDimensionalTable() throws {
        let text = """
        LUT_1D_SIZE 3
        0.0 0.0 0.0
        0.5 0.5 0.5
        1.0 1.0 1.0
        """

        let lut = try CubeLUTParser.parse(text: text)

        XCTAssertEqual(lut.kind, .oneDimensional)
        XCTAssertEqual(lut.size, 3)
        XCTAssertEqual(lut.sampleCount, 3)
    }

    // MARK: - Validation

    func testEmptyFileIsRejected() {
        assertThrows(.empty, text: "")
        assertThrows(.empty, text: "   \n\n# only a comment\n")
    }

    func testDataWithNoSizeDirectiveIsRejected() {
        assertThrows(.noSizeDirective(line: 1), text: "0 0 0\n1 0 0\n")
    }

    func testBothSizeDirectivesIsRejected() {
        assertThrows(.conflictingSizeDirectives(line: 2),
                     text: "LUT_1D_SIZE 2\nLUT_3D_SIZE 2\n0 0 0\n")
    }

    func testOversizedTableIsRejectedWithItsSize() {
        assertThrows(.unsupportedSize(size: 65, line: 1), text: "LUT_3D_SIZE 65\n")
    }

    func testUndersizedTableIsRejected() {
        assertThrows(.unsupportedSize(size: 1, line: 1), text: "LUT_3D_SIZE 1\n")
    }

    func testNonNumericSampleIsRejectedWithItsLine() {
        let text = """
        LUT_3D_SIZE 2
        0 0 0
        banana
        """

        assertThrows(.malformedNumber(token: "banana", line: 3), text: text)
    }

    /// A data line that is not an RGB triplet is the shape of a truncated or
    /// hand-edited file, and accepting it produces a table that reads past its buffer
    /// when applied.
    func testWrongValueCountIsRejected() {
        let text = """
        LUT_3D_SIZE 2
        0 0 0
        1 0
        """

        assertThrows(.wrongValueCount(expected: 3, found: 2, line: 3), text: text)
    }

    func testSampleCountMismatchIsRejected() {
        // Declares 2x2x2 but only supplies four triplets.
        let text = """
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        """

        assertThrows(.sampleCountMismatch(expected: 8, found: 4), text: text)
    }

    func testNonFiniteSampleIsRejected() throws {
        // "nan" is what a spreadsheet export of an empty cell looks like, and Float
        // happily parses it.
        let text = """
        LUT_3D_SIZE 2
        0 0 0
        nan 0 0
        """

        XCTAssertThrowsError(try CubeLUTParser.parse(text: text))
    }

    func testInvertedDomainIsRejected() {
        let text = """
        LUT_3D_SIZE 2
        DOMAIN_MIN 1.0 0.0 0.0
        DOMAIN_MAX 0.0 1.0 1.0
        0 0 0
        """

        XCTAssertThrowsError(try CubeLUTParser.parse(text: text))
    }

    /// A non-unit domain is the signature of a log-encoded LUT. It parses, because
    /// rejecting it would be wrong, but it is reported so the apply stage can refuse to
    /// treat it as gamma-encoded sRGB.
    func testLogEncodedDomainIsFlaggedRatherThanRejected() throws {
        let text = """
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 0.301 0.301 0.301
        0.0 0.0 0.0
        0.301 0.0 0.0
        0.0 0.301 0.0
        0.301 0.301 0.0
        0.0 0.0 0.301
        0.301 0.0 0.301
        0.0 0.301 0.301
        0.301 0.301 0.301
        """

        let lut = try CubeLUTParser.parse(text: text)

        XCTAssertEqual(lut.domain, .nonUnit)
        XCTAssertTrue(lut.isUsable)
    }

    /// A sample outside the domain the file declared means the file is internally
    /// inconsistent. Clamping it would silently bake a wrong look into every photo, so
    /// it is an error that names the offending line.
    func testSampleOutsideDeclaredDomainIsRejectedWithItsLine() {
        let text = """
        TITLE "inconsistent"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.4 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """

        assertThrows(.sampleOutsideDeclaredDomain(line: 7), text: text)
    }

    /// A lower-case token that is neither a number nor a known directive is damaged data,
    /// not a vendor extension. The Adobe spec puts directives in caps, so casing is what
    /// tells the two apart.
    func testLowerCaseGarbageIsReportedRatherThanSkipped() {
        let text = """
        LUT_3D_SIZE 2
        0 0 0
        oops 0 0
        """

        assertThrows(.malformedNumber(token: "oops", line: 3), text: text)
    }

    // MARK: - Model invariants

    func testUsabilityRequiresTheSampleCountToMatch() throws {
        var lut = try CubeLUTParser.parse(text: valid2x2x2)
        XCTAssertTrue(lut.isUsable)

        lut.samples.removeLast(3)

        XCTAssertFalse(lut.isUsable, "a short table must never report itself usable")
    }

    func testEveryErrorMessageNamesSomethingActionable() {
        let errors: [CubeLUTError] = [
            .empty, .notUTF8,
            .noSizeDirective(line: 1), .conflictingSizeDirectives(line: 2),
            .unsupportedSize(size: 65, line: 1),
            .malformedNumber(token: "x", line: 3),
            .wrongValueCount(expected: 3, found: 2, line: 4),
            .sampleOutsideDeclaredDomain(line: 5),
            .domainBoundsInverted(line: 1),
            .sampleCountMismatch(expected: 8, found: 4),
            .valueOutOfRange(value: 1e9, line: 6)
        ]
        for error in errors {
            let message = error.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty, "\(error) has no message")
            // A user who cannot tell why cannot fix it. The three errors with no
            // location are the ones that genuinely have none: an empty file, a file
            // that is not text, and a whole-file count mismatch.
            switch error {
            case .empty, .notUTF8, .sampleCountMismatch:
                XCTAssertFalse(message.contains("Line"),
                               "\(error) claims a line it cannot have")
            default:
                XCTAssertNotNil(error.line, "\(error) has no line but is not a whole-file failure")
                XCTAssertTrue(message.contains("Line"), "\(error) gives no location: \(message)")
            }
        }
    }

    // MARK: - Helper

    private func assertThrows(_ expected: CubeLUTError, text: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        do {
            let lut = try CubeLUTParser.parse(text: text)
            XCTFail("expected \(expected) but parsed a table of \(lut.sampleCount) samples",
                    file: file, line: line)
        } catch let error as CubeLUTError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
