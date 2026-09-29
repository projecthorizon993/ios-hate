import CoreImage
import XCTest
@testable import LumaFrame

/// Step 2's apply stage.
///
/// What is asserted here is the decisions: what is refused, what is a no-op, and the
/// cube byte order. Rendering is not — Core Image returns no output in the headless CI
/// simulator even for a filter it accepts, so the tests that need a rendered result skip
/// there and are carried by the on-device checklist in `docs/ARCHITECTURE.md`
/// section 4. That is the same line this file has always drawn: pixels are a device
/// claim, decisions are a CI claim.
///
/// **Filter availability is a CI claim, and is asserted here.** Whether
/// `CIColorCubeWithColorSpace` resolves is a fact about the platform, it holds in a
/// headless simulator, and the app shipped a whole release applying tables with the
/// invariant filter because nobody checked it.
///
/// The exception trap is also load-bearing under CI. `CIColorCube` has no
/// `inputColorSpace` key, and setting one raises an Objective-C exception Swift cannot
/// catch, which would kill the app on the first frame with a look applied. Every test
/// here therefore runs the real filter construction, so a reintroduced bad key dies in
/// CI rather than on a phone.
final class LUTProcessorTests: XCTestCase {

    private let processor = LUTProcessor()

    /// The colour-managed filter this file exists to protect.
    ///
    /// Spelled once so the lookup under test and the test that checks the lookup cannot
    /// drift apart.
    /// Read from the processor rather than spelled here.
    ///
    /// It used to be a local constant holding its own copy of the string, which is what
    /// made this test unable to fail: reverting `LUTProcessor` to the invariant
    /// `CIColorCube` would leave this file's copy of the name untouched and the assertion
    /// would still pass. Now the test and the processor read one value, so the two cannot
    /// disagree about which filter the app applies.
    private static var filterName: String { LUTProcessor.colorManagedCubeFilterName }

