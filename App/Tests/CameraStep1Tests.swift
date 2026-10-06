import AVFoundation
import CoreGraphics
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
                            videoDimensions: String = "n/a",
                            switchOver: [Double] = [],
                            minimumZoom: Double = 1) -> BackCameraCapabilities {
        BackCameraCapabilities(uniqueID: uniqueID,
                               kind: kind,
                               relativeScale: relativeScale,
                               hasOpticalZoomSteps: hasOpticalZoomSteps,
                               minimumFocusDistance: -1,
                               flashAvailable: flash,
                               videoDimensions: videoDimensions,
                               switchOverZoomFactors: switchOver,
                               minAvailableVideoZoomFactor: minimumZoom)
    }

    /// A three-lens phone as the device reports it: a bound composite carrying the switch
    /// points, and the three physical lenses behind it.
    ///
    /// `plan` is set as well as `backCameras`, and it has to be — the lens selector and the
    /// zoom chips are derived from the plan, because the plan is what the session actually
    /// bound. A fixture that only sets `backCameras` is a phone with lenses and no camera.
    private func makeTripleLens() -> CameraCapabilities {
        var capabilities = CameraCapabilities()
        let lenses = [
            makeCamera("uw", kind: .ultraWide, relativeScale: 13),
            makeCamera("w", kind: .wide, relativeScale: 24, hasOpticalZoomSteps: true, flash: true),
            makeCamera("t", kind: .telephoto, relativeScale: 77)
        ]
        capabilities.backCameras = lenses
        capabilities.plan = CameraPlan(
            bound: makeCamera("triple", kind: .composite, relativeScale: 24, switchOver: [2, 3]),
            offeredLenses: lenses,
            hasConstituentForPro: true,
            proRequiresRebinding: true)
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
        let single = [makeCamera("w", kind: .wide, relativeScale: 24)]
        capabilities.backCameras = single
        capabilities.plan = CameraPlan(bound: single[0], offeredLenses: single,
                                       hasConstituentForPro: true, proRequiresRebinding: false)

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

    /// The observed iPhone 11 Pro case, verbatim — and the correction of it.
    ///
    /// Six separately discovered back devices reported the identical focal-length proxy
    /// 3168.0. That is because the three lenses share a sensor resolution *and* the virtual
    /// devices report a shared default `activeFormat`, so the still-area derivation returns
    /// one constant. Every chip therefore read "1x" and every tap computed a destination of
    /// 1.0 — where the camera already was — and the log recorded it as a lens change.
    ///
    /// The first response was to hide the selector, on the grounds that three chips reading
    /// "1x" are decoration. That was right about the labels and **wrong about the device**:
    /// the same report showed the composite reporting switch-over factors of 2.0 and 4.0, so
    /// the phone switches lenses perfectly well. Hiding the control threw away a working
    /// feature because a label was unmeasurable. The chips now come from the reported switch
    /// points, and `relativeScale` is used for nothing.
    func testZoomChipsComeFromReportedSwitchPointsNotFromStillResolution() {
        let plan = CameraPlan(bound: makeCamera("triple", kind: .composite, relativeScale: 3168,
                                                switchOver: [2, 4]),
                              offeredLenses: [makeCamera("uw", kind: .ultraWide, relativeScale: 3168),
                                              makeCamera("w", kind: .wide, relativeScale: 3168),
                                              makeCamera("t", kind: .telephoto, relativeScale: 3168)],
                              hasConstituentForPro: true,
                              proRequiresRebinding: true)

        // 1x is always present, plus each reported switch point, in reach order.
        XCTAssertEqual(plan.zoomStops.map(\.factor), [1.0, 2.0, 4.0])
        // And every one of them is a distinct factor despite the identical still resolution,
        // which is the whole point: the measurement that failed is not consulted.
        XCTAssertEqual(Set(plan.zoomStops.map(\.factor)).count, 3)
    }

    /// The chip is the **zoom factor**, not a sensor name.
    ///
    /// An earlier version inferred the active lens from which switch-over band the factor
    /// fell in, and printed "Wide" / "Telephoto" on the chips. The user of an iPhone 11 Pro
    /// observed a chip reading "Wide" while the ultra wide was demonstrably in use: iOS never
    /// reports which constituent is active, so the inference was a fabrication, and it was
    /// printed next to the control that changes the sensor.
    func testChipsAreLabelledWithTheFactorAndNeverWithAnInferredSensor() {
        let plan = CameraPlan(bound: makeCamera("triple", kind: .composite, relativeScale: 3168,
                                                switchOver: [2, 4]),
                              offeredLenses: [makeCamera("uw", kind: .ultraWide, relativeScale: 3168),
                                              makeCamera("w", kind: .wide, relativeScale: 3168),
                                              makeCamera("t", kind: .telephoto, relativeScale: 3168)],
                              hasConstituentForPro: true,
                              proRequiresRebinding: true)

        // Every chip is a number the device actually reported.
        XCTAssertEqual(plan.zoomStops.map(\.label), ["1x", "2x", "4x"])
        // And no chip carries a lens name, on any device, whatever the inference would say.
        let names: Set<String> = Set(
            [BackCameraCapabilities.Kind.ultraWide, .wide, .telephoto, .composite, .unknown]
                .map(\.zoomLabel))
        for label in plan.zoomStops.map(\.label) {
            XCTAssertFalse(names.contains(label), "a chip must not claim a sensor: \(label)")
        }
    }

    /// The same, stated on the type: a `ZoomStop` cannot be given a sensor at all, so the
    /// inference cannot be reintroduced without changing this type.
    func testAZoomStopHasNoSensorFieldToPutAnInferenceIn() {
        let stop = ZoomStop(factor: 2)
        XCTAssertEqual(stop.label, "2x")
        // A fractional factor keeps its decimal, because 1.5x and 2x are different controls.
        XCTAssertEqual(ZoomStop(factor: 1.5).label, "1.5x")
    }

    /// A zoom factor belongs to the band whose **lower edge** it has reached.
    ///
    /// This is what lets a second tap on the same chip return to 1x once the camera settles
    /// just past a switch-over point instead of exactly on it. Observed on an iPhone 11 Pro:
    /// the camera was asked for exactly 4.0, the reported switch point, and settled at
    /// `zoom 4.000x` — which Apple documents as "touches" the point rather than crossing it,
    /// so the telephoto was never selected. An equality test would call 4.08 a different zoom
    /// from the 4x chip and send the user somewhere new instead of home.
    func testBandIsTheSwitchOverPointTheZoomHasReached() {
        let points = [2.0, 4.0]
        // Below every reported point.
        XCTAssertEqual(CameraViewModel.band(containing: 1.0, switchOver: points), 1.0)
        XCTAssertEqual(CameraViewModel.band(containing: 1.99, switchOver: points), 1.0)
        // Exactly on a point counts as having reached it.
        XCTAssertEqual(CameraViewModel.band(containing: 2.0, switchOver: points), 2.0)
        // And just past it, which is where the camera now rests.
        XCTAssertEqual(CameraViewModel.band(containing: 2.04, switchOver: points), 2.0)
        XCTAssertEqual(CameraViewModel.band(containing: 4.08, switchOver: points), 4.0)
        // Above every reported point.
        XCTAssertEqual(CameraViewModel.band(containing: 4.0 * 4, switchOver: points), 4.0)
        // A device reporting no points at all is simply always at 1x, rather than crashing
        // or inventing a boundary.
        XCTAssertEqual(CameraViewModel.band(containing: 7.0, switchOver: []), 1.0)
    }

    /// The margin has to clear the boundary and stay visually negligible.
    ///
    /// If it were 1.0 the camera would rest exactly on the switch point and the lens would
    /// still never be selected, which is the bug. The upper bound is here so "make it
    /// clearly past the point" cannot quietly turn into "noticeably overshoot the chip".
    func testSwitchOverMarginClearsThePointWithoutOvershootingVisibly() {
        XCTAssertGreaterThan(CameraViewModel.switchOverMargin, 1.0)
        XCTAssertLessThanOrEqual(CameraViewModel.switchOverMargin, 1.10)
    }

    /// The device reported `minAvailableVideoZoomFactor == 1.0` on every format, so the
    /// ultra wide is **not reachable** and there is deliberately no 0.5x chip.
    ///
    /// A 0.5x button would be a control that cannot do anything, which is the exact defect
    /// rule 4 of `docs/HANDOFF.md` exists to prevent. The user expected 0.5x; the honest
    /// answer is that this hardware cannot deliver it through the control the app has.
    func testThereIsNoHalfStopWhenTheDeviceCannotZoomBelowOne() {
        let plan = CameraPlan(bound: makeCamera("triple", kind: .composite, relativeScale: 3168,
                                                switchOver: [2, 4]),
                              offeredLenses: [makeCamera("uw", kind: .ultraWide, relativeScale: 3168),
                                              makeCamera("w", kind: .wide, relativeScale: 3168),
                                              makeCamera("t", kind: .telephoto, relativeScale: 3168)],
                              hasConstituentForPro: true,
                              proRequiresRebinding: true)

        XCTAssertNil(plan.belowOneXMinimum, "the device reported 1.0 as its minimum")
        XCTAssertFalse(plan.zoomStops.contains { $0.factor < 1.0 })
    }

    /// The app does not name the active sensor, and this is why the capability model has
    /// no way to ask.
    ///
    /// Three attempts were made and all three were wrong:
    ///
    /// 1. `relativeScale` — returns one constant for every lens on a modern iPhone, so
    ///    every lens read as the same thing.
    /// 2. An index into `switchOverZoomFactors` — off by one, because 1.0 is not among
    ///    the reported points, so 1.0x came out as the ultra wide.
    /// 3. A band inference anchored on 1.0 — which the user of an iPhone 11 Pro observed
    ///    naming the wrong lens outright, with the ultra wide in use behind a chip that
    ///    said "Wide".
    ///
    /// iOS exposes no query for which constituent of a composite is active, so there is
    /// no correct version of this to write. The fix is the absence of the claim: the chips
    /// are zoom factors, which are reported, and `metadata.lensKind` records
    /// `"unverified"` rather than a guess that would be written into the file permanently.
    ///
    /// What is recorded instead is `metadata.zoomFactor`, which is measured and is what
    /// the user actually asked for.
    func testTheActiveSensorIsNotDerivedFromAnything() {
        let plan = CameraPlan(bound: makeCamera("triple", kind: .composite, relativeScale: 3168,
                                                switchOver: [2, 4]),
                              offeredLenses: [makeCamera("uw", kind: .ultraWide, relativeScale: 3168),
                                              makeCamera("w", kind: .wide, relativeScale: 3168),
                                              makeCamera("t", kind: .telephoto, relativeScale: 3168)],
                              hasConstituentForPro: true,
                              proRequiresRebinding: true)

        // The factors are real, and they are the whole of what the app claims.
        XCTAssertEqual(plan.zoomStops.map(\.factor), [1.0, 2.0, 4.0])
        // A device whose minimum allows 0.5x still does not get a 0.5x *sensor*, only a
        // 0.5x *stop*, and that too is absent here because this composite reports 1.0.
        XCTAssertNil(plan.belowOneXMinimum)
    }

    /// A device with no switch points offers no chips, and says why.
    func testADeviceWithNoSwitchPointsOffersNoChips() {
        var capabilities = CameraCapabilities()
        capabilities.plan = CameraPlan(bound: nil, offeredLenses: [],
                                       hasConstituentForPro: false, proRequiresRebinding: false)

        XCTAssertTrue(capabilities.zoomStops.isEmpty)
        XCTAssertFalse(capabilities.lensSelector.isAvailable)
    }

    /// One lens has nothing to switch between, and the reason is the honest one.
    func testASingleLensReportsTheSingleCameraReason() {
        var capabilities = CameraCapabilities()
        capabilities.plan = CameraPlan(bound: makeCamera("w", kind: .wide, relativeScale: 3168),
                                       offeredLenses: [makeCamera("w", kind: .wide, relativeScale: 3168)],
                                       hasConstituentForPro: true, proRequiresRebinding: false)

        XCTAssertTrue(capabilities.zoomStops.isEmpty)
        XCTAssertEqual(capabilities.lensSelector.reason ?? "", "Single camera — no lens switching")
    }

    /// The grainy-preview fix, expressed as the numbers that caused it.
    ///
    /// On an iPhone 11 Pro the device offers a `4032x3024 still | 4032x3024 video` format —
    /// a 12 megapixel video stream — and the chooser picked it, because it ranked on still
    /// area and used video area only as a last tiebreaker. Nothing argued against it. The
    /// viewfinder, the meter and the processed preview all run on that stream, so the
    /// reported symptom was a soft, grainy preview.
    ///
    /// The cap is what stops it. 1920x1440 is full 1080p-class and 4:3, matching the 4:3
    /// stills, and the format that pairs it with a full-size still also reports
    /// `isHighPhotoQualitySupported` and `isVideoHDRSupported` — which the oversized one
    /// did not, so the HDR badge and `photoQualityPrioritization` were both inert too.
    func testTheVideoStreamIsCappedAtAViewfinderSizedResolution() {
        XCTAssertEqual(CaptureFormatChooser.maximumVideoPixels, 1920 * 1440)
        // The format that was actually chosen on device, and the cap that rejects it.
        XCTAssertGreaterThan(4032 * 3024, CaptureFormatChooser.maximumVideoPixels)
        // The one that should be chosen instead, with the size it actually has.
        XCTAssertLessThanOrEqual(1920 * 1440, CaptureFormatChooser.maximumVideoPixels)
    }

    /// The still resolution comes from the *largest* entry, not the first or the smallest.
    ///
    /// Device data: the chosen format advertised `4032x3024 still | 1920x1440 video` and every
    /// capture came back 1920x1440, because nothing ever raised the format's
    /// `maxPhotoDimensions` off the video-linked default. This is the value that fixes it,
    /// so picking the wrong end of the list would reintroduce the same bug.
    func testTheLargestAdvertisedStillIsTheOneAskedFor() {
        let advertised = [
            CMVideoDimensions(width: 1920, height: 1440),
            CMVideoDimensions(width: 4032, height: 3024),
            CMVideoDimensions(width: 2016, height: 1512)
        ]
        let largest = CaptureFormatChooser.largestPhotoDimensions(in: advertised)
        XCTAssertEqual(largest?.width, 4032)
        XCTAssertEqual(largest?.height, 3024)
        XCTAssertNil(CaptureFormatChooser.largestPhotoDimensions(in: []),
                     "a format advertising nothing must not invent a still size")
    }

    /// A full-size still is more pixels than the capped video stream, which is the whole
    /// reason the two are separate numbers.
    func testTheAdvertisedStillIsLargerThanTheCappedVideoStream() {
        let still = CMVideoDimensions(width: 4032, height: 3024)
        let video = CaptureFormatChooser.maximumVideoPixels
        XCTAssertGreaterThan(Int(still.width) * Int(still.height), video,
                             "the still must not be limited by the viewfinder cap")
    }

    /// JPEG is asked for first, even when HEVC is available.
    ///
    /// Observed on device: `codecs: jpeg, hvc1` and the chooser took `hvc1`, so every photo
    /// was stored as HEIC. That file is valid, but a photo the user cannot open outside the
    /// app that took it is a poor default for a camera.
    func testStillPhotosAskForJpegBeforeHevc() {
        XCTAssertEqual(PhotoCaptureController.preferredCodec(in: [.hevc, .jpeg]), .jpeg)
        XCTAssertEqual(PhotoCaptureController.preferredCodec(in: [.jpeg]), .jpeg)
        // HEVC is still used when it is all there is, rather than failing.
        XCTAssertEqual(PhotoCaptureController.preferredCodec(in: [.hevc]), .hevc)
        XCTAssertNil(PhotoCaptureController.preferredCodec(in: []))
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

    /// Both cameras get the same angle, and mirroring is what makes the front camera a
    /// selfie preview. A mirror composed with a 180° rotation is a vertical flip, so an
    /// angle 180° from the back camera's is exactly the upside down front preview seen on
    /// device.
    func testPreviewRotationIsIdenticalForBothCameras() {
        XCTAssertEqual(PreviewRotation.angle(for: .portrait, facing: .back), 90)
        XCTAssertEqual(PreviewRotation.angle(for: .portrait, facing: .front), 90)
        XCTAssertEqual(PreviewRotation.angle(for: .portraitUpsideDown, facing: .back), 270)
        XCTAssertEqual(PreviewRotation.angle(for: .portraitUpsideDown, facing: .front), 270)
        XCTAssertEqual(PreviewRotation.angle(for: .landscapeLeft, facing: .back), 0)
        XCTAssertEqual(PreviewRotation.angle(for: .landscapeRight, facing: .back), 180)
        XCTAssertEqual(PreviewRotation.angle(for: .landscapeLeft, facing: .front), 0)
        XCTAssertEqual(PreviewRotation.angle(for: .landscapeRight, facing: .front), 180)
    }

    /// `UIDevice` reports face-up, face-down and unknown while the phone is flat on a
    /// table, which must not throw the preview sideways.
    func testAmbiguousDeviceOrientationsFallBackToPortrait() {
        for orientation in [UIDeviceOrientation.unknown, .faceUp, .faceDown] {
            XCTAssertEqual(PreviewRotation.angle(for: orientation, facing: .back), 90)
            XCTAssertEqual(PreviewRotation.angle(for: orientation, facing: .front), 90)
        }
    }

    // MARK: - Build identity

    /// The log file is read long after the run that wrote it, often attached to a report
    /// about which build had the bug. It has to name the build from the inside, and the one
    /// thing it must never do is print an unsubstituted Info.plist key — that reads exactly
    /// like a real build name and is the failure this is here to prevent.
    func testBuildIdentityNamesTheBinaryAndNeverAnUnsubstitutedKey() {
        XCTAssertFalse(AppVersion.build.isEmpty)
        XCTAssertFalse(AppVersion.isUnsubstituted(AppVersion.build))
        XCTAssertFalse(AppVersion.description.isEmpty)
        XCTAssertTrue(AppVersion.description.contains(AppVersion.build),
                      "the run banner has to contain the build it claims")
        XCTAssertTrue(AppVersion.description.hasPrefix(AppVersion.channel + " v"),
                      "the banner leads with the channel and version, which is what is read first")
        XCTAssertTrue(AppVersion.description.contains("build "))
    }

    /// The version is labelled, not printed as a bare number: a log that says only "1.0.0"
    /// cannot say whether that was a released build or a test build of that version.
    func testReleaseLabelIsTheVersionUnderItsChannel() {
        let label = AppVersion.releaseLabel
        XCTAssertTrue(label.hasPrefix("beta v"), "expected a beta label, got \(label)")
        XCTAssertTrue(label.contains("1.0.0"), "expected 1.0.0 in \(label)")
    }

    func testAnUnsubstitutedBuildSettingIsRecognised() {
        XCTAssertTrue(AppVersion.isUnsubstituted("$(LUMAFRAME_BUILD)"))
        XCTAssertFalse(AppVersion.isUnsubstituted("977f590"))
        XCTAssertFalse(AppVersion.isUnsubstituted("local"))
        XCTAssertFalse(AppVersion.isUnsubstituted(""))
    }

    /// Two exports from two runs are attached to the same report, so their names have to
    /// differ. A dot turns the commit into an apparent file extension and a slash turns the
    /// export path into a directory.
    func testBuildIdentityIsSafeForAnExportFileName() {
        let safe = AppVersion.fileNameSafeBuild
        XCTAssertFalse(safe.isEmpty)
        XCTAssertFalse(safe.contains("."), "a dot reads as a file extension")
        XCTAssertFalse(safe.contains("/"), "a slash makes the export path a directory")
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

    // MARK: - Zoom track

    func testZoomTrackRoundTripsEveryPosition() {
        // The slider stores a position and the camera stores a factor. If these are not exact
        // inverses, letting go of the slider lands somewhere the user did not drag to.
        let range = 1.0...25.0
        for step in stride(from: 0.0, through: 1.0, by: 0.05) {
            let factor = CameraViewModel.zoomFactor(forPosition: step, in: range)
            let back = CameraViewModel.zoomPosition(forFactor: factor, in: range)
            XCTAssertEqual(back, step, accuracy: 0.0001, "position \(step) did not round trip")
        }
    }

    func testZoomTrackIsMonotonic() {
        // A curve that doubled back would make the same factor reachable from two places and
        // send a drag the wrong way.
        let range = 1.0...25.0
        var previous = -1.0
        for step in stride(from: 0.0, through: 1.0, by: 0.01) {
            let factor = CameraViewModel.zoomFactor(forPosition: step, in: range)
            XCTAssertGreaterThan(factor, previous, "factor fell at position \(step)")
            previous = factor
        }
    }

    func testZoomTrackKeepsTheLensStopsUsable() {
        // The reason the track is curved at all: 2x and 4x must stay in the left half of the
        // slider, or reaching them becomes a drag across the whole screen.
        let range = 1.0...25.0
        XCTAssertLessThan(CameraViewModel.zoomPosition(forFactor: 2, in: range), 0.35)
        XCTAssertLessThan(CameraViewModel.zoomPosition(forFactor: 4, in: range), 0.5)
    }

    func testZoomTrackSpansTheWholeRangeAtItsEnds() {
        let range = 1.0...25.0
        XCTAssertEqual(CameraViewModel.zoomFactor(forPosition: 0, in: range), 1, accuracy: 0.0001)
        XCTAssertEqual(CameraViewModel.zoomFactor(forPosition: 1, in: range), 25, accuracy: 0.0001)
        XCTAssertEqual(CameraViewModel.zoomPosition(forFactor: 1, in: range), 0, accuracy: 0.0001)
        XCTAssertEqual(CameraViewModel.zoomPosition(forFactor: 25, in: range), 1, accuracy: 0.0001)
    }

    func testZoomTrackSurvivesADegenerateRange() {
        // The session can be torn down mid-drag, and the range collapses to 1...1. Dividing
        // by that span is how a slider ends up with a NaN knob.
        let flat = 1.0...1.0
        XCTAssertEqual(CameraViewModel.zoomPosition(forFactor: 1, in: flat), 0)
        XCTAssertEqual(CameraViewModel.zoomFactor(forPosition: 0.5, in: flat), 1, accuracy: 0.0001)
    }

    func testZoomTrackClampsPositionsOutsideTheTrack() {
        let range = 1.0...25.0
        XCTAssertEqual(CameraViewModel.zoomFactor(forPosition: -1, in: range), 1, accuracy: 0.0001)
        XCTAssertEqual(CameraViewModel.zoomFactor(forPosition: 2, in: range), 25, accuracy: 0.0001)
        XCTAssertEqual(CameraViewModel.zoomPosition(forFactor: 0.2, in: range), 0, accuracy: 0.0001)
        XCTAssertEqual(CameraViewModel.zoomPosition(forFactor: 99, in: range), 1, accuracy: 0.0001)
    }

    // MARK: - Recipe identity

    func testAnUntouchedRecipeIsTheIdentityRecipe() {
        // The identity fast path is what keeps the direct preview layer on screen: any
        // set value must flip it off, or the processed preview would never appear.
        XCTAssertTrue(ProcessingSettings.none.isIdentity)
        var settings = ProcessingSettings.none
        settings.grain = 1
        XCTAssertFalse(settings.clamped().isIdentity,
                       "a set value must not report itself as nothing to do")
    }

    // MARK: - Gallery entries

    private func savedPhoto(_ name: String,
                            container: PhotoContainer = .jpeg,
                            capturedAt: TimeInterval = 0,
                            derivedFrom: UUID? = nil) -> SavedPhoto {
        var metadata = CaptureMetadata(mode: "auto")
        metadata.derivedFrom = derivedFrom
        return SavedPhoto(id: UUID(),
                          url: URL(fileURLWithPath: "/tmp/\(name)"),
                          capturedAt: Date(timeIntervalSince1970: capturedAt),
                          container: container,
                          metadata: metadata)
    }

    func testACaptureWithAndWithoutAGradeIsOneGridEntry() {
        // Processing writes a second file beside the original rather than replacing it. Both are
        // real and both stay on disk, but one shutter press filling two cells reads as two
        // photos having been taken.
        let original = savedPhoto("original", capturedAt: 100)
        let processed = savedPhoto("processed", capturedAt: 101, derivedFrom: original.id)
        XCTAssertEqual(GalleryView.entries(from: [processed, original]).count, 1)
    }

    func testTheGradedVersionIsTheEntryThatSurvives() {
        // What the user saw on screen is what should open when they tap the capture.
        let original = savedPhoto("original", capturedAt: 100)
        let processed = savedPhoto("processed", capturedAt: 101, derivedFrom: original.id)
        XCTAssertEqual(GalleryView.entries(from: [processed, original]).first?.url,
                       processed.url)
    }

    func testCapturesWithoutAGradeEachGetAnEntry() {
        let first = savedPhoto("a", capturedAt: 100)
        let second = savedPhoto("b", capturedAt: 200)
        XCTAssertEqual(GalleryView.entries(from: [second, first]).count, 2)
    }

    func testGalleryEntriesAreNewestFirst() {
        // Dictionary iteration order is not stable, so the grid would reshuffle itself
        // between launches if the grouping did not re-sort.
        let first = savedPhoto("a", capturedAt: 100)
        let second = savedPhoto("b", capturedAt: 300)
        let third = savedPhoto("c", capturedAt: 200)
        let entries = GalleryView.entries(from: [first, third, second])
        // `capturedAt` is a `Date`, so this compares the dates themselves rather than
        // mapping to a number and hoping the conversion is the thing under test.
        let stamps: [Date] = entries.map(\.capturedAt)
        XCTAssertEqual(stamps, [
            Date(timeIntervalSince1970: 300),
            Date(timeIntervalSince1970: 200),
            Date(timeIntervalSince1970: 100)
        ])
    }

    func testAnEmptyLibraryIsAnEmptyGalleryNotACrash() {
        XCTAssertTrue(GalleryView.entries(from: []).isEmpty)
    }

    func testLibraryAccessErrorExplainsWhereToReEnableIt() {
        // The denial is only recoverable in Settings, so the message has to say so.
        let message = PhotoStoreError.libraryAccessDenied.errorDescription ?? ""
        XCTAssertTrue(message.contains("Privacy"), "the message should name the Settings path")
    }

    // MARK: - Recipe read back

    func testARecipeSurvivesTheRoundTripThroughItsOwnFile() {
        // The gallery reads what a shot was back out of the file's own metadata, so the
        // decoder has to recover the fields a reader actually displays.
        var written = CaptureMetadata(mode: "looks")
        written.iso = 400
        written.shutterSeconds = 1.0 / 120.0
        written.exposureTargetOffset = -0.3
        written.lensRelativeScale = 24
        written.lensKind = "AVCaptureDeviceTypeBuiltInTelephotoCamera"
        written.zoomFactor = 4.08
        written.photoQualityPrioritization = "quality"
        written.frontCamera = true
        written.colorSpace = "display-p3"
        written.hdrStatus = "qualityRequested"

        let read = CaptureMetadata.decoding(recipe: written.recipeString())
        XCTAssertEqual(read.mode, "looks")
        XCTAssertEqual(read.iso, 400)
        XCTAssertEqual(read.shutterSeconds ?? 0, 1.0 / 120.0, accuracy: 0.000_001)
        XCTAssertEqual(read.exposureTargetOffset ?? 0, -0.3, accuracy: 0.000_1)
        XCTAssertEqual(read.lensRelativeScale, 24)
        XCTAssertEqual(read.lensKind, "AVCaptureDeviceTypeBuiltInTelephotoCamera")
        XCTAssertEqual(read.zoomFactor ?? 0, 4.08, accuracy: 0.000_1)
        XCTAssertEqual(read.photoQualityPrioritization, "quality")
        XCTAssertTrue(read.frontCamera)
        XCTAssertEqual(read.colorSpace, "display-p3")
        XCTAssertEqual(read.hdrStatus, "qualityRequested")
    }

    func testAnUnreadableRecipeDegradesInsteadOfFailing() {
        // A photo must still open when its recipe is from a future version or is simply
        // garbage. Defaults are the honest answer: nothing recorded is not a measurement.
        let read = CaptureMetadata.decoding(recipe: "v9;iso=notanumber;garbage")
        XCTAssertEqual(read.mode, "auto")
        XCTAssertNil(read.iso)
        XCTAssertFalse(read.frontCamera)
    }

    func testTheLensKindResolvesFromTheRawDeviceType() {
        // The file stores `deviceType.rawValue` so it outlives a rename of the app's own
        // enum, which means the display name can only be resolved at read time.
        let telephoto = "AVCaptureDeviceTypeBuiltInTelephotoCamera"
        XCTAssertEqual(BackCameraCapabilities.kind(ofRawValue: telephoto).zoomLabel,
                       "Telephoto")
        XCTAssertEqual(BackCameraCapabilities.kind(ofRawValue: "something-else"),
                       .unknown)
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

    /// Every mode keeps a label, and the switcher's order is the chrome that
    /// `DESIGN_SPEC.md` requires not to move.
    func testEveryModeIsLabelledAndInOrder() {
        for mode in CameraMode.allCases {
            XCTAssertFalse(mode.label.isEmpty, "\(mode) needs a label")
        }
        XCTAssertEqual(CameraMode.allCases, [.photo, .video, .pro])
    }

    /// Video reports itself unimplemented rather than pretending.
    ///
    /// There is no recorder in the app — no `AVCaptureMovieFileOutput`, no start/stop, no
    /// audio input — so a Video button that switched to a viewfinder you cannot record from
    /// would be worse than a disabled one.
    func testVideoReportsItselfUnimplementedUntilThereIsARecorder() {
        XCTAssertFalse(CameraMode.video.isImplemented)
        XCTAssertTrue(CameraMode.photo.isImplemented)
        XCTAssertTrue(CameraMode.pro.isImplemented)
    }

    /// Looks is no longer a mode; grading lives under Pro.
    func testLooksIsNotAMode() {
        XCTAssertFalse(CameraMode.allCases.contains { $0.label == "Looks" })
    }

    // MARK: - Lens pills

    /// The pills are the three physical lenses, whatever the device calls them.
    func testLensPillsAreHalfOneAndTwo() {
        let stops = CameraViewModel.lensStops()
        XCTAssertEqual(stops.map(\.factor), [0.5, 1, 2])
        XCTAssertEqual(stops.map(\.label), ["0.5x", "1x", "2x"])
    }

    /// The device cannot express 0.5x as a factor, so the pill is translated to its own
    /// scale: 0.5x asks for 1x, 1x asks for 2x, 2x asks for 4x. That is the same ×2 that
    /// makes the device report its switch points as 2 and 4.
    func testLensPillsAreTranslatedToTheDevicesOwnScale() {
        XCTAssertEqual(CameraViewModel.requestedFactor(forLens: 0.5, minimumAvailableFactor: 1), 1)
        XCTAssertEqual(CameraViewModel.requestedFactor(forLens: 1, minimumAvailableFactor: 1), 2)
        XCTAssertEqual(CameraViewModel.requestedFactor(forLens: 2, minimumAvailableFactor: 1), 4)
    }

    /// A device that *can* express 0.5x needs no translation, so the mapping is derived from
    /// the device's floor rather than hardcoded to a ×2.
    func testNoTranslationWhenTheDeviceCanExpressTheLensDirectly() {
        for lens in [0.5, 1, 2] {
            XCTAssertEqual(CameraViewModel.requestedFactor(forLens: lens, minimumAvailableFactor: 0.5),
                           lens)
        }
    }

    /// A 4x stop is the 2x telephoto cropped again, so it must not sit beside the lenses.
    func testThePillsNeverOfferACropAsIfItWereALens() {
        XCTAssertFalse(CameraViewModel.lensStops().map(\.factor).contains(4),
                       "4x is a crop of the 2x, not a lens")
    }

    /// In Pro mode each pill binds its constituent rather than zooming the composite,
    /// so the pill has to resolve to a lens kind. Anything off the three pills binds
    /// nothing — a stray value must never select a wrong lens.
    func testLensPillsMapToConstituentKinds() {
        XCTAssertEqual(CameraViewModel.kindForLensPill(0.5), .ultraWide)
        XCTAssertEqual(CameraViewModel.kindForLensPill(1.0), .wide)
        XCTAssertEqual(CameraViewModel.kindForLensPill(2.0), .telephoto)
        XCTAssertNil(CameraViewModel.kindForLensPill(4.0),
                     "4x is a crop of the telephoto, not a fourth lens")
        XCTAssertNil(CameraViewModel.kindForLensPill(0.0))
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

    /// A dialled Kelvin survives clamping only where custom gains can be locked, is
    /// clamped to the documented range, and always brings the lock with it — a
    /// temperature with AWB balancing over it contradicts itself.
    func testKelvinIsGatedClampedAndImpliesTheLock() {
        var capable = ProCapabilities(supportsCustomExposure: true)
        capable.canLockWhiteBalance = true
        capable.kelvinRange = 3000...8000

        let dialled = ManualSettings(lockWhiteBalance: false, kelvin: 9000).clamped(to: capable)
        XCTAssertEqual(dialled.kelvin, 8000)
        XCTAssertTrue(dialled.lockWhiteBalance, "a temperature without the lock is a contradiction")

        var incapable = ProCapabilities(supportsCustomExposure: true)
        incapable.canLockWhiteBalance = false
        let withdrawn = ManualSettings(lockWhiteBalance: true, kelvin: 5200).clamped(to: incapable)
        XCTAssertNil(withdrawn.kelvin)
        XCTAssertFalse(withdrawn.lockWhiteBalance)
    }

    /// Gains past the device maximum are refused before they reach AVFoundation, and
    /// non-finite gains become neutral rather than surviving into the lock call.
    func testGainsClampToTheDeviceMaximum() {
        let gains = AVCaptureDevice.WhiteBalanceGains(redGain: 9, greenGain: .nan, blueGain: 0.2)
        let clamped = CaptureSessionController.clampedGains(gains, ceiling: 4)

        XCTAssertEqual(clamped.redGain, 4)
        XCTAssertEqual(clamped.greenGain, 1)
        XCTAssertEqual(clamped.blueGain, 1, "below 1 is not a gain any device accepts")
    }

    /// Three readout states, not two: a temperature, a bare lock, and automatic.
    @MainActor
    func testWhiteBalanceReadoutNamesTheTemperature() {
        XCTAssertEqual(ProParameter.whiteBalance.readout(ManualSettings(kelvin: 5200)), "5200K")
        XCTAssertEqual(ProParameter.whiteBalance.readout(ManualSettings(lockWhiteBalance: true)),
                       "Locked")
        XCTAssertEqual(ProParameter.whiteBalance.readout(ManualSettings.none), "Auto")
        XCTAssertTrue(ProParameter.whiteBalance.isAutomatic(ManualSettings.none))
        XCTAssertFalse(ProParameter.whiteBalance.isAutomatic(ManualSettings(kelvin: 5200)))
    }

    /// Out-of-frame taps clamp to the edge rather than reaching the device: the
    /// field log showed points like x=1.08, y=-2.17, and `focusPointOfInterest`
    /// only takes 0…1.
    func testFocusPointsClampToTheFrame() {
        XCTAssertEqual(CaptureSessionController.clampedFocusPoint(CGPoint(x: 1.08, y: -2.17)),
                       CGPoint(x: 1, y: 0))
        XCTAssertEqual(CaptureSessionController.clampedFocusPoint(CGPoint(x: 0.4, y: 0.6)),
                       CGPoint(x: 0.4, y: 0.6))
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

    /// The empty Pro panel must collapse into its reason, not render an empty strip.
    /// `contextualRow` switches on `rowContent`, so this pins the decision the view
    /// reads: a composite-like set offers no chips, and the row must be the reason.
    ///
    /// `@MainActor` for the same reason as the chip test above: `ProParameter` is
    /// main-actor isolated.
    @MainActor
    func testProRowShowsTheReasonWhenNoParameterSurvivesGating() {
        let compositeLike = ProCapabilities(supportsCustomExposure: false, isCompositeDevice: true)

        guard case .reason(let text) = ProParameter.rowContent(for: compositeLike) else {
            return XCTFail("a composite-like set offers no chips, so the row must be a reason")
        }
        XCTAssertEqual(text, compositeLike.availabilitySummary,
                       "the displayed reason is the summary, not a second copy of it")
        XCTAssertTrue(text.contains("composite"), "the reason must name the cause: \(text)")
    }

    /// The converse: a capable set offers chips, in the picker's order, and never the
    /// reason line.
    @MainActor
    func testProRowShowsChipsWhenParametersSurviveGating() {
        let capable = ProCapabilities(
            supportsCustomExposure: true,
            isoRange: 50...400,
            shutterRange: (1.0 / 8000)...(1.0 / 30),
            exposureCompensationRange: -3...3,
            canLockExposure: true,
            canLockFocus: true,
            canLockWhiteBalance: true
        )

        guard case .chips(let chips) = ProParameter.rowContent(for: capable) else {
            return XCTFail("a capable set must offer chips, not a reason")
        }
        XCTAssertEqual(chips, [.iso, .shutter, .exposure, .focus, .whiteBalance])
    }
}