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

        // `CIColorCube` has **no** `inputColorSpace` key — it operates in the
        // context's working colour space. Passing that key raises
        // NSUnknownKeyException at `setValue:forUndefinedKey:`, which is an
        // Objective-C exception, which Swift cannot catch, which means the app dies.
        // The colour-space-aware variant is a separate filter name, so that is what is
        // used, and the whole construction is inside the exception trap below.
        guard let cubeData = Self.cubeData(for: lut) else { throw LUTApplicationError.notUsable }

        // `Data(lut.samples)` does not compile: `Data` initialises from bytes, and
        // `Float` is not `UInt8`. The filter wants the raw 32-bit float bit patterns, so
        // the sample buffer is copied verbatim rather than converted.
        var parameters: [String: Any] = [
            kCIInputImageKey: image,
            "inputCubeDimension": CGFloat(lut.size),
            "inputCubeData": cubeData
        ]
        parameters["inputColorSpace"] = imageSpace.cgColorSpace

        // Captured through a mutable local because the trap takes a void block.
        var captured: CIImage?
        let raised = LumaFrameSafety.perform {
            captured = CIFilter(name: "CIColorCubeWithColorSpace", parameters: parameters)?.outputImage
        }
        if let raised {
            AppLog.fail(AppLog.processing, "cube construction raised \(raised); LUT not applied")
            throw LUTApplicationError.notUsable
        }
        guard let graded = captured else {
            // A nil filter means the name is unknown to this OS version, which is a
            // different failure from an exception and gets its own line so the two are
            // not confused later.
            AppLog.fail(AppLog.processing, "CIColorCubeWithColorSpace unavailable; LUT not applied")
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
        return lut.samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
