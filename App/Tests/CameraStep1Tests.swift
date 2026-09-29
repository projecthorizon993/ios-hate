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
                            relativeScale: Double,
                            hasOpticalZoomSteps: Bool = false,
                            flash: Bool = false,
                            videoDimensions: String = "n/a") -> BackCameraCapabilities {
        BackCameraCapabilities(uniqueID: uniqueID,
                               kind: kind,
                               relativeScale: relativeScale,
                               hasOpticalZoomSteps: hasOpticalZoomSteps,
                               minimumFocusDistance: -1,
                               flashAvailable: flash,
                               videoDimensions: videoDimensions,
                               switchOverZoomFactors: [])
    }

    /// Relative scales chosen so the ratios are the same numbers a real phone would
    /// produce: an ultra wide at about half the wide, and a tele at about 3x.
    private func makeTripleLens() -> CameraCapabilities {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [
            makeCamera("uw", kind: .ultraWide, relativeScale: 13),
            makeCamera("w", kind: .wide, relativeScale: 24, hasOpticalZoomSteps: true, flash: true),
            makeCamera("t", kind: .telephoto, relativeScale: 77)
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
        capabilities.backCameras = [makeCamera("w", kind: .wide, relativeScale: 24)]

        XCTAssertFalse(capabilities.lensSelector.isAvailable)
        XCTAssertEqual(capabilities.lensSelector.reason, "Single camera — no lens switching")
        XCTAssertFalse(capabilities.opticalZoom.isAvailable)
    }

    func testSingleBackCameraHasNoZoomStepsOrOpticalRange() {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [makeCamera("w", kind: .wide, relativeScale: 24)]

        XCTAssertFalse(capabilities.physicalLenses.contains { $0.hasOpticalZoomSteps })
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

        capabilities.backCameras = [makeCamera("w", kind: .wide, relativeScale: 24, flash: true)]
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
        capabilities.backCameras = [makeCamera("x", kind: .unknown, relativeScale: 0)]

        XCTAssertNil(capabilities.zoomLabel(for: capabilities.backCameras[0]))
    }

    /// A composite device is a container, not a lens. Offering it alongside the physical
    /// lenses it wraps would put four buttons on a three-lens phone.
    func testPhysicalLensesWinOverCompositeDevices() {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [
            makeCamera("composite", kind: .composite, relativeScale: 24),
            makeCamera("uw", kind: .ultraWide, relativeScale: 13),
            makeCamera("w", kind: .wide, relativeScale: 24)
        ]

        XCTAssertEqual(capabilities.physicalLenses.map(\.uniqueID), ["uw", "w"])
    }

    func testCompositeSurvivesWhenNothingElseWasDiscovered() {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [makeCamera("composite", kind: .composite, relativeScale: 24)]

        XCTAssertEqual(capabilities.physicalLenses.map(\.uniqueID), ["composite"])
    }

    /// The observed iPhone 11 Pro case, verbatim.
    ///
    /// Six separately discovered back devices — three of them distinct composites — all
    /// reported the identical focal-length proxy 3168.0. With every lens equal, every zoom
    /// label computes to `3168 / 3168 = 1.0`, so the user saw three chips reading "1x", and
    /// every tap computed a destination of 1.0 — which is where the camera already was.
    ///
    /// The selector must be hidden rather than rendered with meaningless labels, and the
    /// tap must be refused rather than reported as a success. This is rule 4 of
    /// `docs/HANDOFF.md`: never show a control that does nothing.
    func testLensesThatReportIdenticalOpticsOfferNoLensSelector() {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [
            makeCamera("uw", kind: .ultraWide, relativeScale: 3168),
            makeCamera("w", kind: .wide, relativeScale: 3168),
            makeCamera("t", kind: .telephoto, relativeScale: 3168)
        ]

        XCTAssertFalse(capabilities.lensesAreDistinguishable,
                       "three lenses reading the same scale cannot be told apart")
        XCTAssertFalse(capabilities.lensSelector.isAvailable,
                       "chips that would all read 1x are not a control, they are decoration")
        // And no label is produced for any of them, rather than a plausible-looking "1x".
        XCTAssertNil(capabilities.zoomLabel(for: capabilities.backCameras[0]))
        XCTAssertNil(capabilities.zoomLabel(for: capabilities.backCameras[2]))
    }

    /// The converse, so the guard above is not simply refusing everything: a device that
    /// *does* report distinct optics keeps its selector and its measured labels.
    func testDistinctLensOpticsKeepTheSelectorAndTheirMeasuredLabels() {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [
            makeCamera("uw", kind: .ultraWide, relativeScale: 13),
            makeCamera("w", kind: .wide, relativeScale: 26),
            makeCamera("t", kind: .telephoto, relativeScale: 78)
        ]

        XCTAssertTrue(capabilities.lensesAreDistinguishable)
        XCTAssertTrue(capabilities.lensSelector.isAvailable)
        XCTAssertEqual(capabilities.zoomLabel(for: capabilities.backCameras[0]), "0.5x")
        XCTAssertEqual(capabilities.zoomLabel(for: capabilities.backCameras[1]), "1.0x")
        XCTAssertEqual(capabilities.zoomLabel(for: capabilities.backCameras[2]), "3.0x")
    }

    /// A lens whose optics could not be measured at all — the zero the derivation returns
    /// when there is no largest still — carries no information, so it must not be treated as
    /// a distinct measurement either.
    func testAnUnmeasurableLensIsNotTreatedAsDistinct() {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [
            makeCamera("uw", kind: .ultraWide, relativeScale: 0),
            makeCamera("w", kind: .wide, relativeScale: 26)
        ]

        XCTAssertFalse(capabilities.lensesAreDistinguishable)
        XCTAssertFalse(capabilities.lensSelector.isAvailable)
    }

    /// A single lens has nothing to switch between and is unaffected by the guard.
    func testASingleLensIsUnaffectedByTheIdenticalOpticsGuard() {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [makeCamera("w", kind: .wide, relativeScale: 3168)]

        XCTAssertTrue(capabilities.lensesAreDistinguishable)
        XCTAssertFalse(capabilities.lensSelector.isAvailable)
        XCTAssertEqual(capabilities.lensSelector.reason ?? "", "Single camera — no lens switching")
    }

    /// The gap this leaves, recorded rather than papered over.
    ///
    /// With the selector hidden, a multi-lens iPhone offers **no** way to change lens. That
    /// is honest and it is a worse product than a working 0.5x/1x/2x row, and the way out is
    /// a measurement that actually varies per lens — `videoDimensions` and
    /// `switchOverZoomFactors` are recorded on every lens for exactly that purpose. What
    /// they report on real hardware is not yet known; `docs/device-record-01.md` is where
    /// the answer goes.
    func testTheHiddenSelectorIsABlockingGapNotAClosedOne() {
        var capabilities = CameraCapabilities()
        capabilities.backCameras = [
            makeCamera("uw", kind: .ultraWide, relativeScale: 3168, videoDimensions: "1920x1080"),
            makeCamera("w", kind: .wide, relativeScale: 3168, videoDimensions: "1920x1080"),
            makeCamera("t", kind: .telephoto, relativeScale: 3168, videoDimensions: "1920x1080")
        ]

        // If the video dimensions ever do differ per lens, the information is already in
        // hand and the selector can be brought back on real measurements. This asserts the
        // data is captured, so the next step is a derivation and not another probe.
        XCTAssertEqual(Set(capabilities.backCameras.map(\.videoDimensions)).count, 1)
        XCTAssertFalse(capabilities.lensesAreDistinguishable,
                       "the guard reads relativeScale, which is still degenerate here")
    }

    // MARK: - The session and the capability model agree

    /// The regression test for a contradiction CI was green on.
    ///
    /// `CaptureSessionController.pickDevice` preferred a composite device while
    /// `attachBackCameras` filtered composites *out* of the capability model. The UI
    /// therefore offered physical lens chips for a session bound to a device the model had
    /// never heard of, and nothing tested the session half, so the two copies of the rule
    /// were free to disagree.
    ///
    /// Both halves now read `CameraPlan.resolve`. This asserts they do: whatever
    /// `pickDevice` would bind is the device the plan bound, and the offered lenses are the
    /// constituents of that bound device. If someone reintroduces a second copy of the
    /// selection rule, this fails.
    func testTheSessionAndTheCapabilityModelChooseTheSameDevice() {
        // What a three-lens Pro reports: three physical lenses and one composite.
        let discovered = [
            makeCamera("composite", kind: .composite, relativeScale: 24),
            makeCamera("uw", kind: .ultraWide, relativeScale: 13),
            makeCamera("w", kind: .wide, relativeScale: 24),
            makeCamera("t", kind: .telephoto, relativeScale: 77)
        ]

        let plan = CameraPlan.resolve(discovered: discovered)

        // The session binds the composite, and the capability model must not have bound
        // something else. `pickDevice` maps this same `bound` back to an `AVCaptureDevice`,
        // so asserting on `bound` is asserting on the session's choice.
        XCTAssertEqual(plan.bound?.uniqueID, "composite")

        // And the lens chips are the constituents of that composite, in reach order — not
        // the composite itself, which is a container rather than a lens.
        XCTAssertEqual(plan.offeredLenses.map(\.uniqueID), ["uw", "w", "t"])
        XCTAssertFalse(plan.offeredLenses.contains { $0.kind == .composite })

        // The capability model reads the plan rather than deciding again, so the two cannot
        // drift. This is the half that was previously untested.
        XCTAssertEqual(plan.offeredLenses, CameraPlan.resolve(discovered: discovered).offeredLenses)
    }

    /// A device reporting constituents but no composite binds its own wide lens. That is
    /// still a real lens and still supports `.custom`, so the Pro panel is not emptied.
    func testASingleLensDeviceBindsItselfAndKeepsItsProControls() {
        let plan = CameraPlan.resolve(discovered: [makeCamera("w", kind: .wide, relativeScale: 24)])

        XCTAssertEqual(plan.bound?.uniqueID, "w")
        XCTAssertEqual(plan.offeredLenses.map(\.uniqueID), ["w"])
        // No composite means no documented restriction on manual exposure.
        XCTAssertFalse(plan.bound?.kind == .composite)
    }

    /// The Pro panel being empty on a Pro iPhone is a consequence of binding a composite,
    /// and that is recorded rather than left as an unexplained gap. Binding a constituent
    /// instead is `docs/PHASES.md` 3.1 and has never been run on a device.
    ///
    /// The distinction this pins is between the two flags. `hasConstituentForPro` is true
    /// even for a single-lens device, because that device is its own constituent and there
    /// is nothing to fix. `proRequiresRebinding` is the one that names the empty-panel
    /// case, and it is false for a single-lens device because the bound device already
    /// supports `.custom`.
    func testTheEmptyProPanelOnACompositeHasARecordedCause() {
        let withComposite = CameraPlan.resolve(discovered: [
            makeCamera("composite", kind: .composite, relativeScale: 24),
            makeCamera("w", kind: .wide, relativeScale: 24)
        ])
        let singleLens = CameraPlan.resolve(discovered: [
            makeCamera("w", kind: .wide, relativeScale: 24)
        ])

        XCTAssertTrue(withComposite.hasConstituentForPro,
                      "a constituent exists, so the empty panel is the binding, not the hardware")
        XCTAssertTrue(withComposite.proRequiresRebinding,
                      "a composite is bound while a constituent exists: this is the empty-panel case")
        XCTAssertEqual(withComposite.bound?.kind, .composite)

        // A single-lens device has a constituent — itself — and needs no rebinding.
        XCTAssertTrue(singleLens.hasConstituentForPro)
        XCTAssertFalse(singleLens.proRequiresRebinding,
                       "a single lens is already the device Pro mode would want")
    }

    /// The `unknown` kind is a device type this app does not model. It must not become the
    /// bound device, because binding an unrecognised device would let the UI offer lenses
    /// whose capabilities were never probed.
    func testAnUnrecognisedDeviceTypeIsNeverBound() {
        let plan = CameraPlan.resolve(discovered: [
            makeCamera("mystery", kind: .unknown, relativeScale: 40)
        ])

        XCTAssertNil(plan.bound)
        XCTAssertTrue(plan.offeredLenses.isEmpty)
    }

    /// A composite is only ever its own single lens when discovery reported nothing else.
    /// Otherwise it stands in for the constituents it wraps, and offering it as a fourth
    /// chip on a three-lens phone is the lie this whole derivation exists to prevent.
    func testACompositeIsOfferedAsALensOnlyWhenThereIsNoAlternative() {
        let alone = CameraPlan.resolve(discovered: [
            makeCamera("composite", kind: .composite, relativeScale: 24)
        ])
        XCTAssertEqual(alone.offeredLenses.map(\.uniqueID), ["composite"])

        let alongside = CameraPlan.resolve(discovered: [
            makeCamera("composite", kind: .composite, relativeScale: 24),
            makeCamera("w", kind: .wide, relativeScale: 24)
        ])
        XCTAssertEqual(alongside.offeredLenses.map(\.uniqueID), ["w"])
    }

    // MARK: - HDR badge is derived

    func testHDRBadgeNeverClaimsAResolutionItCannotObserve() {
        // `.ready` says the hardware can. It does not say the system did anything.
        XCTAssertEqual(HDRStatus.ready.label, "HDR ready")
        // The resolved quality prioritisation is not readable from
        // `AVCaptureResolvedPhotoSettings`, so the third state is worded as a request.
        XCTAssertEqual(HDRStatus.qualityRequested.label, "HDR requested")
        XCTAssertEqual(HDRStatus.unsupported.label, "HDR n/a")
        XCTAssertTrue(HDRStatus.unsupported.isMuted)
        XCTAssertFalse(HDRStatus.ready.isMuted)
        // There is no "frames merged" state at all, because the app merges none.
        XCTAssertEqual(HDRStatus.allCases.count, 3)
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
        metadata.lensRelativeScale = 24
        metadata.lensKind = "wide"
        metadata.zoomFactor = 1.5
        metadata.photoQualityPrioritization = "quality"
        metadata.proRaw = true
        metadata.colorSpace = "display-p3"
        metadata.hdrStatus = "HDR quality"

        let parsed = CaptureMetadata.parse(recipe: metadata.recipeString())

        XCTAssertEqual(parsed.version, CaptureMetadata.recipeVersion)
        XCTAssertEqual(parsed.fields["mode"], "auto")
        // Whole numbers print without a decimal point; fractional ones keep two. The
        // recipe is a persisted format, so the representation has to be stable rather
        // than the shortest one that happens to round-trip.
        XCTAssertEqual(parsed.fields["iso"], "400")
        XCTAssertEqual(parsed.fields["sh"], "0.008333")
        XCTAssertEqual(parsed.fields["ev"], "-0.30")
        XCTAssertEqual(parsed.fields["rs"], "24.0")
        XCTAssertEqual(parsed.fields["lens"], "wide")
        XCTAssertEqual(parsed.fields["zoom"], "1.50")
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
        metadata.lensRelativeScale = 24

        let dictionary = metadata.dictionary()
        let exif = try XCTUnwrap(dictionary[kCGImagePropertyExifDictionary as String] as? [String: Any])

        XCTAssertEqual(exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], [800])
        XCTAssertEqual(exif[kCGImagePropertyExifISOSpeed as String] as? Int, 800)
        let comment = try XCTUnwrap(exif[kCGImagePropertyExifUserComment as String] as? String)
        XCTAssertEqual(comment, metadata.recipeString())
        // The focal length lives in the recipe, not in an EXIF key, because this SDK has
        // no `kCGImagePropertyExifFocalLengthIn35mmFilm`. If it ever comes back, the
        // recipe is still the source of truth and this assertion keeps the two in step.
        XCTAssertTrue(comment.contains("rs=24.0"))
        XCTAssertNotNil(dictionary[kCGImagePropertyTIFFDictionary as String])
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

    /// Was `testOnlyAutoIsImplementedInStep1`, asserting that Pro and Looks reported
    /// themselves unavailable. Steps 3 and 4 built them, so the assertion was inverted
    /// rather than deleted — the modes are still all present and still all labelled the
    /// same way, which is the part of the contract that does not change when one of them
    /// stops being a placeholder.
    func testEveryModeIsImplementedAndKeepsItsLabel() {
        for mode in CameraMode.allCases {
            XCTAssertTrue(mode.isImplemented, "\(mode) should be implemented")
            XCTAssertFalse(mode.label.isEmpty, "\(mode) needs a label")
        }
        // The mode switcher's order is the chrome, and `DESIGN_SPEC.md` requires it not
        // to move when a mode is filled in.
        XCTAssertEqual(CameraMode.allCases, [.auto, .pro, .looks])
    }

    // MARK: - Manual exposure gating

    /// The regression test for the defect this branch was returned for.
    ///
    /// `setExposureModeCustom(duration:iso:)` takes both values in one call and has no
    /// partial form, so setting only ISO still has to name a shutter. The first version of
    /// this named a fixed 1/60 s, which meant a user who dialled in ISO alone silently got
    /// a 1/60 s shutter they never chose — the manual control moving the image to somewhere
    /// nobody asked for, which is the defect this whole task exists to remove.
    ///
    /// The value the user did not set has to be the device's own. That is the whole rule.
    func testSettingISOAloneLeavesTheShutterWhereTheDeviceHadIt() {
        // The device is running a fast shutter, which is the case that matters: a
        // substituted 1/60 is a three-stop error in bright light and invisible in dim.
        let pair = CaptureSessionController.resolveExposurePair(
            ManualSettings(iso: 400),
            currentSeconds: 1.0 / 1000,
            currentISO: 50,
            shutterRange: (1.0 / 8000)...(1.0 / 30),
            isoRange: 25...6400
        )

        XCTAssertEqual(pair.iso, 400, "the ISO the user dialled in is the ISO sent")
        XCTAssertEqual(pair.seconds, 1.0 / 1000,
                       "the shutter the user did not set must be the device's, not a substituted value")
        XCTAssertNotEqual(pair.seconds, 1.0 / 60,
                          "1/60 here is the original defect returning")
    }

    /// The converse, and the reason the rule is symmetric rather than an ISO special case.
    func testSettingTheShutterAloneLeavesTheISOWhereTheDeviceHadIt() {
        let pair = CaptureSessionController.resolveExposurePair(
            ManualSettings(shutterSeconds: 1.0 / 60),
            currentSeconds: 1.0 / 1000,
            currentISO: 800,
            shutterRange: (1.0 / 8000)...(1.0 / 30),
            isoRange: 25...6400
        )

        XCTAssertEqual(pair.seconds, 1.0 / 60)
        XCTAssertEqual(pair.iso, 800, "an unset ISO must not be reset to a default either")
    }

    /// A bias on its own still has to enter `.custom`, and doing so must not disturb the
    /// exposure the device was already running — which is what writing the pair first is
    /// for.
    func testSettingBiasAloneCarriesTheDevicesOwnExposure() {
        let pair = CaptureSessionController.resolveExposurePair(
            ManualSettings(exposureTargetOffset: 1.5),
            currentSeconds: 1.0 / 250,
            currentISO: 200,
            shutterRange: (1.0 / 8000)...(1.0 / 30),
            isoRange: 25...6400
        )

        XCTAssertEqual(pair.iso, 200)
        XCTAssertEqual(pair.seconds, 1.0 / 250)
    }

    /// Both set means both are honoured, and each is clamped to the live format's range
    /// rather than to whatever was probed earlier.
    func testBothValuesAreUsedAndClampedToTheLiveRange() {
        let pair = CaptureSessionController.resolveExposurePair(
            ManualSettings(iso: 99999, shutterSeconds: 30),
            currentSeconds: 1.0 / 250,
            currentISO: 200,
            shutterRange: (1.0 / 8000)...(1.0 / 30),
            isoRange: 25...6400
        )

        XCTAssertEqual(pair.iso, 6400, "an ISO above the live ceiling clamps to it")
        XCTAssertEqual(pair.seconds, 1.0 / 30, "a shutter below the live floor clamps to it")
    }

    /// A device that reports no usable range is still written, unclamped, rather than
    /// refusing. Refusing would be a behaviour change on hardware the probe could not
    /// describe, and the exception trap is what catches a bad value, not a missing range.
    func testAnAbsentRangeLeavesTheValuesUnclamped() {
        let pair = CaptureSessionController.resolveExposurePair(
            ManualSettings(iso: 400),
            currentSeconds: 1.0 / 250,
            currentISO: 200,
            shutterRange: nil,
            isoRange: nil
        )

        XCTAssertEqual(pair.iso, 400)
        XCTAssertEqual(pair.seconds, 1.0 / 250)
    }

    /// A composite device cannot do manual exposure, and the panel must not pretend
    /// otherwise.
    ///
    /// `ProCapabilities.probe` needs a live `AVCaptureDevice`, so it cannot be called
    /// here. What *can* be tested is the rule that consumes it: given a capability set
    /// with no custom-exposure support, `ManualSettings.clamped(to:)` must withdraw every
    /// exposure value rather than pass a value the device will refuse.
    ///
    /// This is the fixture the plan's Step 5 asks for, and it is the assertion that would
    /// have failed while the panel offered sliders over a composite device.
    func testACompositeDeviceWithdrawsEveryManualExposureValue() {
        let compositeLike = ProCapabilities(
            supportsCustomExposure: false,
            isoRange: nil,
            shutterRange: nil,
            exposureCompensationRange: nil,
            canLockExposure: false,
            canLockFocus: false,
            canLockWhiteBalance: false
        )

        let requested = ManualSettings(iso: 400,
                                       shutterSeconds: 1.0 / 120,
                                       exposureTargetOffset: 1.5,
                                       lockExposure: true,
                                       lockFocus: true,
                                       lockWhiteBalance: true)
        let clamped = requested.clamped(to: compositeLike)

        XCTAssertNil(clamped.iso)
        XCTAssertNil(clamped.shutterSeconds)
        XCTAssertEqual(clamped.exposureTargetOffset, 0)
        XCTAssertFalse(clamped.lockExposure)
        XCTAssertFalse(clamped.lockFocus)
        XCTAssertFalse(clamped.lockWhiteBalance)
        XCTAssertTrue(compositeLike.isEmpty, "nothing should be offered at all")
    }

    /// The converse: a device that does support custom exposure keeps the values, and
    /// clamps them to its real range rather than dropping them.
    func testADeviceThatSupportsCustomExposureKeepsAndClampsItsValues() {
        let capable = ProCapabilities(
            supportsCustomExposure: true,
            isoRange: 50...400,
            shutterRange: (1.0 / 8000)...(1.0 / 30),
            exposureCompensationRange: -3...3,
            canLockExposure: true,
            canLockFocus: true,
            canLockWhiteBalance: true
        )

        let clamped = ManualSettings(iso: 6400, exposureTargetOffset: 9).clamped(to: capable)
        XCTAssertEqual(clamped.iso, 400, "an out-of-range ISO clamps to the ceiling, not to nil")
        XCTAssertEqual(clamped.exposureTargetOffset, 3)
    }

    /// The summary must name the platform's reason, not just say "nothing available".
    /// A panel reading "no manual controls" on a device that visibly has three lenses is
    /// indistinguishable from a bug.
    ///
    /// Built with `isCompositeDevice: true` rather than relying on a default, because the
    /// composite wording is only true for a device that reported itself as one. The
    /// converse case is the assertion that matters: a device which is not a composite must
    /// not be told that it is.
    func testTheSummaryExplainsWhyACompositeDeviceHasNoManualControls() {
        let composite = ProCapabilities(supportsCustomExposure: false, isCompositeDevice: true)
        let summary = composite.availabilitySummary

        XCTAssertTrue(summary.contains("composite"), "summary was: \(summary)")
        XCTAssertTrue(summary.contains("do not support manual exposure"), "summary was: \(summary)")
    }

    /// The other half of the same rule, and the one an earlier version of this file got
    /// backwards: the composite explanation is a claim about the hardware, so it may only
    /// be made about hardware that reported itself as a composite.
    ///
    /// `ProCapabilities.probe` needs a live `AVCaptureDevice` and cannot run here, so what
    /// is pinned is the rule that consumes the recorded flag: no composite, no composite
    /// claim.
    func testTheSummaryDoesNotCallANonCompositeDeviceAComposite() {
        let notComposite = ProCapabilities(supportsCustomExposure: false, isCompositeDevice: false)
        let summary = notComposite.availabilitySummary

        XCTAssertFalse(summary.contains("composite"),
                       "a device that did not report as a composite must not be told it is: \(summary)")
        XCTAssertTrue(summary.contains("does not support manual exposure"),
                      "the reason must still be stated: \(summary)")
    }

    /// `isCompositeDevice` has to be recorded from `device.deviceType`, and the types it
    /// accepts are exactly the composites. A device type list that drifts — by gaining a
    /// single-lens type, say — would put the composite explanation on hardware it does not
    /// describe.
    func testOnlyCompositeDeviceTypesAreTreatedAsComposite() {
        let composites: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera
        ]
        XCTAssertEqual(ProCapabilities.compositeTypes.sorted { $0.rawValue < $1.rawValue },
                       composites.sorted { $0.rawValue < $1.rawValue })

        for singleLens: AVCaptureDevice.DeviceType in [.builtInWideAngleCamera,
                                                       .builtInTelephotoCamera,
                                                       .builtInUltraWideCamera] {
            XCTAssertFalse(ProCapabilities.compositeTypes.contains(singleLens),
                           "\(singleLens.rawValue) is one lens, not a composite")
        }
    }

    /// A composite-like capability set offers no white balance lock, even though
    /// `AVCaptureDevice` answers yes to `isWhiteBalanceModeSupported(.locked)`.
    ///
    /// Apple documents composites as refusing new AWB gains, and — contrary to what
    /// `docs/HANDOFF.md` 0.3 asserted — there *is* a query for that:
    /// `isLockingWhiteBalanceWithCustomDeviceGainsSupported`. It returns false where
    /// `setWhiteBalanceModeLocked(with:)` would throw, so the gate is a certain answer
    /// rather than the `.custom` proxy it started as.
    ///
    /// All three combinations are asserted, so the gate cannot be accidentally satisfied by
    /// only one of the two questions.
    func testACompositeLikeCapabilitySetOffersNoWhiteBalanceLock() {
        // What `probe` records for a composite: the locked *mode* is supported, locking to
        // chosen gains is not.
        XCTAssertFalse(ProCapabilities.whiteBalanceLockIsOffered(
            lockedModeSupported: true,
            customGainsLockSupported: false),
            "a device that refuses new gains must not offer the lock")

        // Neither half is sufficient on its own.
        XCTAssertFalse(ProCapabilities.whiteBalanceLockIsOffered(
            lockedModeSupported: false,
            customGainsLockSupported: true))
        XCTAssertFalse(ProCapabilities.whiteBalanceLockIsOffered(
            lockedModeSupported: false,
            customGainsLockSupported: false))

        // And a device that supports both does get it.
        XCTAssertTrue(ProCapabilities.whiteBalanceLockIsOffered(
            lockedModeSupported: true,
            customGainsLockSupported: true))
    }

    /// The same gate has to reach the panel. `ProParameter.supported(by:)` is what the Pro
    /// panel renders from, so a withdrawn lock must not produce a WB chip — this is the
    /// user-visible half of the assertion above, and it is the half a user would see.
    ///
    /// `@MainActor` because `ProParameter` lives in the SwiftUI file, where the static is
    /// main-actor isolated. Same reason the prioritisation test below carries it.
    @MainActor
    func testNoWhiteBalanceChipIsRenderedForACompositeLikeCapabilitySet() {
        let compositeLike = ProCapabilities(supportsCustomExposure: false, isCompositeDevice: true)

        XCTAssertFalse(ProParameter.supported(by: compositeLike).contains(.whiteBalance),
                       "a WB chip that cannot lock is exactly the defect being closed")
        // A device that can, does show it.
        var capable = ProCapabilities(supportsCustomExposure: true)
        capable.canLockWhiteBalance = true
        XCTAssertTrue(ProParameter.supported(by: capable).contains(.whiteBalance))
    }

    /// `photoQualityPrioritization` is decided from this, and `.balanced` would let the
    /// system override the user's ISO in low light. So the flag has to be true exactly
    /// when something was dialled in.
    func testManualExposureIsFlaggedOnlyWhenSomethingWasDialledIn() {
        XCTAssertFalse(ManualSettings.none.isExposureManual)
        XCTAssertFalse(ManualSettings(iso: nil, shutterSeconds: nil).isExposureManual)
        XCTAssertTrue(ManualSettings(iso: 100).isExposureManual)
        XCTAssertTrue(ManualSettings(shutterSeconds: 1.0 / 60).isExposureManual)
        XCTAssertTrue(ManualSettings(lockExposure: true).isExposureManual)
        // An exposure bias of zero is the neutral point, not a manual setting.
        XCTAssertFalse(ManualSettings(exposureTargetOffset: 0).isExposureManual)
    }

    /// The prioritisation and the string written into the file's own recipe must be the
    /// same decision, derived from one function.
    ///
    /// These were two independent expressions once, and they disagreed: the settings got
    /// `.speed` while the recipe said `"balanced"`, so a manual capture's file reported
    /// the opposite of what had been done to it.
    /// `PhotoCaptureController` is `@MainActor`, so this is too. The project builds in
    /// Swift 5.9 with minimal concurrency checking, where the mismatch is not diagnosed,
    /// but the annotation costs nothing and states what the test actually needs.
    @MainActor
    func testTheRecordedPrioritisationMatchesTheOneApplied() {
        // Built by assignment rather than the memberwise initialiser, because the
        // declaration order of `Request` is not the order these two matter in and a
        // positional call would have to repeat the defaults to get here.
        var manual = PhotoCaptureController.Request()
        manual.preferQuality = true
        manual.manualExposureActive = true

        var quality = PhotoCaptureController.Request()
        quality.preferQuality = true

        let neither = PhotoCaptureController.Request()

        XCTAssertEqual(PhotoCaptureController.name(for: PhotoCaptureController.prioritization(for: manual)),
                       "speed", "manual must win over a quality request")
        XCTAssertEqual(PhotoCaptureController.name(for: PhotoCaptureController.prioritization(for: quality)),
                       "quality")
        XCTAssertEqual(PhotoCaptureController.name(for: PhotoCaptureController.prioritization(for: neither)),
                       "balanced")
    }
}
