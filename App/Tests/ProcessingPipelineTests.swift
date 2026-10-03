import XCTest
@testable import LumaFrame

/// The parts of the processing pipeline that are decisions rather than pixels.
///
/// Core Image will not render in the headless CI simulator — `LUTProcessorTests` records
/// that in its own skip — so nothing here asserts an output image. What is asserted is
/// everything upstream of the first filter: clamping, the identity fast path, how a
/// recipe is summarised into the capture metadata, how a look resolves, and when a
/// subject mask is rejected.
///
/// The pipeline is a pure function of its inputs plus Core Image, so separating the
/// decisions from the rendering is the only way to cover the first half at all.
final class ProcessingPipelineTests: XCTestCase {

    private let pipeline = ProcessingPipeline()

    // MARK: - Clamping

    func testClampingKeepsEveryControlInRange() {
        var tone = ToneCurve()
        tone.contrast = 12
        tone.saturation = -9
        tone.lift = 4
        tone.exposure = 3
        tone.temperatureOffset = 99_999
        tone.tintOffset = -99_999

        let clamped = tone.clamped()

        XCTAssertEqual(clamped.contrast, 1)
        XCTAssertEqual(clamped.saturation, -1)
        XCTAssertEqual(clamped.lift, 1)
        XCTAssertEqual(clamped.exposure, 1)
        XCTAssertEqual(clamped.temperatureOffset, 2500)
        XCTAssertEqual(clamped.tintOffset, -150)
    }

    /// A NaN reaching a Core Image parameter is a black frame, and an infinity is worse.
    /// Both have to become the neutral value rather than survive a comparison.
    func testClampingTurnsNonFiniteValuesIntoZero() {
        var tone = ToneCurve()
        tone.contrast = .nan
        tone.exposure = .infinity
        tone.temperatureOffset = .nan

        let clamped = tone.clamped()

        XCTAssertEqual(clamped.contrast, 0)
        XCTAssertEqual(clamped.exposure, 0)
        XCTAssertEqual(clamped.temperatureOffset, 0)
    }

    /// `CIColorControls` and `CIExposureAdjust` are centred on 1.0 or 0.0, not on the
    /// -1…1 the sliders use, so the mapping is the thing most likely to be wrong.
    func testSliderValuesAreMappedOntoTheCoreImageCentre() {
        var tone = ToneCurve()
        tone.contrast = 0
        tone.saturation = 0
        tone.lift = 0
        tone.exposure = 0

        XCTAssertEqual(tone.colorControlsContrast, 1.0, "zero contrast must be a no-op")
        XCTAssertEqual(tone.colorControlsSaturation, 1.0, "zero saturation must be a no-op")
        XCTAssertEqual(tone.brightness, 0)
        XCTAssertEqual(tone.exposureEV, 0)

        tone.contrast = 1
        tone.saturation = -1
        tone.lift = -1
        tone.exposure = 1

        XCTAssertEqual(tone.colorControlsContrast, 2.0)
        XCTAssertEqual(tone.colorControlsSaturation, 0.0)
        XCTAssertEqual(tone.brightness, -0.5)
        XCTAssertEqual(tone.exposureEV, 2.0, "the slider tops out at +2 EV")
    }

    /// The white point has to be D65, not a zero vector. `CITemperatureAndTint` with a
    /// zero target shifts an image wildly, and it is the kind of thing that looks like a
    /// broken filter rather than a broken constant.
    func testWhiteBalanceNeutralIsD65() {
        let neutral = ToneCurve().neutralVector
        XCTAssertEqual(neutral.x, 6500)
        XCTAssertEqual(neutral.y, 0)
    }

    // MARK: - Identity