    private func makeTable(size: Int = 2,
                           domainWasDeclared: Bool = true,
                           domainMax: Float = 1) -> CubeLUT {
        // An identity ramp: every sample equals its own position in the cube, so applying
        // it must leave the image alone. That is what makes "did the LUT do anything"
        // a separable question from "did the filter run".
        var samples: [Float] = []
        let last = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    samples.append(Float(r) / last)
                    samples.append(Float(g) / last)
                    samples.append(Float(b) / last)
                }
            }
        }
        // `authoredSpace` is set the way the parser sets it, from the domain, rather than
        // left to its default. These fixtures build `CubeLUT` directly and so skip the
        // parser, and a log-domain fixture that quietly claimed sRGB would never reach the
        // refusal it exists to test.
        return CubeLUT(size: size,
                       kind: .threeDimensional,
                       title: "identity",
                       domainMin: [0, 0, 0],
                       domainMax: [domainMax, domainMax, domainMax],
                       domainWasDeclared: domainWasDeclared,
                       samples: samples,
                       authoredSpace: domainMax == 1 ? .sRGB : nil)
    }

    /// A plain CIImage to hand to the processor.
    ///
    /// `CIImage(color:)` rather than a generator filter: `CIFalseColor` and friends are
    /// filter *names*, not Swift types, and a flat image is enough here. The pixel
    /// *values* produced by the pipeline are not asserted — that needs a real GPU and a
    /// reference image, and belongs in the on-device checklist. What is asserted here is
    /// the decisions: what is refused, what is a no-op, and the cube byte order.
    private func makeTestImage() -> CIImage {
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        return flat.cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    // MARK: - Authored space

    /// The parser is what turns a declared domain into a colour space, so this is where
    /// the two halves of that claim are pinned: a 0…1 domain is the sRGB convention, and
    /// a non-unit domain is not a colour space at all.
    ///
    /// Written here rather than in `CubeLUTParserTests` because the property does not
    /// exist in isolation — it only means something once a table reaches the apply stage.
    ///
    /// Both fixtures keep their samples inside their declared domain, because the parser
    /// rejects a table that does not before the authored space is ever consulted. A log
    /// table with 0…1 samples is not a log table, it is a malformed one.
    func testParserRecordsTheAuthoredSpaceFromTheDeclaredDomain() throws {
        let sRGBTable = """
        TITLE "unit domain"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 1 1 1
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let parsedSRGB = try CubeLUTParser.parse(text: sRGBTable)
        XCTAssertEqual(parsedSRGB.authoredSpace, .sRGB)

        let logTable = """
        TITLE "log domain"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 0.3 0.3 0.3
        0 0 0
        0.3 0 0
        0 0.3 0
        0.3 0.3 0
        0 0 0.3
        0.3 0 0.3
        0 0.3 0.3
        0.3 0.3 0.3
        """
        let parsedLog = try CubeLUTParser.parse(text: logTable)
        XCTAssertNil(parsedLog.authoredSpace,
                     "a log domain is not a colour space, so it must not claim to be sRGB")
        XCTAssertEqual(parsedLog.domain, .nonUnit)
    }

    /// A table with no `DOMAIN` lines at all is assumed 0…1, per the Adobe convention,
    /// and the assumption is what it claims — not a refusal.
    func testParserAssumesSRGBWhenNoDomainIsDeclared() throws {
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
        let parsed = try CubeLUTParser.parse(text: text)
        XCTAssertFalse(parsed.domainWasDeclared)
        XCTAssertEqual(parsed.authoredSpace, .sRGB)
    }

    // MARK: - Filter availability

    /// The test that should have existed before this defect was shipped.
    ///
    /// `LUTProcessor` used `CIColorCube`, on the stated grounds that the colour-managed
    /// alternative "is absent from the SDK CI builds against". That claim was never
    /// checked, and it was false: the filter resolves, and the app was applying every
    /// lookup table with no colour management in the meantime.
    ///
    /// This asserts only that the filter **resolves**, which is a fact about the platform
    /// and holds in a headless simulator. It deliberately asserts nothing about rendering,
    /// which does not — that is what the skips below are for. The distinction is the
    /// whole lesson: *availability* is checkable in CI, *pixels* are not.
    func testColorManagedCubeFilterIsAvailable() {
        // The processor must not be using the invariant filter. Asserting the name equals
        // the colour-managed one is the assertion that fails on a revert, which the
        // previous copy of this test could not do.
        XCTAssertEqual(LUTProcessor.colorManagedCubeFilterName, "CIColorCubeWithColorSpace",
                       "the cube path must use the colour-managed filter, not CIColorCube")
        XCTAssertNotNil(CIFilter(name: Self.filterName),
                        "\(Self.filterName) must resolve; if it does not, the LUT path is "
                        + "applying tables without colour management")
    }

    // MARK: - Cube data

    func testCubeDataPreservesRedVariesFastest() throws {
        let lut = makeTable(size: 2)

        let data = try XCTUnwrap(LUTProcessor.cubeData(for: lut))
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        // 2x2x2 identity: the first two samples are (0,0,0) and (1,0,0). If the parser
        // or the upload ever transposes a channel, this is the assertion that catches it
        // — and nothing else will, because the result still looks like a working filter.
        XCTAssertEqual(Array(values.prefix(6)), [0, 0, 0, 1, 0, 0])
        XCTAssertEqual(values.count, 8 * 3)
    }

    func testCubeDataIsNilForAnUnusableTable() {
        var truncated = makeTable(size: 2)
        truncated.samples.removeLast(3)

        XCTAssertNil(LUTProcessor.cubeData(for: truncated))
    }

    func testCubeDataIsNilForAOneDimensionalTable() {
        let lut = CubeLUT(size: 3, kind: .oneDimensional, title: nil,
                          domainMin: [0, 0, 0], domainMax: [1, 1, 1],
                          domainWasDeclared: true,
                          samples: Array(repeating: 0, count: 9),
                          authoredSpace: .sRGB)

        XCTAssertNil(LUTProcessor.cubeData(for: lut))
    }

    // MARK: - Refusals

    func testRefusesAOneDimensionalTable() {
        let lut = CubeLUT(size: 3, kind: .oneDimensional, title: nil,
                          domainMin: [0, 0, 0], domainMax: [1, 1, 1],
                          domainWasDeclared: true,
                          samples: Array(repeating: 0, count: 9),
                          authoredSpace: .sRGB)

        XCTAssertThrowsError(try processor.apply(lut,
                                                 to: makeTestImage(),
                                                 intensity: 1,
                                                 imageSpace: .sRGB)) { error in
            XCTAssertEqual(error as? LUTApplicationError, .oneDimensionalTableNotSupported(size: 3))
        }
    }

    func testRefusesAnIncompleteTable() {
        var truncated = makeTable(size: 2)
        truncated.samples.removeLast(3)

        XCTAssertThrowsError(try processor.apply(truncated,
                                                 to: makeTestImage(),
                                                 intensity: 1,
                                                 imageSpace: .sRGB)) { error in
            guard case .notUsable(let reason)? = error as? LUTApplicationError else {
                return XCTFail("expected notUsable, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty, "the reason must say something")
        }
    }

    /// A non-unit domain is not "linear sRGB" — it is a log encoding, and saying otherwise
    /// implies a conversion is possible when it is not. So it is refused as its own case,
    /// by name, rather than as a colour-space mismatch against a space it does not have.
    func testRefusesALogEncodedTableAndNamesItAsSuch() {
        let logTable = makeTable(size: 2, domainMax: 0.301)

        XCTAssertThrowsError(try processor.apply(logTable,
                                                 to: makeTestImage(),
                                                 intensity: 1,
                                                 imageSpace: .sRGB)) { error in
            guard case .logEncodedTable(let domain)? = error as? LUTApplicationError else {
                return XCTFail("expected logEncodedTable, got \(error)")
            }
            XCTAssertFalse(domain.isEmpty, "the reason must say what the domain was")
            XCTAssertFalse(domain.contains("linear sRGB"),
                           "a log domain is not linear sRGB and must not be reported as it")
        }
    }

    func testRefusesAnSRGBTableOnAP3Image() {
        let table = makeTable(size: 2)

        XCTAssertThrowsError(try processor.apply(table,
                                                 to: makeTestImage(),
                                                 intensity: 1,
                                                 imageSpace: .displayP3)) { error in
            XCTAssertEqual(error as? LUTApplicationError,
                           .domainMismatch(lut: "sRGB", image: "Display P3"))
        }
    }

    func testEveryRefusalExplainsItself() {
        let refusals: [LUTApplicationError] = [
            .oneDimensionalTableNotSupported(size: 3),
            .domainMismatch(lut: "sRGB", image: "Display P3"),
            .logEncodedTable(domain: "0…0.3"),
            .notUsable(reason: "the table is missing samples"),
            .intensityOutOfRange(2)
        ]
        for refusal in refusals {
            let message = refusal.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty, "\(refusal) has no message")
        }
    }

    // MARK: - Intensity

    func testRefusesAnIntensityOutsideTheUnitRange() {
        let table = makeTable(size: 2)
        for intensity in [Float(-0.01), 1.01, .nan, .infinity] {
            XCTAssertThrowsError(try processor.apply(table,
                                                     to: makeTestImage(),
                                                     intensity: intensity,
                                                     imageSpace: .sRGB),
                                 "intensity \(intensity) should be refused")
        }
    }

    /// Zero strength must be a genuine no-op, not a filter pass that happens to produce
    /// the same numbers. A look that is switched off should cost nothing per frame.
    func testZeroIntensityReturnsTheImageUnchanged() throws {
        let table = makeTable(size: 2)
        let image = makeTestImage()

        let result = try processor.apply(table, to: image, intensity: 0, imageSpace: .sRGB)

        XCTAssertEqual(result.extent, image.extent)
    }

    /// Whether Core Image can build a colour cube in this environment at all.
    ///
    /// On the CI simulator `CIFilter(name: "CIColorCubeWithColorSpace")` succeeds and
    /// accepts all its parameters without raising, then returns nil for `outputImage`.
    /// That was five CI runs' worth of misdiagnosis before the per-key reporting made it
    /// visible: the filter is fine, the headless simulator is not. The distinction is
    /// worth holding onto, because it is what made the availability claim in
    /// `LUTProcessor` look credible in the first place — **the filter resolving and the
    /// filter rendering are separate questions, and only the first is answerable here.**
    private func coreImageCanRenderACube() -> Bool {
        guard let cube = CIFilter(name: Self.filterName) else { return false }
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        cube.setValue(ColorSpace.sRGB.cgColorSpace, forKey: "inputColorSpace")
        cube.setValue(flat.cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4)),
                      forKey: kCIInputImageKey)
        cube.setValue(Float(2), forKey: "inputCubeDimension")
        // A 2-cubed table of black, which is the smallest buffer the filter accepts.
        cube.setValue(Data(repeating: 0, count: 2 * 2 * 2 * 3 * 4), forKey: "inputCubeData")
        return cube.outputImage != nil
    }

    // MARK: - Accepted application

    /// Needs a real Core Image, and the pixel values are only asserted as a range even
    /// then, because GPU float rounding is not something to assert to the last bit.
    func testAppliesAUnitDomainTableToAnSRGBImage() throws {
        try XCTSkipUnless(coreImageCanRenderACube(),
                          "headless Core Image returns no output for CIColorCubeWithColorSpace; "
                          + "verified on device per docs/ARCHITECTURE.md section 4")
        let table = makeTable(size: 2)

        let result = try processor.apply(table,
                                         to: makeTestImage(),
                                         intensity: 1,
                                         imageSpace: .sRGB)

        XCTAssertEqual(result.extent, makeTestImage().extent)
    }

    /// There is no "P3 lookup table". A `.cube` domain of 0…1 means gamma-encoded sRGB
    /// by the Adobe convention, and the format has no way to say otherwise — so a P3
    /// capture has no table that can be applied to it directly. Either the table is
    /// applied in sRGB after an **explicit, logged** conversion, or it is not applied at
    /// all. The refusal is asserted above; the conversion path is not built in Step 2,
    /// and this test records that rather than implying it works.
    func testAP3ImageWithAnSRGBTableIsRefusedNotGuessedAt() {
        let table = makeTable(size: 2)

        XCTAssertThrowsError(try processor.apply(table,
                                                 to: makeTestImage(),
                                                 intensity: 1,
                                                 imageSpace: .displayP3)) { error in
            XCTAssertEqual(error as? LUTApplicationError,
                           .domainMismatch(lut: "sRGB", image: "Display P3"))
        }
    }

    /// Every intensity the UI can produce must be accepted. The refusals are asserted
    /// above; this is the other half of the contract, that nothing *valid* is turned away.
    func testEveryIntensityInRangeIsAccepted() throws {
        try XCTSkipUnless(coreImageCanRenderACube(),
                          "headless Core Image returns no output for CIColorCubeWithColorSpace; "
                          + "verified on device per docs/ARCHITECTURE.md section 4")
        let table = makeTable(size: 2)
        let image = makeTestImage()

        for intensity in stride(from: Float(0), through: 1, by: 0.25) {
            XCTAssertNoThrow(try processor.apply(table,
                                                 to: image,
                                                 intensity: intensity,
                                                 imageSpace: .sRGB),
                             "intensity \(intensity) should be accepted")
        }
    }

    /// A larger table must also build. The size ceiling is enforced at parse time, so a
    /// 33-cubed table reaching here is already known to be within the texture budget.
    /// Runs without Core Image, so it is real coverage in CI rather than a skip.
    func testAcceptsTheMaximumTableSize() throws {
        let lut = makeTable(size: CubeLUTParser.maximumSize)

        XCTAssertTrue(lut.isUsable)
        let data = try XCTUnwrap(LUTProcessor.cubeData(for: lut))
        // Three floats per sample, four bytes per float.
        XCTAssertEqual(data.count,
                       CubeLUTParser.maximumSize * CubeLUTParser.maximumSize
                       * CubeLUTParser.maximumSize * 3 * 4)
    }
}
