import AVFoundation
import ImageIO
import XCTest
@testable import LumaFrame

/// Step 1's unit tests cover the arithmetic and the gating rules, which are the parts
/// that are wrong in ways a device test will not catch. Everything that needs a real
/// sensor is verified through the capability report instead.
final class CameraStep1Tests: XCTestCase {

    // MARK: - Fixtures

    private func makeCamera(_ uniqueID: String,
                            kind: BackCameraCapabilities.Kind,
                            focalLength35mm: Double,
                            virtualZoomFactors: [Double] = [],
                            flash: Bool = false) -> BackCameraCapabilities {
        BackCameraCapabilities(uniqueID: uniqueID,
                               kind: kind,
                               focalLength35mm: focalLength35mm,
                               virtualZoomFactors: virtualZoomFactors,
                               minimumFocusDistance: -1,
                               flashAvailable: flash)
    }

    private func makeTripleLens() -> CameraCapabilities {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [
            makeCamera("uw", kind: .ultraWide, focalLength35mm: 13),
            makeCamera("w", kind: .wide, focalLength35mm: 24, virtualZoomFactors: [1, 2, 3, 4, 5], flash: true),
            makeCamera("t", kind: .telephoto, focalLength35mm: 77)
        ]
        capabilities.rawPixelTypes = [0x31324241]
        capabilities.proRawSupported = true
        capabilities.photoQualitySupported = true
        capabilities.highestPhotoQualitySupported = true
        capabilities.videoHDRSupported = true
        return capabilities
    }

    // MARK: - Gating: hide, disable, never simulate

    func testSingleBackCameraHasNoLensSelector() {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [makeCamera("w", kind: .wide, focalLength35mm: 24)]

        XCTAssertFalse(capabilities.lensSelector.isAvailable)
        XCTAssertEqual(capabilities.lensSelector.reason, "Single camera — no lens switching")
        XCTAssertFalse(capabilities.opticalZoom.isAvailable)
    }

    func testSingleBackCameraHasNoZoomStepsOrOpticalRange() {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [makeCamera("w", kind: .wide, focalLength35mm: 24)]

        XCTAssertFalse(capabilities.physicalLenses.contains { $0.virtualZoomFactors.count > 1 })
        XCTAssertEqual(capabilities.opticalZoom.reason, "No optical zoom range reported")
    }

    func testTripleLensDeviceEnablesLensSelectorAndOpticalZoom() {
        let capabilities = makeTripleLens()

        XCTAssertTrue(capabilities.lensSelector.isAvailable)
        XCTAssertTrue(capabilities.opticalZoom.isAvailable)
        XCTAssertNil(capabilities.lensSelector.reason, "an available feature must not carry a reason")
    }

    func testNoBackCameraIsReportedAsMissingRatherThanDisabled() {
        let capabilities = CameraCapabilities()

        XCTAssertFalse(capabilities.lensSelector.isAvailable)
        XCTAssertEqual(capabilities.lensSelector.reason, "No back camera reported")
        XCTAssertFalse(capabilities.rawCapture.isAvailable)
    }

    /// The iPhone SE 2022 case from `docs/ARCHITECTURE.md` section 5: ProRAW off and RAW
    /// independent of it. Neither may be inferred from the other.
    func testRawAndProRawAreIndependentCapabilities() {
        var capabilities = CameraCapabilities()
        capabilities.rawPixelTypes = [0x31324241]
        capabilities.proRawSupported = false

        XCTAssertTrue(capabilities.rawCapture.isAvailable)
        XCTAssertFalse(capabilities.proRawCapture.isAvailable)
        XCTAssertEqual(capabilities.proRawCapture.reason, "Apple ProRAW is not supported on this device")
    }

    func testProRawWithoutRawTypesIsStillReportedIndependently() {
        var capabilities = CameraCapabilities()
        capabilities.rawPixelTypes = []
        capabilities.proRawSupported = true

        XCTAssertFalse(capabilities.rawCapture.isAvailable)
        XCTAssertTrue(capabilities.proRawCapture.isAvailable)
    }

    func testFlashAvailabilityFollowsTheReportedCameras() {
        var capabilities = CameraCapabilities()
        XCTAssertFalse(capabilities.flash.isAvailable)

        capabilities.backCameras = [makeCamera("w", kind: .wide, focalLength35mm: 24, flash: true)]
        XCTAssertTrue(capabilities.flash.isAvailable)
    }