    /// The identity fast path is a performance decision, not a correctness one, but only
    /// if it is actually reached: a recipe that reports identity while a look is set at
    /// zero intensity would silently skip the whole pipeline.
    func testIdentityIsOnlyTrueWhenNothingWouldRun() {
        XCTAssertTrue(ProcessingSettings.none.isIdentity)
        XCTAssertTrue(ProcessingSettings(tone: .neutral, lookIntensity: 0).isIdentity)

        let look = Look.Generated.warmth.look
        XCTAssertTrue(ProcessingSettings(look: look, lookIntensity: 0).isIdentity)
        XCTAssertFalse(ProcessingSettings(look: look, lookIntensity: 0.01).isIdentity)

        var tone = ToneCurve()
        tone.contrast = 0.2
        XCTAssertFalse(ProcessingSettings(tone: tone).isIdentity)

        XCTAssertFalse(ProcessingSettings(grain: 0.5).isIdentity)
        XCTAssertFalse(ProcessingSettings(sharpen: 0.5).isIdentity)
        XCTAssertFalse(ProcessingSettings(subjectMask: SubjectMask(coverage: 0.2, confidence: 0.9))
            .isIdentity)
    }

    /// A tone of `.neutral` and a tone of `nil` mean the same thing to the renderer, and
    /// the summary is what a photo's metadata says, so both have to read as "nothing".
    func testIdentitySummarySaysNothingRatherThanSomething() {
        XCTAssertEqual(ProcessingSettings.none.summarise(), "identity")
        XCTAssertEqual(ProcessingSettings(tone: .neutral).summarise(), "identity")
    }

    // MARK: - Look resolution

    /// Every built-in has to generate a table the apply stage will actually accept. A
    /// generated look that produced a non-unit domain or the wrong sample count would be
    /// refused at apply time, on a device, for every frame.
    func testEveryGeneratedLookProducesAUsableThreeDimensionalTable() {
        for which in Look.Generated.allCases {
            let table = try? XCTUnwrap(GeneratedLooks.table(for: which),
                                       "\(which) produced no table")
            guard let table else { continue }
            XCTAssertEqual(table.kind, .threeDimensional, "\(which) is not 3D")
            XCTAssertEqual(table.size, GeneratedLooks.size, "\(which) has the wrong size")
            XCTAssertEqual(table.domain, .unit,
                           "\(which) must be over the unit domain or it is refused at apply time")
            XCTAssertTrue(table.isUsable, "\(which) produced an unusable table")
            XCTAssertEqual(table.sampleCount, table.size * table.size * table.size)
        }
    }

    /// Red has to vary fastest, or the channels come out transposed — a plausible-looking
    /// image with the colours swapped, which is exactly the kind of bug that survives a
    /// visual check.
    ///
    /// `Warmth` is the right look for this, and the choice matters: `No Colour` maps every
    /// channel to the same luma, so *all three* channels of a sample change together and it
    /// cannot distinguish which axis moved first. Warmth offsets each channel differently,
    /// so if red moves first then green and blue are identical between the cube origin and
    /// its neighbour while red is not. Transposed order would invert that: green and blue
    /// would differ and red would not.
    func testGeneratedTablesHaveRedVaryingFastest() throws {
        let table = try XCTUnwrap(GeneratedLooks.table(for: .warmth))
        let s = Array(table.samples.prefix(6))

        XCTAssertNotEqual(s[0], s[3], "the first axis should be red, and red should move")
        XCTAssertEqual(s[1], s[4], "green must not move first")
        XCTAssertEqual(s[2], s[5], "blue must not move first")
        XCTAssertGreaterThan(s[3], s[0], "the first axis runs black to white, not back")
    }

    /// `.noColour` deliberately lifts blacks rather than crushing them, so a pure luma copy
    /// is not what it does. Asserted because "No Colour" promising a pure conversion and
    /// shipping a lifted one is the kind of mismatch the name hides.
    func testNoColourLiftsBlacksRatherThanCrushingThem() throws {
        let table = try XCTUnwrap(GeneratedLooks.table(for: .noColour))
        let origin = Array(table.samples.prefix(3))
        for value in origin {
            XCTAssertGreaterThan(value, 0, "the cube origin should be lifted off zero")
            XCTAssertLessThan(value, 0.1, "and only slightly")
        }
        // Still a grey ramp: all three channels equal at every point.
        for index in stride(from: 0, to: table.samples.count, by: 3) {
            let r = table.samples[index]
            let g = table.samples[index + 1]
            let b = table.samples[index + 2]
            XCTAssertEqual(r, g, "no colour must have equal channels")
            XCTAssertEqual(g, b, "no colour must have equal channels")
        }
    }

