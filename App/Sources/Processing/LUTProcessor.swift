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
        guard lut.isUsable else {
            throw LUTApplicationError.notUsable(reason: "the table is missing samples")
        }
        guard lut.kind == .threeDimensional else {
            throw LUTApplicationError.oneDimensionalTableNotSupported(size: lut.size)
        }

        // The space the table was authored in, as recorded by the parser — not inferred
        // here. A table that is not in a colour space this pipeline can apply comes back
        // as `nil` and is refused by name, which is a different error from a table that
        // is in a *different* colour space from the image.
        guard let lutSpace = lut.authoredSpace else {
            AppLog.warn(AppLog.processing,
                        "LUT refused: domain \(lut.domainMin)...\(lut.domainMax) is not a colour space")
            throw LUTApplicationError.logEncodedTable(domain: Self.describeDomain(lut))
        }
        guard lutSpace == imageSpace else {
            AppLog.warn(AppLog.processing,
                        "LUT refused: table=\(lutSpace.name) image=\(imageSpace.name)")
            throw LUTApplicationError.domainMismatch(lut: lutSpace.name, image: imageSpace.name)
        }

        // Intensity 0 is a complete no-op, and taking it early avoids a pointless
        // texture upload and filter pass on every frame while a look is switched off.
        guard intensity > 0 else { return image }

        // `CIColorCubeWithColorSpace`, never `CIColorCube`.
        //
        // The difference is not cosmetic. `CIColorCube` is **invariant**: it applies the
        // table to the sample values it is given with no colour management at all, the
        // same as `CIPhotoEffect`. `CIContext`'s working space is linear sRGB, and a
        // colourist's `.cube` is gamma-encoded, so an invariant cube is fed a table
        // authored in one space and evaluated in the other. That is the washed-out /
        // over-saturated look, and it is not a subtle bias — it is the wrong transfer
        // function. `CIColorCubeWithColorSpace` takes the table's own space as
        // `inputColorSpace` and performs the conversion, which is the only correct
        // construction.
        //
        // A previous version of this file used `CIColorCube` and gave a reason: that
        // `CIColorCubeWithColorSpace` was "absent from the SDK CI builds against", with
        // `CIFilter(name:)` returning nil and the typed accessor not compiling. Both
        // halves of that were misdiagnoses, and both are worth recording because the
        // mistake is easy to repeat:
        //
        // - The typed accessor requires `import CoreImage.CIFilterBuiltins`. Without that
        //   import it does not resolve, which reads exactly like "the API does not exist".
        // - `CIFilter(name:)` for Metal-backed filters returns nil in a **headless** CI
        //   simulator. A nil there says nothing about the device, where the same lookup
        //   succeeds.
        //
        // `testColorManagedCubeFilterIsAvailable` now asserts the filter resolves, so this
        // cannot silently regress into the invariant path again.
        //
        // The lookup is by name rather than through `CIFilterBuiltins` deliberately: the
        // string form is a stable documented API, it needs no extra import to be spelled
        // correctly, and this file already builds every filter that way inside the
        // exception trap.
        guard let cubeData = Self.cubeData(for: lut) else {
            throw LUTApplicationError.notUsable(reason: "the sample buffer could not be built")
        }

        // `Data(lut.samples)` does not compile: `Data` initialises from bytes, and
        // `Float` is not `UInt8`. The filter wants the raw 32-bit float bit patterns, so
        // the sample buffer is copied verbatim rather than converted.
        //
        // Parameters are set one key at a time rather than handed over as a dictionary.
        // `CIFilter(name:parameters:)` returns **nil** — with no error and no log — when
        // any value has the wrong type, so a single wrong value is indistinguishable
        // from a filter that does not exist. `setValue(_:forKey:)` instead raises
        // NSInvalidArgumentException, which `LumaFrameSafety` converts to a string, and
        // recording the key before each call means the message names the parameter that
        // was refused. Four runs went into this filter being silently wrong; the point
        // of setting them individually is that the next one is self-diagnosing.
        var graded: CIImage?
        var currentKey = "creating the filter"
        let raised = LumaFrameSafety.perform {
            guard let cube = CIFilter(name: "CIColorCubeWithColorSpace") else { return }

            // Set before the image, so that a filter validating its arguments sees the
            // space first. It is the one key `CIColorCube` does not have, which is exactly
            // why passing it to that filter raised an uncatchable Objective-C exception.
            currentKey = "inputColorSpace"
            cube.setValue(lutSpace.cgColorSpace, forKey: "inputColorSpace")

            currentKey = kCIInputImageKey
            cube.setValue(image, forKey: kCIInputImageKey)

            currentKey = "inputCubeDimension"
            cube.setValue(Float(lut.size), forKey: "inputCubeDimension")

            currentKey = "inputCubeData"
            cube.setValue(cubeData, forKey: "inputCubeData")

            currentKey = "outputImage"
            graded = cube.outputImage
        }
        if let raised {
            AppLog.fail(AppLog.processing, "cube rejected \(currentKey): \(raised); LUT not applied")
            throw LUTApplicationError.notUsable(reason: "Core Image refused \(currentKey): \(raised)")
        }
        guard let graded else {
            let reason = currentKey == "creating the filter"
                ? "this OS has no CIColorCubeWithColorSpace filter"
                : "CIColorCubeWithColorSpace produced no output"
            AppLog.fail(AppLog.processing, "cube failed at \(currentKey); LUT not applied")
            throw LUTApplicationError.notUsable(reason: reason)
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

    /// Renders a table's domain for a log line and an error message.
    ///
    /// Only ever called on the refusal path, so it is not worth a formatter and is built
    /// with plain interpolation rather than pulling in `String(format:)`.
    private static func describeDomain(_ lut: CubeLUT) -> String {
        let min = lut.domainMin.map { Self.shortest($0) }.joined(separator: ",")
        let max = lut.domainMax.map { Self.shortest($0) }.joined(separator: ",")
        return "\(min)…\(max)"
    }

    private static func shortest(_ value: Float) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
