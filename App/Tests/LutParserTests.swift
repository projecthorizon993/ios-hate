import XCTest
@testable import LumaFrame

/// The engine's table ingestion, as pure decisions.
///
/// Parsing, interpolation and the upload shape are all arithmetic on values, so
/// every one of these executes in CI — the exact opposite of the old LUT path,
/// whose only executing tests skipped themselves. What CI still cannot do is
/// compare graded pixels against a reference tool; that stays a device check in
/// `docs/ENGINE_PLAN.md` §7.
final class LutParserTests: XCTestCase {

    private var tiny: String {
        """
        TITLE "Test 2x2x2"
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
    }

    /// File order is the sample order: red varies fastest, and the parser preserves
    /// it verbatim rather than transposing. A transposed table loads, reports itself
    /// applied, and colours every photo slightly wrong.
    func testSamplesKeepFileOrderRedVaryingFastest() throws {
        let parsed = try LutParser.parse(text: tiny)

        XCTAssertEqual(parsed.size, 2)
        XCTAssertEqual(parsed.samples, [0, 0, 0,
                                        1, 0, 0,
                                        0, 1, 0,
                                        1, 1, 0,
                                        0, 0, 1,
                                        1, 0, 1,
                                        0, 1, 1,
                                        1, 1, 1])
    }

    /// Titles carry spaces in real colourist files. A parser that rejects them
    /// rejects valid tables.
    func testTitleWithSpacesIsAccepted() throws {
        let parsed = try LutParser.parse(text: tiny)
        XCTAssertEqual(parsed.samples.count, 8 * 3)
    }

    func testEmptyFileIsRefused() {
        XCTAssertThrowsError(try LutParser.parse(text: "  \n ")) { error in
            XCTAssertEqual(error as? LutParseError, .empty)
        }
    }

    func testMissingSizeIsRefused() {
        XCTAssertThrowsError(try LutParser.parse(text: "TITLE x\n0.0 0.0 0.0\n")) { error in
            XCTAssertEqual(error as? LutParseError, .noSizeDirective)
        }
    }

    func testOneDimensionalTableIsRefused() {
        XCTAssertThrowsError(
            try LutParser.parse(text: "LUT_1D_SIZE 16\n0.0\n")) { error in
            XCTAssertEqual(error as? LutParseError, .oneDimensional(size: 16))
        }
    }

    func testSizeOutsideTheSupportedRangeIsRefused() {
        XCTAssertThrowsError(try LutParser.parse(text: "LUT_3D_SIZE 129\n")) { error in
            XCTAssertEqual(error as? LutParseError, .sizeOutOfRange(size: 129))
        }
    }

    /// A non-unit domain is log- or wide-encoded: no colour space to apply in, so no
    /// import rather than a silent misread.
    func testNonUnitDomainIsRefused() {
        let text = "LUT_3D_SIZE 2\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 100.0 100.0 100.0\n"
            + String(repeating: "0.0 0.0 0.0\n", count: 8)
        XCTAssertThrowsError(try LutParser.parse(text: text)) { error in
            XCTAssertEqual(error as? LutParseError, .nonUnitDomain)
        }
    }

    /// A non-unit input range is the same refusal through a different directive.
    func testNonUnitInputRangeIsRefused() {
        let text = "LUT_3D_SIZE 2\nLUT_3D_INPUT_RANGE 0.0 100.0\n"
            + String(repeating: "0.0 0.0 0.0\n", count: 8)
        XCTAssertThrowsError(try LutParser.parse(text: text)) { error in
            XCTAssertEqual(error as? LutParseError, .nonUnitDomain)
        }
    }

    /// The bad line is named, because "that file could not be used" with no line is
    /// unactionable for the person who exported it.
    func testAMalformedSampleReportsItsLine() {
        let text = "LUT_3D_SIZE 2\n0.0 0.0 0.0\n1.0 oops 0.0\n"
            + String(repeating: "0.0 0.0 0.0\n", count: 6)
        XCTAssertThrowsError(try LutParser.parse(text: text)) { error in
            XCTAssertEqual(error as? LutParseError, .invalidSample(line: 3))
        }
    }

    func testShortTableIsRefusedWithCounts() {
        XCTAssertThrowsError(
            try LutParser.parse(text: "LUT_3D_SIZE 2\n0.0 0.0 0.0\n")) { error in
            XCTAssertEqual(error as? LutParseError,
                           .wrongSampleCount(expected: 8, found: 1))
        }
    }

    func testUnknownDirectiveFailsByName() {
        XCTAssertThrowsError(try LutParser.parse(text: "LUT_3D_SIZE 2\nFUTURE_DIRECTIVE 1\n")) { error in
            XCTAssertEqual(error as? LutParseError,
                           .unknownDirective("FUTURE_DIRECTIVE", line: 2))
        }
    }

    /// Overshoot clamps: generated tables commonly touch 1.0001 at the edges, and
    /// that is not information worth refusing a file over.
    func testOvershootSamplesClampIntoRange() throws {
        let text = "LUT_3D_SIZE 2\n" + String(repeating: "1.0001 -0.0001 0.5\n", count: 8)
        let parsed = try LutParser.parse(text: text)
        XCTAssertEqual(parsed.samples[0], 1)
        XCTAssertEqual(parsed.samples[1], 0)
        XCTAssertEqual(parsed.samples[2], 0.5)
    }

    // MARK: - Interpolation and upload

    /// Strength 0 is the identity lattice, exactly — which is what makes 0% a
    /// provable no-op rather than a very small grade.
    func testZeroIntensityIsTheIdentityLattice() throws {
        let parsed = try LutParser.parse(text: tiny)
        let table = LutTable(size: parsed.size, samples: parsed.samples, space: .sRGB)

        XCTAssertEqual(table.interpolated(at: 0), table.identityLattice())
    }

    /// Full strength is the table untouched.
    func testFullIntensityIsTheTable() throws {
        let parsed = try LutParser.parse(text: tiny)
        let table = LutTable(size: parsed.size, samples: parsed.samples, space: .sRGB)

        XCTAssertEqual(table.interpolated(at: 1), parsed.samples)
    }

    /// Half strength is the midpoint between the lattice and the table, per sample.
    func testHalfIntensityIsTheMidpoint() {
        // A 2³ table that pushes red fully up: lattice red at the far corner is 1,
        // so the midpoint is still 1 there, but the near corner moves from 0 to 0.5.
        let pushed = LutTable(size: 2,
                              samples: [Float](repeating: 1, count: 8 * 3),
                              space: .sRGB)
        let mid = pushed.interpolated(at: 0.5)

        XCTAssertEqual(mid[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(mid[3], 1.0, accuracy: 0.0001)
    }

    /// The documented upload shape: `size³ × 4 × sizeof(Float)` bytes, alpha 1 in
    /// every fourth slot. A 17³ RGB buffer is 25% short of it, which is the exact
    /// shortage that made every old look a silent no-op.
    func testUploadBufferIsFourFloatsPerSample() throws {
        let parsed = try LutParser.parse(text: tiny)
        let table = LutTable(size: parsed.size, samples: parsed.samples, space: .sRGB)

        let data = try XCTUnwrap(table.rgbaData(intensity: 1))
        XCTAssertEqual(data.count, 2 * 2 * 2 * 4 * 4)
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        for i in stride(from: 3, to: floats.count, by: 4) {
            XCTAssertEqual(floats[i], 1, "alpha slot \(i) must be opaque")
        }
    }

    func testUnusableTableProducesNoBuffer() {
        let bad = LutTable(size: 2, samples: [0, 0, 0], space: .sRGB)
        XCTAssertFalse(bad.isUsable)
        XCTAssertNil(bad.rgbaData(intensity: 1))
    }

    // MARK: - Store names

    /// A file name that could escape the store comes back flat. An import must never
    /// be able to write outside `LUTs/`.
    func testSanitisedNamesCannotEscapeTheStore() {
        XCTAssertEqual(LutStore.sanitised(filename: "../Shared/photo.jpg"),
                       "photo.jpg.cube")
        XCTAssertNil(LutStore.sanitised(filename: ".."))
        XCTAssertNil(LutStore.sanitised(filename: "   "))
        XCTAssertEqual(LutStore.sanitised(filename: "My Table.CUBE"), "My Table.CUBE")
    }

    // MARK: - Recipe

    /// A table reference breaks identity and clamps its strength at the boundary.
    func testATableReferenceBreaksIdentityAndClamps() {
        var settings = ProcessingSettings.none
        settings.lut = LutReference(filename: "table.cube", intensity: 5, space: .sRGB)
        let clamped = settings.clamped()

        XCTAssertFalse(clamped.isIdentity)
        XCTAssertEqual(clamped.lut?.intensity, 1)

        var off = ProcessingSettings.none
        off.lut = LutReference(filename: "table.cube", intensity: 0, space: .sRGB)
        XCTAssertTrue(off.isIdentity, "zero strength must keep the direct preview path")
    }

    /// Colour spaces round-trip through words, never integers.
    func testColorSpacesRoundTripAsWords() throws {
        for space in [ColorSpace.sRGB, .displayP3, .linearSRGB] {
            let data = try JSONEncoder().encode(space)
            XCTAssertEqual(try JSONDecoder().decode(ColorSpace.self, from: data), space)
        }
        XCTAssertNil(ColorSpace.named("No Such Space"))
    }

    /// A table reference survives the file round trip a photo's metadata requires.
    func testATableReferenceSurvivesAFileRoundTrip() throws {
        var settings = ProcessingSettings.none
        settings.lut = LutReference(filename: "table.cube", intensity: 0.6, space: .sRGB)
        var metadata = CaptureMetadata(mode: "auto")
        metadata.processing = settings

        let (_, fields) = CaptureMetadata.parse(recipe: metadata.recipeString())
        let token = try XCTUnwrap(fields["proc"])
        XCTAssertEqual(CaptureMetadata.decodeProcessing(token), settings)
    }
}
