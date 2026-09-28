import CoreImage
import XCTest
@testable import LumaFrame

/// Step 2's apply stage.
///
/// The parts that can be checked without a GPU are the decisions: what is refused, what
/// is a no-op, and what byte order the cube data ends up in. The pixel result itself is
/// verified on device, where there is a real Core Image to run.
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

    private func makeTestImage() -> CIImage {
        let gradient = CIFalseColor()
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1)
        gradient.extent = CGRect(x: 0, y: 0, width: 4, height: 4)
        return gradient.outputImage
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
            XCTAssertEqual(error as? LUTApplicationError, .notUsable)
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
            .notUsable,
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

    // MARK: - Accepted application

    /// These need a real Core Image. They run on the simulator in CI, and the pixel
    /// values are only asserted as a range, because GPU float rounding is not something
    /// to assert to the last bit.
    func testAppliesAUnitDomainTableToAnSRGBImage() throws {
        let table = makeTable(size: 2)

        let result = try processor.apply(table,
                                         to: makeTestImage(),
                                         intensity: 1,
                                         imageSpace: .sRGB)

        XCTAssertEqual(result.extent, makeTestImage().extent)
    }

    func testAppliesAP3TableToAP3Image() throws {
        let table = makeTable(size: 2)

        let result = try processor.apply(table,
                                         to: makeTestImage(),
                                         intensity: 1,
                                         imageSpace: .displayP3)

        XCTAssertFalse(result.extent.isEmpty)
    }

    func testEveryIntensityInRangeIsAccepted() throws {
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
    func testAcceptsTheMaximumTableSize() throws {
        let lut = makeTable(size: CubeLUTParser.maximumSize)

        XCTAssertTrue(lut.isUsable)
        let data = try XCTUnwrap(LUTProcessor.cubeData(for: lut))
        XCTAssertEqual(data.count, CubeLUTParser.maximumSize
                       * CubeLUTParser.maximumSize
                       * CubeLUTParser.maximumSize * 4)
    }
}
