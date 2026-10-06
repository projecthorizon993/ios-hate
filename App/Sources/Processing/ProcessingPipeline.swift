import CoreImage
// Typed filter accessors. `CIFilter(name:)` takes the registered name, and the names
// this file used to pass ("exposure", "tone controls", "sharpen", …) are display
// names that resolve to nil — so every stage silently produced nothing and the
// pipeline fell back to the original on every frame. The accessor makes a wrong
// filter a compile error instead of a silent no-op, which is the same lesson
// `LUTProcessor` already taught once.
import CoreImage.CIFilterBuiltins
import Foundation

/// Why a frame could not be processed.
///
/// A camera app cannot afford an unprocessable frame: the user is looking at the preview
/// or holding a photo they just took. So every one of these has a defined fallback — the
/// **unprocessed** frame — and the error exists to be logged and shown, not to propagate
/// into the capture path as a failure.
enum ProcessingError: LocalizedError, Equatable {
    case stageFailed(String, stage: String)

    var errorDescription: String? {
        switch self {
        case .stageFailed(let reason, let stage):
            return "The \(stage) step failed: \(reason)"
        }
    }
}

/// The one image pipeline, used by the preview and the saved photo alike.
///
/// **This is the whole reason the type exists.** Two processing paths is how a grade ends
/// up looking right on screen and wrong in the file, which is the single most common
/// defect in a camera app and one that is invisible in CI because both paths can be
/// individually correct. The preview and `PhotoStore` both call `render` with the same
/// `ProcessingSettings`; there is nowhere else for the difference to creep in.
///
/// Order is `docs/ARCHITECTURE.md` section 3, and the order is the whole design:
///
/// 1. tone curve, in **linear** light — a curve applied in gamma space makes muddy
///    shadows, which is the most common way a grade looks wrong without being obviously
///    broken;
/// 2. the imported table, in its declared space — converted into, evaluated
///    colour-managed, at the recipe's intensity;
/// 3. sharpen then grain, in gamma space. Grain in linear light is invisible in the
///    shadows, which is the whole reason it is specified there;
/// 4. convert to the output space.
///
/// Two rules from the architecture are enforced here rather than trusted:
///
/// - A correction only runs when the user asked for it. The native pipeline has already
///   applied white balance and tone mapping, so applying ours unconditionally is what
///   makes a photo look washed out.
/// - Highlight recovery is not in this list. If the native pipeline is already doing HDR
///   fusion, doing it again is the other half of the same problem.
/// Mask input for per-region grading: the mask pixels plus the statistics the
/// recipe already carries.
///
/// Kept together so the image and the numbers cannot disagree — a mask for one
/// frame blended by another frame's statistics is exactly the seam this type
/// closes. Neither half is `Sendable` on its own terms (`CIImage` is not), and
/// the pipeline runs on the caller's thread, so this travels as a parameter,
/// never across queues.
struct SubjectBlendInput {

    var mask: CIImage
    var stats: SubjectStat
}

struct ProcessingPipeline {

