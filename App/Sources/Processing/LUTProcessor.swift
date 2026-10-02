import CoreImage
// Required for the typed accessors below — `CIFilterBuiltins`. Without it the accessor
// does not resolve, which reads exactly like "the API does not exist". That misreading
// is recorded in this file's history and cost CI runs.
import CoreImage.CIFilterBuiltins
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

    /// The filter the cube path uses, by name. Named once, in the file that uses it.
    ///
    /// It was a bare literal at the `CIFilter(name:)` call site, and the test asserting the
    /// filter is available declared its own copy of the same string. A test that asserts a
    /// string it also owns cannot fail when the string changes, so reverting to the
    /// invariant `CIColorCube` would have left CI green.
    ///
    /// The filter is now **constructed** through the typed accessor, so the name is not a
    /// construction key any more. It is still used for the availability check below, which
    /// keeps the constant load-bearing in production and keeps the test guarding something
    /// real — a constant that only the test reads is a constant nothing checks.
    static let colorManagedCubeFilterName = "CIColorCubeWithColorSpace"

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
        // Whether this OS has the filter at all, which is a different question from whether
        // it was configured correctly and is the one the name constant and its test cover.
        // Kept separate so "no such filter" and "filter produced nothing" stay
        // distinguishable in the log — they have completely different causes.
        guard CIFilter(name: Self.colorManagedCubeFilterName) != nil else {
            AppLog.fail(AppLog.processing,
                        "this OS has no \(Self.colorManagedCubeFilterName); LUT not applied")
            throw LUTApplicationError.notUsable(
                reason: "this OS has no \(Self.colorManagedCubeFilterName) filter")
        }

        // The typed accessor, not `CIFilter(name:)`.
        //
        // ## The bug this fixes: a required parameter was never set
        //
        // `CIColorCubeWithColorSpace` has **five** properties:
        //
        //     var colorSpace: CGColorSpace?
        //     var cubeData: Data
        //     var cubeDimension: Float
        //     var inputImage: CIImage?
        //     var extrapolate: Bool          <-- never set
        //
        // This code set four of them and left `extrapolate` at its default. `CIFilter(name:)`
        // populates **no** input values — Core Image does not apply a filter's documented
        // defaults to a programmatically created instance — so `extrapolate` was left unset,
        // the filter failed its own validation, and `outputImage` came back `nil`:
        //
        //     x cube failed at outputImage; LUT not applied
        //     x CIColorCubeWithColorSpace produced no output
        //
        // On a device that meant every look silently did nothing and the saved photo was the
        // untouched image. The intensity slider moved and changed nothing, because there was
        // no graded image to dissolve against.
        //
        // ## Why CI never saw it
        //
        // `coreImageCanRenderACube()` in `LUTProcessorTests` built this same filter the same
        // incomplete way, got the same `nil`, and concluded that *headless Core Image cannot
        // render this filter* — then used that conclusion to skip the only two tests that
        // would have caught it. The bug wrote its own blind spot, and the claim was then
        // cited in `docs/ARCHITECTURE.md` section 4 as if it were a platform fact.
        //
        // ## Why the accessor rather than one more key string
        //
        // The four keys that were being set are *not* the property names: the properties are
        // `colorSpace` / `cubeData` / `cubeDimension` but the keys are `inputColorSpace` /
        // `inputCubeData` / `inputCubeDimension`. So the key for `extrapolate` cannot be
        // guessed from the others — `extrapolate` and `inputExtrapolate` are both plausible
        // and only one exists. Guessing is exactly the mistake this file already records
        // twice, and it cost four CI runs. The typed accessor has no key strings at all and
        // the compiler rejects a wrong type or a misspelled property, so the next version of
        // this bug is a compile error instead of a silent nil.
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.colorSpace = lutSpace.cgColorSpace
        cube.inputImage = image
        cube.cubeDimension = Float(lut.size)
        cube.cubeData = cubeData

        // `extrapolate == false` clamps RGB components that fall outside 0…1 to the edge
        // of the table, which is what this pipeline wants and what `GeneratedLooks.clamp01`
        // already assumes by never emitting an out-of-range sample. `true` would linearly
        // extrapolate past the table's corners and invent colours no entry describes.
        cube.extrapolate = false

        guard let graded = cube.outputImage else {
            AppLog.fail(AppLog.processing,
                        "cube produced no output; all inputs set "
                        + "(space=\(lutSpace.name) dimension=\(lut.size) "
                        + "bytes=\(cubeData.count)); LUT not applied")
            throw LUTApplicationError.notUsable(reason: "CIColorCubeWithColorSpace produced no output")
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

    /// Renders a domain value for a log line and an error message.
    ///
    /// `Int(_: Float)` **traps** on a value that overflows `Int` or is not finite, and
    /// `CubeLUTParser` range-checks sample data but not `DOMAIN_MIN` / `DOMAIN_MAX` — a
    /// `.cube` declaring `DOMAIN_MAX 1e40 1e40 1e40` parses cleanly and would then reach
    /// here, on the refusal path, and kill the app. An import must never be able to take
    /// the camera down, so nothing is converted unless the conversion is known to be safe
    /// and the fallback is the original value.
    private static func shortest(_ value: Float) -> String {
        guard value.isFinite else { return String(value) }
        guard value.magnitude <= 9_007_199_254_740_992 else { return String(value) }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }
}
