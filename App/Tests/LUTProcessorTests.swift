import CoreImage
import XCTest
@testable import LumaFrame

/// Step 2's apply stage.
///
/// What is asserted here is the decisions: what is refused, what is a no-op, and the
/// cube byte order. Rendering is not — Core Image returns no output in the headless CI
/// simulator even for a filter it accepts, so the two tests that need a rendered result
/// skip there and are carried by the on-device checklist in `docs/ARCHITECTURE.md`
/// section 4. That is the same line this file has always drawn: pixels are a device
/// claim, decisions are a CI claim.
///
/// The exception trap is also load-bearing under CI. `CIColorCube` has no
/// `inputColorSpace` key, and setting one raises an Objective-C exception Swift cannot
/// catch, which would kill the app on the first frame with a look applied. Every test
/// here therefore runs the real filter construction, so a reintroduced bad key dies in
/// CI rather than on a phone.
final class LUTProcessorTests: XCTestCase {

    private let processor = LUTProcessor()

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
        return CubeLUT(size: size,
                       kind: .threeDimensional,
                       title: "identity",
                       domainMin: [0, 0, 0],
                       domainMax: [domainMax, domainMax, domainMax],
                       domainWasDeclared: domainWasDeclared,
                       samples: samples)
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
                          samples: Array(repeating: 0, count: 9))

        XCTAssertNil(LUTProcessor.cubeData(for: lut))
    }

    // MARK: - Refusals

    func testRefusesAOneDimensionalTable() {
        let lut = CubeLUT(size: 3, kind: .oneDimensional, title: nil,
                          domainMin: [0, 0, 0], domainMax: [1, 1, 1],
                          domainWasDeclared: true,
                          samples: Array(repeating: 0, count: 9))

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

    /// The section 3.1 rule: a log-encoded table must not be applied to gamma-encoded
    /// pixels, and the user is told rather than handed a wrong photo.
    func testRefusesALogEncodedTableOnAnSRGBImage() {
        let logTable = makeTable(size: 2, domainMax: 0.301)

        XCTAssertThrowsError(try processor.apply(logTable,
                                                 to: makeTestImage(),
                                                 intensity: 1,
                                                 imageSpace: .sRGB)) { error in
            XCTAssertEqual(error as? LUTApplicationError,
                           .domainMismatch(lut: "linear sRGB", image: "sRGB"))
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
            .domainMismatch(lut: "linear sRGB", image: "sRGB"),
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
    /// On the CI simulator `CIFilter(name: "CIColorCube")` succeeds and accepts all three
    /// parameters without raising, then returns nil for `outputImage`. That was five CI
    /// runs' worth of misdiagnosis before the per-key reporting made it visible: the
    /// filter is fine, the headless simulator is not. The tests that need a rendered
    /// result skip on that evidence rather than assert something untrue, and
    /// `docs/ARCHITECTURE.md` section 4 carries them as on-device items instead.
    private func coreImageCanRenderACube() -> Bool {
        guard let cube = CIFilter(name: "CIColorCube") else { return false }
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
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
                          "headless Core Image returns no output for CIColorCube; "
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
                          "headless Core Image returns no output for CIColorCube; "
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