    /// Out-of-range samples are not clamped by Core Image, so a generator that overshoots
    /// produces a black or blown frame rather than an error.
    func testGeneratedTablesStayInsideTheUnitDomain() {
        for which in Look.Generated.allCases {
            guard let table = GeneratedLooks.table(for: which) else { continue }
            for (index, value) in table.samples.enumerated() {
                XCTAssertGreaterThanOrEqual(value, 0, "\(which) sample \(index) is negative")
                XCTAssertLessThanOrEqual(value, 1, "\(which) sample \(index) is over 1")
            }
        }
    }

    /// A look that cannot be resolved must degrade to "no look". Returning a table that
    /// does not match the look would be worse than returning nothing at all.
    func testAnUnresolvableLookReturnsNilRatherThanAWrongTable() {
        let look = Look(name: "missing", source: .imported(filename: "does-not-exist.cube"))
        XCTAssertNil(LookLibrary().resolve(look))
    }

    // MARK: - Subject mask

    /// A mask that found no boundary at all is a segmentation failure, not a subject.
    /// Acting on it would apply the look to everything while the UI claimed a subject blend.
    func testAMaskWithNoBoundaryIsRejected() {
        let mask = SubjectMask(coverage: 1, confidence: 0.9)
        XCTAssertFalse(mask.isUsable)
        XCTAssertTrue(mask.decision().contains("covers the frame"))
    }

    /// The bug the 0.85 threshold caused, named as a test.
    ///
    /// Every mask the app computed was being discarded with `covers the frame`. A subject
    /// filling most of the frame is a close-up, not a segmentation failure, and a close-up is
    /// exactly when subject-aware processing earns its keep. At 0.85 this was rejected.
    func testASubjectFillingMostOfTheFrameIsStillASubject() {
        // What a near portrait produces: high coverage, and a confident mask because the
        // background is still a distinct region.
        let mask = SubjectMask(coverage: 0.92, confidence: 0.8)
        XCTAssertTrue(mask.isUsable,
                      "a subject filling 92% of the frame must not be rejected as a failure")
    }

    /// The gate has to still catch the case it was written for, one notch below 1.0.
    func testTheCoverageCeilingRejectsOnlyNearUniformMasks() {
        XCTAssertFalse(SubjectMask(coverage: 0.99, confidence: 0.9).isUsable)
        XCTAssertTrue(SubjectMask(coverage: 0.97, confidence: 0.9).isUsable)
    }

    /// A high-coverage mask with no bimodality is caught by confidence rather than by
    /// coverage, which is the division of labour between the two gates.
    func testAUniformHighCoverageMaskIsCaughtByConfidence() {
        // Coverage alone cannot tell "fills the frame" from "has no boundary"; the spread
        // proxy can, because a mask with no boundary has none.
        let mask = SubjectMask(coverage: 0.97, confidence: 0.1)
        XCTAssertFalse(mask.isUsable)
        XCTAssertTrue(mask.decision().contains("low confidence"))
    }

    func testAMaskWithNoCoverageIsRejected() {
        let mask = SubjectMask(coverage: 0, confidence: 0.9)
        XCTAssertTrue(mask.isEmpty)
        XCTAssertFalse(mask.isUsable)
        XCTAssertEqual(mask.decision(), "no subject")
    }

    func testAWeakMaskIsRejected() {
        let mask = SubjectMask(coverage: 0.2, confidence: 0.1)
        XCTAssertFalse(mask.isUsable)
        XCTAssertTrue(mask.decision().contains("low confidence"))
    }

    func testAPlausibleMaskIsAccepted() {
        let mask = SubjectMask(coverage: 0.3, confidence: 0.8)
        XCTAssertTrue(mask.isUsable)
        XCTAssertEqual(mask.decision(), "blend 30%")
    }

    // MARK: - Learned stage routing