    /// Nothing is available before probing finishes, so no control can be enabled on a
    /// guess while the report or the session is still coming up.
    func testUnknownCapabilitiesEnableNothing() {
        let unknown = CameraCapabilities.unknown

        XCTAssertFalse(unknown.lensSelector.isAvailable)
        XCTAssertFalse(unknown.rawCapture.isAvailable)
        XCTAssertFalse(unknown.proRawCapture.isAvailable)
        XCTAssertFalse(unknown.hdr.isAvailable)
        XCTAssertFalse(unknown.flash.isAvailable)
        XCTAssertFalse(unknown.opticalZoom.isAvailable)
        XCTAssertNil(unknown.deviceTier, "tier stays nil until the Step 5 benchmark measures it")
    }

    // MARK: - Zoom labels are measured, never guessed

    func testZoomLabelsAreRatiosAgainstTheWideLens() {
        let capabilities = makeTripleLens()
        let lenses = capabilities.backCameras

        XCTAssertEqual(capabilities.zoomLabel(for: lenses[0]), "0.5x")
        XCTAssertEqual(capabilities.zoomLabel(for: lenses[1]), "1.0x")
        XCTAssertEqual(capabilities.zoomLabel(for: lenses[2]), "3.2x")
    }

    func testZoomLabelIsHiddenWhenTheReferenceLensIsUnknown() {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [makeCamera("x", kind: .unknown, focalLength35mm: 0)]

        XCTAssertNil(capabilities.zoomLabel(for: capabilities.backCameras[0]))
    }

    /// A composite device is a container, not a lens. Offering it alongside the physical
    /// lenses it wraps would put four buttons on a three-lens phone.
    func testPhysicalLensesWinOverCompositeDevices() {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [
            makeCamera("composite", kind: .composite, focalLength35mm: 24),
            makeCamera("uw", kind: .ultraWide, focalLength35mm: 13),
            makeCamera("w", kind: .wide, focalLength35mm: 24)
        ]

        XCTAssertEqual(capabilities.physicalLenses.map(\.uniqueID), ["uw", "w"])
    }

    func testCompositeSurvivesWhenNothingElseWasDiscovered() {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [makeCamera("composite", kind: .composite, focalLength35mm: 24)]

        XCTAssertEqual(capabilities.physicalLenses.map(\.uniqueID), ["composite"])
    }

    // MARK: - HDR badge is derived

    func testHDRBadgeRefusesToClaimFramesWeDidNotMerge() {
        // `.ready` says the hardware can. It does not say the system did anything.
        XCTAssertEqual(HDRStatus.ready.label, "HDR ready")
        XCTAssertEqual(HDRStatus.capturedWithQualityPriority.label, "HDR quality")
        XCTAssertEqual(HDRStatus.unsupported.label, "HDR n/a")
        XCTAssertTrue(HDRStatus.unsupported.isMuted)
        XCTAssertFalse(HDRStatus.ready.isMuted)
    }

    func testQualityPriorityIsOnlyRequestedWhereTheFormatSupportsIt() {
        XCTAssertTrue(HDRStatus.requestedQuality(hasPhotoQualitySupport: true))
        XCTAssertFalse(HDRStatus.requestedQuality(hasPhotoQualitySupport: false))
    }

    // MARK: - Exposure clamping

    private func makeRange() -> ExposureRange {
        ExposureRange(minISO: 32,
                      maxISO: 3200,
                      minShutterSeconds: 1.0 / 8000.0,
                      maxShutterSeconds: 1.0 / 15.0,
                      minExposureTargetOffset: -8,
                      maxExposureTargetOffset: 8)
    }

    func testExposureClampsToTheFormatsOwnLimits() {
        let range = makeRange()

        XCTAssertEqual(range.clampedISO(10), 32)
        XCTAssertEqual(range.clampedISO(128_000), 3200)
        XCTAssertEqual(range.clampedISO(400), 400)
    }

    /// An out-of-range `CMTimeSeconds` raises an Objective-C exception inside
    /// AVFoundation, so a non-finite or non-positive value has to collapse to the
    /// minimum rather than pass through.
    func testShutterClampsAndRejectsNonFiniteValues() {
        let range = makeRange()

        XCTAssertEqual(range.clampedShutterSeconds(0), range.minShutterSeconds, accuracy: 1e-9)
        XCTAssertEqual(range.clampedShutterSeconds(-1), range.minShutterSeconds, accuracy: 1e-9)
        XCTAssertEqual(range.clampedShutterSeconds(.nan), range.minShutterSeconds, accuracy: 1e-9)
        XCTAssertEqual(range.clampedShutterSeconds(60), range.maxShutterSeconds, accuracy: 1e-9)
        XCTAssertEqual(range.clampedShutterSeconds(1.0 / 120.0), 1.0 / 120.0, accuracy: 1e-9)
    }

