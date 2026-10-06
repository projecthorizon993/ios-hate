import CoreImage
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
/// 2. sharpen then grain, in gamma space. Grain in linear light is invisible in the
///    shadows, which is the whole reason it is specified there;
/// 3. convert to the output space.
///
/// Two rules from the architecture are enforced here rather than trusted:
///
/// - A correction only runs when the user asked for it. The native pipeline has already
///   applied white balance and tone mapping, so applying ours unconditionally is what
///   makes a photo look washed out.
/// - Highlight recovery is not in this list. If the native pipeline is already doing HDR
///   fusion, doing it again is the other half of the same problem.
struct ProcessingPipeline {

    /// Renders one frame.
    ///
    /// - Throws: only for reasons the caller should surface. Callers that cannot fail
    ///   should use `renderOrOriginal`, which degrades to the untouched frame.
    func render(_ image: CIImage,
                settings: ProcessingSettings,
                inputSpace: ColorSpace,
                outputSpace: ColorSpace) throws -> CIImage {
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
            result = try convert(result, from: space, to: .linearSRGB, stage: "to working space")
            space = .linearSRGB
            result = try applyTone(tone, to: result)
        }

        // 2. Sharpen then grain, in gamma space. Grain in linear light is invisible in the
        // shadows, which is the whole reason it is specified there.
        if recipe.sharpen > 0 || recipe.grain > 0 {
            if space != .sRGB {
                result = try convert(result, from: space, to: .sRGB, stage: "to gamma for grain")
                space = .sRGB
            }
            if recipe.sharpen > 0 { result = try applySharpen(recipe.sharpen, to: result) }
            if recipe.grain > 0 { result = try applyGrain(recipe.grain, to: result) }
        }

        // 3. Output transform.
        if space != outputSpace {
            result = try convert(result, from: space, to: outputSpace, stage: "output transform")
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
                          outputSpace: ColorSpace) -> CIImage {
        do {
            return try render(image,
                              settings: settings,
                              inputSpace: inputSpace,
                              outputSpace: outputSpace)
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
            result = try stage("exposure", result, [
                kCIInputImageKey: result,
                kCIInputEVKey: tone.exposureEV
            ])
        }

        if tone.temperatureOffset != 0 || tone.tintOffset != 0 {
            result = try stage("white balance", result, [
                kCIInputImageKey: result,
                "inputNeutral": tone.neutralVector,
                "inputTargetNeutral": tone.targetNeutralVector
            ])
        }

        // `CIColorControls` carries brightness, contrast and saturation, and they are
        // independent of each other in the filter, so one pass rather than three.
        if tone.lift != 0 || tone.contrast != 0 || tone.saturation != 0 {
            result = try stage("tone controls", result, [
                kCIInputImageKey: result,
                kCIInputBrightnessKey: tone.brightness,
                kCIInputContrastKey: tone.colorControlsContrast,
                kCIInputSaturationKey: tone.colorControlsSaturation
            ])
        }
        return result
    }

    private func applySharpen(_ amount: Float, to image: CIImage) throws -> CIImage {
        try stage("sharpen", image, [
            kCIInputImageKey: image,
            kCIInputSharpnessKey: amount
        ])
    }

    /// `CIRandomGenerator` is monochrome by design, so it needs no desaturation — only
    /// scaling, which is what makes the amount control mean anything.
    ///
    /// Built by name and cropped to the frame rather than filtered, because it takes no
    /// input image and produces an infinite extent.
    private func applyGrain(_ amount: Float, to image: CIImage) throws -> CIImage {
        var random: CIImage?
        let failure = LumaFrameSafety.perform {
            random = CIFilter(name: "CIRandomGenerator")?.outputImage?
                .cropped(to: image.extent)
        }
        if let failure {
            AppLog.warn(AppLog.processing, "grain unavailable (raised: \(failure)); skipping")
            return image
        }
        guard let noise = random else {
            AppLog.warn(AppLog.processing, "CIRandomGenerator unavailable; skipping grain")
            return image
        }

        // Zeroing the colour vectors and putting the amount in the alpha column scales
        // monochrome noise by it. The alpha position is the fourth component, which is
        // the only part of a `CIColorMatrix` vector that is not an RGB coefficient.
        let amountVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount))
        let scaled = noise.applyingFilter("CIColorMatrix", parameters: [
            kCIInputImageKey: noise,
            "inputRVector": amountVector,
            "inputGVector": amountVector,
            "inputBVector": amountVector
        ])
        return try stage("grain", image, [
            kCIInputImageKey: image,
            kCIInputBackgroundImageKey: scaled
        ])
    }

    /// Colour space conversion, named explicitly at the call site.
    ///
    /// The keys are string literals because there is no Swift constant for them. This is
    /// the *same trap* the LUT code fell into once already: `inputColorSpace` is a key on
    /// `CIColorSpace` and is **not** a key on `CIColorCube`, and having been bitten by
    /// that, they are written out rather than reached for by habit. The whole call is
    /// inside `stage`, so a wrong key is a logged refusal rather than a crash.
    private func convert(_ image: CIImage,
                         from: ColorSpace,
                         to: ColorSpace,
                         stage stageName: String) throws -> CIImage {
        guard from != to else { return image }
        return try stage(stageName, image, [
            kCIInputImageKey: image,
            "inputColorSpace": from.cgColorSpace,
            "outputColorSpace": to.cgColorSpace
        ])
    }

    // MARK: - Filter construction

    /// Builds one filter by name, inside the exception trap.
    ///
    /// Core Image raises `NSInvalidArgumentException` for an unknown filter or key, which
    /// Swift cannot catch. A camera app that dies because a filter name was wrong is a
    /// worse outcome than a frame that did not get processed, so every stage goes through
    /// here and a raise becomes a `ProcessingError` the caller can log and skip past.
    ///
    /// `applyingFilter` on `CIImage` is avoided for this reason: it traps rather than
    /// raising, and a trap is not catchable.
    private func stage(_ name: String, _ image: CIImage, _ parameters: [String: Any]) throws -> CIImage {
        var output: CIImage?
        let failure = LumaFrameSafety.perform {
            output = CIFilter(name: name, parameters: parameters)?.outputImage
        }
        if let failure {
            AppLog.fail(AppLog.processing, "stage \(name) raised: \(failure)")
            throw ProcessingError.stageFailed(failure, stage: name)
        }
        guard let output else {
            AppLog.fail(AppLog.processing, "stage \(name) produced no output")
            throw ProcessingError.stageFailed("Core Image produced no output", stage: name)
        }
        return output
    }
}