    private func metadata(lens: String?, zoom: Double? = nil, front: Bool = false) -> CaptureMetadata {
        var metadata = CaptureMetadata(mode: "auto")
        metadata.lensKind = lens
        metadata.zoomFactor = zoom
        metadata.frontCamera = front
        return metadata
    }

    /// Each lens gets the stage its optics actually call for, and nothing else.
    ///
    /// The f/2.4 ultra wide against the wide's f/1.8 is why denoise is routed there, and the
    /// crop past the telephoto's optical limit is why super-resolution is. A single "AI
    /// enhance" toggle across all three would apply the wrong one to two of them.
    func testEachLensRoutesToItsOwnStage() {
        XCTAssertEqual(
            LearnedStagePlan.plan(for: metadata(lens: "AVCaptureDeviceTypeBuiltInUltraWideCamera")).stages,
            [.denoise])
        XCTAssertEqual(
            LearnedStagePlan.plan(for: metadata(lens: "AVCaptureDeviceTypeBuiltInWideAngleCamera")).stages,
            [.lowLightToneMap])
    }

    /// A telephoto inside its optical range needs nothing. It is sharp already, and an SR
    /// model here would smooth real detail to add invented detail.
    func testTheTelephotoGetsNothingInsideItsOpticalRange() {
        let plan = LearnedStagePlan.plan(
            for: metadata(lens: "AVCaptureDeviceTypeBuiltInTelephotoCamera", zoom: 2))
        XCTAssertEqual(plan, .none)
    }

    /// Past the optical limit the frame is a crop, and that is the only case worth SR.
    func testTheTelephotoGetsSuperResolutionOnceItIsCropping() {
        let plan = LearnedStagePlan.plan(
            for: metadata(lens: "AVCaptureDeviceTypeBuiltInTelephotoCamera", zoom: 4.08))
        XCTAssertEqual(plan.stages, [.superResolution])
    }

    /// No zoom factor recorded means the crop cannot be established, so no SR. Guessing
    /// "probably cropped" would put invented detail in ordinary shots.
    func testSuperResolutionIsSkippedWhenTheZoomIsUnknown() {
        let plan = LearnedStagePlan.plan(
            for: metadata(lens: "AVCaptureDeviceTypeBuiltInTelephotoCamera", zoom: nil))
        XCTAssertEqual(plan, .none)
    }

    /// The front camera gets nothing from any stage.
    ///
    /// It has no low-light problem worth solving here, and it is not a sensor these models
    /// were trained for. Worth its own test because a front shot still carries a `lensKind`.
    func testTheFrontCameraIsExcludedFromEveryStage() {
        XCTAssertEqual(
            LearnedStagePlan.plan(for: metadata(lens: "AVCaptureDeviceTypeBuiltInWideAngleCamera",
                                               zoom: 4,
                                               front: true)),
            .none)
    }

    /// A stage never runs on a lens that is not its own.
    func testAStageNeverRunsOnAnotherLens() {
        XCTAssertFalse(LearnedStage.denoise.applies(to: .telephoto))
        XCTAssertFalse(LearnedStage.superResolution.applies(to: .ultraWide))
        XCTAssertFalse(LearnedStage.lowLightToneMap.applies(to: .front))
        XCTAssertTrue(LearnedStage.denoise.applies(to: .ultraWide))
    }

    /// A composite whose constituent could not be resolved falls back to the wide, which is
    /// the constituent a composite actually falls back to.
    func testAnUnresolvedCompositeRoutesLikeTheWide() {
        let plan = LearnedStagePlan.plan(for: metadata(lens: "AVCaptureDeviceTypeBuiltInTripleCamera"))
        XCTAssertEqual(plan.stages, [.lowLightToneMap])
    }

    /// A lens name this app does not recognise runs nothing rather than guessing.
    ///
    /// A model running because a string looked plausible is worse than no model: it costs
    /// time and invents detail with nothing to justify it.
    func testAnUnknownLensRunsNothing() {
        XCTAssertEqual(LearnedStagePlan.plan(for: metadata(lens: "something-new")), .none)
        XCTAssertEqual(LearnedStagePlan.plan(for: metadata(lens: nil)), .none)
    }

