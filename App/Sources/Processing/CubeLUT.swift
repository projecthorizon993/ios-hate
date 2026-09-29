import Foundation

/// A parsed Adobe `.cube` lookup table.
///
/// Parsing is strict and total: a malformed file produces a `CubeLUTError` naming the
/// line, never a partially-populated table and never a crash. `IOS_CAMERA_APP_PLAN.md`
/// section 14 requires imported LUTs to be validated, and the app's own rule is that a
/// diagnostics or import path may not take down the camera.
struct CubeLUT: Equatable {

    /// Which kind of table this is.
    ///
    /// `.cube` files come in two shapes and they are not interchangeable: a 1D table is
    /// one lookup per channel per input, a 3D table is one lookup per RGB triplet. The
    /// distinction is kept because Step 2 only *applies* 3D tables, and reporting a 1D
    /// table as usable would be a lie the intensity slider would then act on.
    enum Kind: Equatable, Sendable {
        case oneDimensional
        case threeDimensional
    }

    /// `LUT_1D_SIZE` / `LUT_3D_SIZE` from the file. For a 3D table this is the edge
    /// length, so the sample count is `size³`.
    var size: Int

    var kind: Kind

    /// The `TITLE` directive, when present. Metadata, never used for a file name or a
    /// log line, so an untrusted title cannot reach either.
    var title: String?

    /// `DOMAIN_MIN` and `DOMAIN_MAX`. Absent in the file means the sRGB default of
    /// 0…1 for every channel, which is an assumption, so it is recorded as such.
    var domainMin: [Float]
    var domainMax: [Float]
    var domainWasDeclared: Bool

    /// Flat RGB samples in file order. For a 3D table the red channel varies fastest,
    /// which is the order Core Image's colour cube filters expect.
    var samples: [Float]

    /// The colour space the table was **authored** for, or `nil` when the table is not
    /// in a colour space this pipeline can apply.
    ///
    /// This is the value handed to `CIColorCubeWithColorSpace` as `inputColorSpace`, and
    /// it must be the space the colourist worked in — not the space the image happens to
    /// be in, and not a space inferred from the numbers.
    ///
    /// Adobe `.cube` has no colour-space directive; the only thing a file can state is
    /// its domain. A 0…1 domain means gamma-encoded sRGB by convention, and that is the
    /// only claim this type will make. **A non-unit domain is not "linear sRGB"** — it is
    /// a log encoding (Rec.709, LogC, S-Log) or a wider range, neither of which is a
    /// colour space, so it is recorded as `nil` and refused at apply time rather than
    /// relabelled as something it is not.
    ///
    /// That also means a P3-authored table is indistinguishable from an sRGB one, because
    /// the format cannot say. See `LUTProcessor` for what follows from that.
    ///
    /// Declared last so the memberwise initialiser keeps its existing shape.
    ///
    /// **No default value, deliberately.** It used to default to `.sRGB`, which is the
    /// false claim the doc comment above is written to prevent: a construction site that
    /// forgot the field got "authored in sRGB" for free, and that value is handed to
    /// `CIColorCubeWithColorSpace` as `inputColorSpace` — a wrong space here is a wrong
    /// render, not a cosmetic default. Every site now states it, including the tests, so a
    /// new one cannot inherit a claim it never made.
    var authoredSpace: ColorSpace?

    /// The colour space the table was authored for, inferred from its domain. A table
    /// whose domain is not 0…1 in every channel is almost always a log-encoded one.
    enum Domain: Equatable, Sendable {
        /// 0…1 in all three channels: the sRGB assumption, declared or defaulted.
        case unit
        /// Anything else. Log-encoded (Rec.709, LogC, S-Log) or wider.
        case nonUnit
    }

    var domain: Domain {
        let isUnit = domainMin.allSatisfy { $0 == 0 }
            && domainMax.allSatisfy { $0 == 1 }
        return isUnit ? .unit : .nonUnit
    }

    /// The number of floats one 3D sample occupies, which is always 3.
    static let channelsPerSample = 3

    var sampleCount: Int { samples.count / CubeLUT.channelsPerSample }

    /// Whether the sample count matches the declared size.
    ///
    /// Checked explicitly rather than trusted, because a truncated file with a
    /// plausible `LUT_3D_SIZE` would otherwise index out of range at apply time.
    var sampleCountMatchesSize: Bool {
        switch kind {
        case .oneDimensional: return sampleCount == size
        case .threeDimensional: return sampleCount == size * size * size
        }
    }

    /// Sampling the table is only meaningful once the count is known to be right.
    var isUsable: Bool { sampleCountMatchesSize && !samples.isEmpty }
}