    /// Renders one frame.
    ///
    /// - Parameter subject: the mask for *this* frame. The recipe carries the
    ///   statistics (which is what makes preview and file agree); the pixels
    ///   cannot ride in a `Codable` recipe and arrive here instead.
    /// - Throws: only for reasons the caller should surface. Callers that cannot fail
    ///   should use `renderOrOriginal`, which degrades to the untouched frame.
    func render(_ image: CIImage,
                settings: ProcessingSettings,
                inputSpace: ColorSpace,
                outputSpace: ColorSpace,
                subject: SubjectBlendInput? = nil) throws -> CIImage {
        let recipe = settings.clamped()
        // The fast path, and a real one: on a slow device an identity recipe is the
        // difference between a live preview and a warm one.
        guard !recipe.isIdentity else { return image }

        // The current space is tracked as a variable rather than recomputed at the end.
        // Reconstructing it afterwards meant a chain of conditions that had to agree with
        // the sequence above, and any disagreement showed up as a wrong-space render that
        // still looked like an image.
        var result = image
        var space = inputSpace

        // 1. Tone, in linear light.
        if let tone = recipe.tone, !tone.isIdentity {
            result = try convert(result, from: space, to: .linearSRGB)
            space = .linearSRGB
            result = try applyTone(tone, to: result)
        }

        // 2. The imported table, in its declared space. The image is converted
        // into the table's space first — matching names is not being in the
        // space, and the invariant filter that skipped the conversion is gone.
        // Intensity interpolates the table toward identity (engine semantics,
        // `docs/ENGINE_PLAN.md` §4), so one filter pass, not a dissolve of two.
        // A usable subject mask blends full strength on the subject against a
        // reduced background pass; without one the grade applies globally.
        if let lut = recipe.lut, lut.intensity > 0 {
            result = try applyTable(lut, to: result, space: &space, subject: subject)
        }

        // 3. Sharpen then grain, in gamma space. Grain in linear light is invisible in the
        // shadows, which is the whole reason it is specified there.
        if recipe.sharpen > 0 || recipe.grain > 0 {
            if space != .sRGB {
                result = try convert(result, from: space, to: .sRGB)
                space = .sRGB
            }
            if recipe.sharpen > 0 { result = try applySharpen(recipe.sharpen, to: result) }
            if recipe.grain > 0 { result = try applyGrain(recipe.grain, to: result) }
        }

        // 4. Output transform.
        if space != outputSpace {
            result = try convert(result, from: space, to: outputSpace)
        }
        return result
    }

    /// Renders, or returns the frame untouched.
    ///
    /// This is what the preview uses. A frame that cannot be processed is worth showing
    /// unprocessed; it is not worth losing the preview over.
    func renderOrOriginal(_ image: CIImage,
                          settings: ProcessingSettings,
                          inputSpace: ColorSpace,
                          outputSpace: ColorSpace,
                          subject: SubjectBlendInput? = nil) -> CIImage {
        do {
            return try render(image,
                              settings: settings,
                              inputSpace: inputSpace,
                              outputSpace: outputSpace,
                              subject: subject)
        } catch {
            AppLog.fail(AppLog.processing, "render failed, showing the unprocessed frame: \(error)")
            return image
        }
    }

