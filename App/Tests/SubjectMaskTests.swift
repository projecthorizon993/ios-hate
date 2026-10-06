import CoreVideo
import XCTest
@testable import LumaFrame

/// The subject gate and the statistics behind it.
///
/// The Vision request itself needs a device to mean anything, so what is pinned
/// here is everything around it: the usability rule, the clamping, the recipe
/// behaviour — and the sampling math, which runs headless against synthetic
/// buffers and executes every line it covers.
final class SubjectMaskTests: XCTestCase {

    // MARK: - Usability

    func testEmptyAndFullCoverageAreUnusable() {
        XCTAssertFalse(SubjectStat(coverage: 0, confidence: 0.9).isUsable)
        XCTAssertFalse(SubjectStat(coverage: 1, confidence: 0.9).isUsable,
                       "a full-frame mask is no background to blend against")
        XCTAssertFalse(SubjectStat(coverage: 0.99, confidence: 0.9).isUsable)
    }

    func testPlausibleMasksAreUsable() {
        XCTAssertTrue(SubjectStat(coverage: 0.3, confidence: 0.8).isUsable)
        XCTAssertTrue(SubjectStat(coverage: 0.92, confidence: 0.8).isUsable,
                      "a close-up filling most of the frame is still a subject")
    }

    func testLowConfidenceIsUnusable() {
        XCTAssertFalse(SubjectStat(coverage: 0.3, confidence: 0.1).isUsable)
        XCTAssertTrue(SubjectStat(coverage: 0.3, confidence: 0.2).isUsable)
    }

    func testDecisionsNameTheRejection() {
        XCTAssertEqual(SubjectStat(coverage: 0, confidence: 0).decision(), "no subject")
        XCTAssertEqual(SubjectStat(coverage: 1, confidence: 0.9).decision(), "covers the frame")
        XCTAssertEqual(SubjectStat(coverage: 0.3, confidence: 0.1).decision(), "low confidence")
        XCTAssertEqual(SubjectStat(coverage: 0.3, confidence: 0.8).decision(), "blend 30%")
    }

    func testStatisticsClamp() {
        let clamped = SubjectStat(coverage: .nan, confidence: 9).clamped()
        XCTAssertEqual(clamped.coverage, 0)
        XCTAssertEqual(clamped.confidence, 1)
    }

    // MARK: - Recipe

    /// Statistics alone never break identity: without an active table there is
    /// nothing to blend, so a stats-only recipe still gets the direct preview.
    func testStatisticsAloneKeepTheIdentityPath() {
        var settings = ProcessingSettings.none
        settings.subject = SubjectStat(coverage: 0.3, confidence: 0.8)
        XCTAssertTrue(settings.clamped().isIdentity)
        XCTAssertEqual(settings.summarise(), "subject(blend 30%)",
                       "recorded, but not rendered without a table")
    }

    func testStatisticsSurviveAFileRoundTrip() throws {
        var settings = ProcessingSettings.none
        settings.lut = LutReference(filename: "table.cube", intensity: 0.6, space: .sRGB)
        settings.subject = SubjectStat(coverage: 0.3, confidence: 0.8)
        var metadata = CaptureMetadata(mode: "auto")
        metadata.processing = settings

        let (_, fields) = CaptureMetadata.parse(recipe: metadata.recipeString())
        let token = try XCTUnwrap(fields["proc"])
        XCTAssertEqual(CaptureMetadata.decodeProcessing(token), settings)
    }

    // MARK: - Sampling math

    private func buffer(values: [UInt8], width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_OneComponent8, nil,
                                  &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                pointer[y * bytesPerRow + x] = values[y * width + x]
            }
        }
        return buffer
    }

    /// Half subject, half background: coverage one half, confidence high.
    func testStatisticsReadCoverageFromPixels() throws {
        let buffer = try XCTUnwrap(buffer(values: [255, 255, 255, 255,
                                                   255, 255, 255, 255,
                                                   0, 0, 0, 0,
                                                   0, 0, 0, 0],
                                         width: 4, height: 4))
        let stats = PersonSegmentation.statistics(of: buffer)
        XCTAssertEqual(stats.coverage, 0.5, accuracy: 0.01)
        XCTAssertTrue(stats.isUsable)
    }

    /// All foreground is no background to blend against — the exact case the
    /// field log showed on every empty framing.
    func testUniformBufferIsUnusable() throws {
        let buffer = try XCTUnwrap(buffer(values: [UInt8](repeating: 255, count: 16),
                                         width: 4, height: 4))
        let stats = PersonSegmentation.statistics(of: buffer)
        XCTAssertEqual(stats.coverage, 1, accuracy: 0.01)
        XCTAssertFalse(stats.isUsable)
    }

    /// The mask converts to an image at the frame's size: every mask pixel has
    /// to land on the frame pixel it describes, so scale, never crop.
    func testMaskImageMatchesTheFrameExtent() throws {
        let buffer = try XCTUnwrap(buffer(values: [UInt8](repeating: 128, count: 16),
                                         width: 4, height: 4))
        let snapshot = SubjectMaskSnapshot(stats: SubjectStat(coverage: 0.5, confidence: 0.8),
                                           buffer: buffer)
        let image = try XCTUnwrap(snapshot.image(matching: CGRect(x: 0, y: 0, width: 8, height: 8)))
        XCTAssertEqual(image.extent.width, 8, accuracy: 0.01)
        XCTAssertEqual(image.extent.height, 8, accuracy: 0.01)
    }
}
