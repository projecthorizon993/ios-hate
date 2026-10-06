import XCTest
@testable import LumaFrame

/// The parts of the processing pipeline that are decisions rather than pixels.
///
/// What is asserted is everything upstream of the first filter: clamping, the identity
/// fast path, how a recipe is summarised into the capture metadata, and the learned
/// stage routing.
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

    /// The newer colour controls clamp to the filter's own -1…1 range, and non-finite
    /// input becomes neutral rather than surviving into `CIHighlightShadowAdjust`.
    func testColorControlsClampToTheirFilterRange() {
        var tone = ToneCurve()
        tone.vibrance = 4
        tone.highlights = -9
        tone.shadows = .nan

        let clamped = tone.clamped()

        XCTAssertEqual(clamped.vibrance, 1)
        XCTAssertEqual(clamped.highlights, -1)
        XCTAssertEqual(clamped.shadows, 0)
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

    /// The identity fast path is a performance decision, not a correctness one, and it
    /// is only correct if it is actually reached: a recipe that reports identity while
    /// a stage is set would silently skip the whole pipeline.
    func testIdentityIsOnlyTrueWhenNothingWouldRun() {
        XCTAssertTrue(ProcessingSettings.none.isIdentity)
        XCTAssertTrue(ProcessingSettings(tone: .neutral).isIdentity)

        var tone = ToneCurve()
        tone.contrast = 0.2
        XCTAssertFalse(ProcessingSettings(tone: tone).isIdentity)

        XCTAssertFalse(ProcessingSettings(grain: 0.5).isIdentity)
        XCTAssertFalse(ProcessingSettings(sharpen: 0.5).isIdentity)
    }

    /// Every colour control must break identity, or its stage is skipped and the slider
    /// is a control over nothing — the defect class this suite exists to close.
    func testEveryColorControlBreaksIdentity() {
        var vibrance = ToneCurve()
        vibrance.vibrance = 0.5
        XCTAssertFalse(ProcessingSettings(tone: vibrance).isIdentity)

        var highlights = ToneCurve()
        highlights.highlights = -0.5
        XCTAssertFalse(ProcessingSettings(tone: highlights).isIdentity)

        var shadows = ToneCurve()
        shadows.shadows = 0.5
        XCTAssertFalse(ProcessingSettings(tone: shadows).isIdentity)
    }

    /// A tone of `.neutral` and a tone of `nil` mean the same thing to the renderer, and
    /// the summary is what a photo's metadata says, so both have to read as "nothing".
    func testIdentitySummarySaysNothingRatherThanSomething() {
        XCTAssertEqual(ProcessingSettings.none.summarise(), "identity")
        XCTAssertEqual(ProcessingSettings(tone: .neutral).summarise(), "identity")
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
    /// The slower ultra wide is why denoise is routed there, and the crop past the
    /// telephoto's optical limit is why super-resolution is. A single "AI
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

    /// A composite borrows the wide's stage.
    ///
    /// Apple documents a composite falling back to its wide constituent, so that is the
    /// constituent that actually took the shot. Without this the common 1x composite capture
    /// would match no stage and silently get nothing.
    func testACompositeRoutesLikeTheWide() {
        let plan = LearnedStagePlan.plan(for: metadata(lens: "AVCaptureDeviceTypeBuiltInTripleCamera"))
        XCTAssertEqual(plan.stages, [.lowLightToneMap])
        XCTAssertEqual(CaptureLens(kind: .composite).routingLens, .wide)
    }

    /// Routing through the wide must not make a composite *telephoto*, or an SR model would
    /// run on every composite shot and invent detail in ordinary 1x photos.
    func testRoutingACompositeDoesNotGiveItTheTelephotoStage() {
        let plan = LearnedStagePlan.plan(
            for: metadata(lens: "AVCaptureDeviceTypeBuiltInTripleCamera", zoom: 6))
        XCTAssertFalse(plan.stages.contains(.superResolution),
                       "a composite borrows the wide's stages only")
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
        settings.grain = 0.2
        settings.sharpen = 0.4

        var metadata = CaptureMetadata(mode: "auto")
        metadata.processing = settings
        let recipe = metadata.recipeString()

        let (version, fields) = CaptureMetadata.parse(recipe: recipe)
        XCTAssertEqual(version, CaptureMetadata.recipeVersion)
        let token = try XCTUnwrap(fields["proc"], "the recipe did not write a processing token")
        let decoded = try XCTUnwrap(CaptureMetadata.decodeProcessing(token),
                                    "the token did not decode")
        XCTAssertEqual(decoded, settings)
    }

    /// A recipe written before looks were removed still carries their keys, and it must
    /// decode to the original rather than to nothing. `Decodable` ignores unknown keys,
    /// so the old grade is dropped by the format, not by a migration — and "show the
    /// original" holds without any code needing to know looks ever existed.
    func testARecipeWrittenWithALookDecodesToTheOriginal() {
        let legacyJSON = """
            {"tone":null,"look":{"name":"Faded Film"},"lookIntensity":0.8,\
            "subjectMask":{"coverage":0.25,"confidence":0.7},"grain":0.2,"sharpen":0.4}
            """
        let token = Data(legacyJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let decoded = CaptureMetadata.decodeProcessing(token)

        var expected = ProcessingSettings()
        expected.grain = 0.2
        expected.sharpen = 0.4
        XCTAssertEqual(decoded, expected)
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
        var metadata = CaptureMetadata(mode: "auto")
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