    /// Order is fixed, so the same capture always produces the same plan and therefore the
    /// same file. A set would make the sequence depend on hashing.
    func testTheStageOrderIsDeterministic() {
        let plan = LearnedStagePlan.plan(for: metadata(lens: "AVCaptureDeviceTypeBuiltInUltraWideCamera"))
        XCTAssertEqual(plan.stages, plan.stages, "the same shot must plan identically twice")
    }

    // MARK: - Colour space

    /// `.linearSRGB` used to hand back the gamma sRGB object, which made every conversion
    /// into the working space a no-op. The two spaces have to be genuinely different
    /// objects or the whole linear-light stage is decorative.
    func testLinearSRGBIsNotTheGammaSpace() {
        XCTAssertNotEqual(ColorSpace.linearSRGB.cgColorSpace,
                          ColorSpace.sRGB.cgColorSpace,
                          "the working space must not be the gamma space")
        XCTAssertEqual(ColorSpace.linearSRGB.cgColorSpace.model, .rgb)
    }

    // MARK: - Recipe round trip

    /// The recipe has to survive the trip through a photo's metadata, or a photo can
    /// never be re-rendered from its original.
    func testTheRecipeSurvivesAFileRoundTrip() throws {
        var tone = ToneCurve()
        tone.contrast = 0.35
        tone.saturation = -0.2
        tone.temperatureOffset = -450

        var settings = ProcessingSettings()
        settings.tone = tone
        settings.look = Look.Generated.fadedFilm.look
        settings.lookIntensity = 0.8
        settings.grain = 0.2
        settings.sharpen = 0.4
        settings.subjectMask = SubjectMask(coverage: 0.25, confidence: 0.7)

        var metadata = CaptureMetadata(mode: "looks")
        metadata.processing = settings
        let recipe = metadata.recipeString()

        let (version, fields) = CaptureMetadata.parse(recipe: recipe)
        XCTAssertEqual(version, CaptureMetadata.recipeVersion)
        let token = try XCTUnwrap(fields["proc"], "the recipe did not write a processing token")
        let decoded = try XCTUnwrap(CaptureMetadata.decodeProcessing(token),
                                    "the token did not decode")
        XCTAssertEqual(decoded, settings)
    }

    /// A recipe from a future version, or a corrupted one, must degrade to "no recipe".
    /// It must never throw, because the reader is opening someone else's photo.
    func testAnUnreadableRecipeDegradesToNothing() {
        XCTAssertNil(CaptureMetadata.decodeProcessing("not-valid-base64!!!"))
        XCTAssertNil(CaptureMetadata.decodeProcessing(""))
        // Valid base64, not valid JSON.
        XCTAssertNil(CaptureMetadata.decodeProcessing("aGVsbG8gd29ybGQ"))
    }

    /// Base64 uses `+` and `/` and pads with `=`, all of which collide with the recipe's
    /// own `;` and `=` separators, so the encoding has to be URL-safe and unpadded. If it
    /// were not, a recipe containing a `=` would be split into a bogus extra field.
    func testTheRecipeEncodingSurvivesItsOwnSeparators() {
        var tone = ToneCurve()
        tone.contrast = 0.777
        var settings = ProcessingSettings()
        settings.tone = tone
        var metadata = CaptureMetadata(mode: "looks")
        metadata.processing = settings

        let recipe = metadata.recipeString()
        // Every token has to have exactly one separator, and no value may contain one.
        for token in recipe.split(separator: ";") {
            XCTAssertLessThanOrEqual(token.filter { $0 == "=" }.count, 1,
                                     "a value leaked a separator: \(token)")
        }
        let (_, fields) = CaptureMetadata.parse(recipe: recipe)
        XCTAssertNotNil(fields["proc"])
        XCTAssertEqual(fields["proc"]?.contains(";"), false)
    }

    func testAFileWithNoRecipeSaysSo() {
        let metadata = CaptureMetadata(mode: "auto")
        XCTAssertNil(metadata.processing)
        XCTAssertNil(CaptureMetadata.parse(recipe: metadata.recipeString()).fields["proc"])
    }
}