    func testExposureOffsetClampsAndFallsBackToZeroForNonFiniteValues() {
        let range = makeRange()

        XCTAssertEqual(range.clampedExposureTargetOffset(-99), -8)
        XCTAssertEqual(range.clampedExposureTargetOffset(99), 8)
        XCTAssertEqual(range.clampedExposureTargetOffset(.infinity), 0)
        XCTAssertEqual(range.clampedExposureTargetOffset(1.5), 1.5)
    }

    func testContainsMatchesTheClampedResult() {
        let range = makeRange()

        XCTAssertTrue(range.contains(iso: 100, shutterSeconds: 1.0 / 60.0))
        XCTAssertFalse(range.contains(iso: 100, shutterSeconds: 30))
        XCTAssertFalse(range.contains(iso: 1, shutterSeconds: 1.0 / 60.0))
    }

    // MARK: - Orientation

    func testPreviewRotationMatchesTheCameraSide() {
        XCTAssertEqual(PreviewRotation.angle(for: .portrait, facing: .back), 90)
        XCTAssertEqual(PreviewRotation.angle(for: .portrait, facing: .front), 270)
        XCTAssertEqual(PreviewRotation.angle(for: .portraitUpsideDown, facing: .back), 270)
        XCTAssertEqual(PreviewRotation.angle(for: .portraitUpsideDown, facing: .front), 90)
        XCTAssertEqual(PreviewRotation.angle(for: .landscapeLeft, facing: .back), 0)
        XCTAssertEqual(PreviewRotation.angle(for: .landscapeRight, facing: .back), 180)
        XCTAssertEqual(PreviewRotation.angle(for: .landscapeLeft, facing: .front), 180)
        XCTAssertEqual(PreviewRotation.angle(for: .landscapeRight, facing: .front), 0)
    }

    /// `UIDevice` reports face-up, face-down and unknown while the phone is flat on a
    /// table, which must not throw the preview sideways.
    func testAmbiguousDeviceOrientationsFallBackToPortrait() {
        for orientation in [UIDeviceOrientation.unknown, .faceUp, .faceDown] {
            XCTAssertEqual(PreviewRotation.angle(for: orientation, facing: .back), 90)
            XCTAssertEqual(PreviewRotation.angle(for: orientation, facing: .front), 270)
        }
    }

    // MARK: - Container detection

    func testContainerDetectionReadsTheLeadingBytes() {
        XCTAssertEqual(PhotoContainer.detect(from: Data([0xFF, 0xD8, 0xFF, 0xE0] + [0, 0, 0, 0, 0, 0, 0, 0])),
                       .jpeg)
        XCTAssertEqual(PhotoContainer.detect(from: Data([0x49, 0x49, 0x2A, 0x00] + [0, 0, 0, 0, 0, 0, 0, 0])),
                       .dng)
        XCTAssertEqual(PhotoContainer.detect(from: Data([0x4D, 0x4D, 0x00, 0x2A] + [0, 0, 0, 0, 0, 0, 0, 0])),
                       .dng)
        XCTAssertEqual(PhotoContainer.detect(from: heif("heic")), .heic)
        XCTAssertEqual(PhotoContainer.detect(from: heif("mif1")), .heif)
    }

    func testUnknownDataIsNotForcedIntoAContainer() {
        XCTAssertNil(PhotoContainer.detect(from: Data([0x00, 0x01, 0x02])))
        XCTAssertNil(PhotoContainer.detect(from: Data()), "a short buffer is not a format")
    }

    private func heif(_ brand: String) -> Data {
        var bytes = Data([0x00, 0x00, 0x00, 0x18])
        bytes.append(contentsOf: Array("ftyp".utf8))
        bytes.append(contentsOf: Array(brand.utf8))
        return bytes
    }

    // MARK: - Recipe round trip