    /// Encodes an image to JPEG data in a named space.
    ///
    /// The space is passed to the encoder rather than assumed, because a JPEG written
    /// without one is tagged sRGB and a P3 photo silently comes out looking washed out —
    /// which is the exact defect this whole pipeline exists to avoid.
    ///
    /// There is no `jpegData` on `CIImage`; encoding goes through a `CIContext`.
    ///
    /// `quality` is accepted and **not** applied. `jpegRepresentation` takes
    /// `CIImageRepresentationOption`, and the lossy-quality case was guessed at twice and
    /// does not exist under either name; rather than guess a third time the option is
    /// omitted and Core Image's default is used. A real quality control belongs with the
    /// `AVAssetWriter` path the still export already uses, where the bit rate is set
    /// explicitly. Until then this parameter is a promise the code does not keep, which is
    /// why it is called out here.
    static func encodeJPEG(_ image: CIImage, space: ColorSpace, quality: Float) -> Data? {
        // The working colour space is stated rather than left to the default. Core
        // Image's default already is linear sRGB, so this is behaviourally a no-op today —
        // which is exactly why it is written down. A context whose working space is
        // implicit is a context whose working space is Core Image's business, and the
        // tone stage runs in linear light and relies on exactly that.
        let context = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: ColorSpace.linearSRGB.cgColorSpace
        ])
        return context.jpegRepresentation(of: image, colorSpace: space.cgColorSpace, options: [:])
    }

    // MARK: - Stages

    private func applyTone(_ tone: ToneCurve, to image: CIImage) throws -> CIImage {
        var result = image

        // Exposure first, so the contrast and saturation that follow act on the
        // exposed image rather than on the original level.
        if tone.exposure > 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = result
            filter.ev = tone.exposureEV
            result = try output(of: filter, stage: "exposure")
        }

        if tone.temperatureOffset != 0 || tone.tintOffset != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = result
            filter.neutral = tone.neutralVector
            filter.targetNeutral = tone.targetNeutralVector
            result = try output(of: filter, stage: "white balance")
        }

        // `CIColorControls` carries brightness, contrast and saturation, and they are
        // independent of each other in the filter, so one pass rather than three.
        if tone.lift != 0 || tone.contrast != 0 || tone.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = result
            filter.brightness = tone.brightness
            filter.contrast = tone.colorControlsContrast
            filter.saturation = tone.colorControlsSaturation
            result = try output(of: filter, stage: "tone controls")
        }

        // Highlight and shadow recovery in the same linear stage: both remap tonal
        // ranges rather than scaling channels, so they belong with tone, not colour.
        if tone.highlights != 0 || tone.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = result
            filter.highlightAmount = tone.highlights
            filter.shadowAmount = tone.shadows
            result = try output(of: filter, stage: "highlight shadow")
        }

        // Vibrance after saturation, so the skin-tone protection acts on the
        // already-saturated image rather than being saturated over.
        if tone.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = result
            filter.amount = tone.vibrance
            result = try output(of: filter, stage: "vibrance")
        }
        return result
    }

    private func applySharpen(_ amount: Float, to image: CIImage) throws -> CIImage {
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image
        filter.sharpness = amount
        return try output(of: filter, stage: "sharpen")
    }

    /// Evaluates an imported table through the colour-managed filter.
    ///
    /// The table arrives with its declared space (`LutTable.space`, stated at import,
    /// never inferred), which becomes the filter's working space — the conversion the
    /// old invariant path skipped. A missing file or a bad upload fails the frame to
    /// the original via `renderOrOriginal`, never to a half-graded image.
    private func applyTable(_ reference: LutReference,
                            to image: CIImage,
                            space: inout ColorSpace,
                            subject: SubjectBlendInput? = nil) throws -> CIImage {
        guard let table = LutStore.resolve(reference) else {
            throw LUTApplicationError.notUsable(
                reason: "table file \(reference.filename) is missing")
        }
        var current = image
        if space != table.space {
            current = try convert(current, from: space, to: table.space)
            space = table.space
        }
        let full = try evaluate(table, intensity: reference.intensity, image: current)
        guard let subject, subject.stats.isUsable else { return full }
        AppLog.note(AppLog.ml, "subject blend: \(subject.stats.decision())")
        return try blendBySubject(full: full,
                                  softIntensity: reference.intensity * Self.backgroundTableFraction,
                                  table: table,
                                  image: current,
                                  mask: subject.mask)
    }

    /// One table evaluation at one intensity, in the table's own space.
    private func evaluate(_ table: LutTable,
                          intensity: Float,
                          image: CIImage) throws -> CIImage {
        guard let data = table.rgbaData(intensity: intensity) else {
            throw LUTApplicationError.notUsable(reason: "table samples failed the upload shape")
        }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.colorSpace = table.space.cgColorSpace
        filter.inputImage = image
        filter.cubeDimension = Float(table.size)
        filter.cubeData = data
        // Clamp out-of-range samples to the table edge: the tables the engine writes
        // never leave 0…1, so anything outside is a conversion artefact, not a colour.
        filter.extrapolate = false
        return try output(of: filter, stage: "color table")
    }

    /// How much of the table the **background** gets when a subject mask is in play.
    ///
    /// Not zero: a grade that only touches the subject reads as a cut-out, because
    /// real light does not leave the background untouched. Not one: then the mask
    /// does no work at all.
    nonisolated static let backgroundTableFraction: Float = 0.35

    /// Full table on the subject, a reduced table everywhere else, feathered between.
    ///
    /// The background is evaluated separately rather than derived by inverting the
    /// subject result, because a second pass at lower intensity is a genuinely
    /// different amount of the grade, not a subtraction.
    private func blendBySubject(full: CIImage,
                                softIntensity: Float,
                                table: LutTable,
                                image: CIImage,
                                mask: CIImage) throws -> CIImage {
        let base: CIImage
        if softIntensity > 0.01 {
            base = try evaluate(table, intensity: softIntensity, image: image)
        } else {
            // A background fraction of zero means the grade is wanted on the
            // subject only.
            base = image
        }
        // Feather the mask edge in fractions of the frame's shorter side: wide
        // enough to hide the boundary, narrow enough that the transition still
        // reads as belonging to the subject.
        let shortSide = min(image.extent.width, image.extent.height)
        let feathered: CIImage
        if shortSide > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = mask
            blur.radius = Float(shortSide * 0.04)
            feathered = try output(of: blur, stage: "mask feather")
        } else {
            feathered = mask
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = full
        blend.backgroundImage = base
        blend.maskImage = feathered
        return try output(of: blend, stage: "subject blend")
    }

    /// `CIRandomGenerator` is monochrome by design, so it needs no desaturation — only
    /// scaling, which is what makes the amount control mean anything.
    ///
    /// The generator takes no input image and produces an infinite extent, so it is
    /// cropped to the frame rather than filtered.
    private func applyGrain(_ amount: Float, to image: CIImage) throws -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage?.cropped(to: image.extent) else {
            AppLog.warn(AppLog.processing, "CIRandomGenerator unavailable; skipping grain")
            return image
        }

        // Zeroing the colour vectors and putting the amount in the alpha column scales
        // monochrome noise by it. The alpha position is the fourth component, which is
        // the only part of a `CIColorMatrix` vector that is not an RGB coefficient.
        let amountVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount))
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = noise
        matrix.rVector = amountVector
        matrix.gVector = amountVector
        matrix.bVector = amountVector
        let scaled = try output(of: matrix, stage: "grain scale")

        let add = CIFilter.additionCompositing()
        add.inputImage = image
        add.backgroundImage = scaled
        return try output(of: add, stage: "grain")
    }

    /// Colour space conversion through the working space.
    ///
    /// `matchedToWorkingSpace(from:)` converts into the working space the contexts are
    /// created with (linear sRGB, stated at every construction site); matching back out
    /// lands in the target. Two hops when neither end is the working space, which keeps
    /// one conversion rule instead of a matrix of them. Both matches are failable, so
    /// either failing fails the frame to the original rather than to a wrong-space
    /// render that still looks like an image.
    private func convert(_ image: CIImage,
                         from: ColorSpace,
                         to: ColorSpace) throws -> CIImage {
        guard from != to else { return image }
        guard let working = image.matchedToWorkingSpace(from: from.cgColorSpace) else {
            throw ProcessingError.stageFailed("match to working space produced no image",
                                              stage: "colour match")
        }
        guard to != .linearSRGB else { return working }
        guard let out = working.matchedFromWorkingSpace(to: to.cgColorSpace) else {
            throw ProcessingError.stageFailed("match from working space produced no image",
                                              stage: "colour match")
        }
        return out
    }

    // MARK: - Filter output

    /// Reads a typed filter's output, or fails the frame.
    ///
    /// With typed accessors a wrong filter name is a compile error, so the only failure
    /// left is a nil output — which still degrades to the untouched frame via
    /// `renderOrOriginal`, never to a crash. A stage that must never fail a frame
    /// (grain) handles its own fallback above instead of coming through here.
    private func output(of filter: CIFilter, stage name: String) throws -> CIImage {
        guard let output = filter.outputImage else {
            AppLog.fail(AppLog.processing, "stage \(name) produced no output")
            throw ProcessingError.stageFailed("Core Image produced no output", stage: name)
        }
        return output
    }
}
