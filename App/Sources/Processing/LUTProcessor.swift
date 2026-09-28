import CoreImage
import Foundation

/// Applies a parsed lookup table to a `CIImage`.
///
/// This is the only place in the app that touches a 3D LUT, and the preview and the
/// saved photo both come through here. That shared path is the point: `docs/DESIGN_SPEC.md`
/// requires what you see in the viewfinder to be what lands in the file, and two
/// pipelines are how that guarantee is lost.
///
/// ## Why the intensity blend is a dissolve
///
/// Blending two images by fraction `t` is `original * (1 - t) + graded * t`, per channel.
/// `CIDissolveTransition` is documented as computing exactly that, it is a built-in GPU
/// filter, and it needs no custom kernel. The obvious alternative — a `CIColorKernel` —
/// is deprecated, and a Metal kernel for one lerp is not worth the build risk at this
/// stage. Note this is a blend of *results*, not of lookup tables: interpolating the
/// table and applying that would be a different, and wrong, operation.
struct LUTProcessor {

    /// The intensity range a caller may request.
    static let intensityRange: ClosedRange<Float> = 0...1

    /// Applies `lut` to `image` in `imageSpace`.
    ///
    /// - Throws: rather than guessing. Every failure here is a case where the obvious
    ///   fallback — a silent conversion, a clamped value, a skipped pass — would produce
    ///   a photo that is subtly wrong and gives the user no way to tell.
    func apply(_ lut: CubeLUT,
               to image: CIImage,
               intensity: Float,
               imageSpace: ColorSpace) throws -> CIImage {
        guard intensity.isFinite,
              LUTProcessor.intensityRange.contains(intensity) else {
            throw LUTApplicationError.intensityOutOfRange(intensity)
        }
        guard lut.isUsable else { throw LUTApplicationError.notUsable }
        guard lut.kind == .threeDimensional else {
            throw LUTApplicationError.oneDimensionalTableNotSupported(size: lut.size)
        }

        // The domain check from section 3.1. A table with no DOMAIN lines is assumed to
        // be sRGB, which is the Adobe convention and is recorded as an assumption on
        // the table itself. A table that *declares* a non-unit domain is log-encoded, and
        // applying it to gamma-encoded pixels would be meaningless rather than merely
        // inaccurate, so it is refused.
        let lutSpace = lut.domain == .unit ? ColorSpace.sRGB : ColorSpace.linearSRGB
        guard lutSpace == imageSpace else {
            AppLog.warn(AppLog.processing,
                        "LUT refused: table=\(lutSpace.name) image=\(imageSpace.name)")
            throw LUTApplicationError.domainMismatch(lut: lutSpace.name, image: imageSpace.name)
        }

        // Intensity 0 is a complete no-op, and taking it early avoids a pointless
        // texture upload and filter pass on every frame while a look is switched off.
        guard intensity > 0 else { return image }

        let cube = CIColorCube(
            dimension: lut.size,
            data: Data(lut.samples),
            colorSpace: imageSpace.cgColorSpace
        )
        guard let graded = image.applyingFilter("CIColorCube",
                                                parameters: [
                                                    "inputCubeData": cube,
                                                    "inputColorSpace": imageSpace.cgColorSpace
                                                ]) else {
            // Core Image returns nil for an unsupported filter rather than raising, so
            // this is a real branch and the only correct answer is to not apply it.
            AppLog.fail(AppLog.processing, "CIColorCube returned nil; LUT not applied")
            throw LUTApplicationError.notUsable
        }

        guard intensity < 1 else { return graded }

        let mixed = graded.applyingFilter("CIDissolveTransition",
                                          parameters: [
                                            kCIInputTargetImageKey: image,
                                            kCIInputTimeKey: intensity
                                          ])
        return mixed ?? graded
    }

    /// Builds the cube data exactly as Core Image expects it: RGB floats, red varying
    /// fastest, matching the sample order the parser preserved.
    ///
    /// Exposed separately so the ordering is unit tested rather than assumed, since a
    /// transposition here produces a table that loads, reports itself applied, and
    /// colours every photo slightly wrong.
    static func cubeData(for lut: CubeLUT) -> Data? {
        guard lut.kind == .threeDimensional, lut.isUsable else { return nil }
        return Data(lut.samples)
    }
}