    func testRecipeRoundTripsEveryRecordedField() {
        var metadata = CaptureMetadata(mode: "auto")
        metadata.iso = 400
        metadata.shutterSeconds = 1.0 / 120.0
        metadata.exposureTargetOffset = -0.3
        metadata.lensFocalLength35mm = 24
        metadata.lensKind = "wide"
        metadata.zoomFactor = 1.5
        metadata.photoQualityPrioritization = "quality"
        metadata.proRaw = true
        metadata.colorSpace = "display-p3"
        metadata.hdrStatus = "HDR quality"

        let parsed = CaptureMetadata.parse(recipe: metadata.recipeString())

        XCTAssertEqual(parsed.version, CaptureMetadata.recipeVersion)
        XCTAssertEqual(parsed.fields["mode"], "auto")
        XCTAssertEqual(parsed.fields["iso"], "400")
        XCTAssertEqual(parsed.fields["sh"], "0.008333")
        XCTAssertEqual(parsed.fields["ev"], "-0.3")
        XCTAssertEqual(parsed.fields["f"], "24.0")
        XCTAssertEqual(parsed.fields["lens"], "wide")
        XCTAssertEqual(parsed.fields["zoom"], "1.5")
        XCTAssertEqual(parsed.fields["q"], "quality")
        XCTAssertEqual(parsed.fields["proraw"], "1")
        XCTAssertEqual(parsed.fields["space"], "display-p3")
        XCTAssertEqual(parsed.fields["hdr"], "HDR quality")
    }

    /// A recipe can come from a file the app did not write, so parsing has to be total.
    func testMalformedRecipesParseWithoutThrowing() {
        XCTAssertEqual(CaptureMetadata.parse(recipe: "").fields, [:])
        XCTAssertNil(CaptureMetadata.parse(recipe: "nonsense").version)

        let parsed = CaptureMetadata.parse(recipe: "v1;=orphanKey;iso=100;;garbage")
        XCTAssertEqual(parsed.version, 1)
        XCTAssertEqual(parsed.fields["iso"], "100")
        XCTAssertNil(parsed.fields[""], "an empty key is not a field")
    }

    func testRecipeOmitsFieldsThatWereNeverMeasured() {
        let recipe = CaptureMetadata(mode: "auto").recipeString()

        XCTAssertTrue(recipe.hasPrefix("v1;mode=auto"))
        XCTAssertFalse(recipe.contains("iso="), "an unmeasured ISO must be absent, not zero")
        XCTAssertFalse(recipe.contains("sh="))
        XCTAssertTrue(recipe.contains("q=balanced"))
    }

    func testImageDictionaryCarriesExposureAndRecipe() throws {
        var metadata = CaptureMetadata(mode: "auto")
        metadata.iso = 800
        metadata.shutterSeconds = 1.0 / 60.0
        metadata.lensFocalLength35mm = 24

        let dictionary = metadata.dictionary()
        let exif = try XCTUnwrap(dictionary[kCGImagePropertyExifDictionary as String] as? [String: Any])

        XCTAssertEqual(exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], [800])
        XCTAssertEqual(exif[kCGImagePropertyExifFocalLengthIn35mmFilm as String] as? Int, 24)
        let comment = try XCTUnwrap(exif[kCGImagePropertyExifUserComment as String] as? String)
        XCTAssertEqual(comment, metadata.recipeString())
    }

    // MARK: - Meter

    func testMeterReadsClippingAndAverageFromASyntheticPlane() {
        let width = 64
        let height = 64
        var plane = [UInt8](repeating: 10, count: width * height)
        for index in 0..<(width * height / 4) { plane[index] = 255 }

        let measured = plane.withUnsafeBufferPointer { buffer in
            PreviewMeter.measure(luma: buffer.baseAddress, width: width, height: height, bytesPerRow: width)
        }

        XCTAssertEqual(measured.clipFraction, 0.25, accuracy: 0.02)
        XCTAssertEqual(measured.averageLuma, ((10.0 * 768 + 255.0 * 256) / 1024.0) / 255.0, accuracy: 0.01)
    }

    /// A plane that is not luma-sized must return zeros, not a divide-by-zero or a read
    /// past the end of the buffer.
    func testMeterReportsZeroRatherThanNaNForAnUnusablePlane() {
        let measured = PreviewMeter.measure(luma: nil, width: 0, height: 0, bytesPerRow: 0)

        XCTAssertEqual(measured.clipFraction, 0)
        XCTAssertEqual(measured.averageLuma, 0)
    }

    func testDarkSceneThresholdMatchesItsName() {
        XCTAssertTrue(PreviewMeter.Sample(highlightClipFraction: 0, averageLuma: 0.1, framesPerSecond: 30).isDarkScene)
        XCTAssertFalse(PreviewMeter.Sample(highlightClipFraction: 0, averageLuma: 0.4, framesPerSecond: 30).isDarkScene)
    }

    // MARK: - Modes

    func testOnlyAutoIsImplementedInStep1() {
        XCTAssertTrue(CameraMode.auto.isImplemented)
        XCTAssertFalse(CameraMode.pro.isImplemented)
        XCTAssertFalse(CameraMode.looks.isImplemented)
    }
}
