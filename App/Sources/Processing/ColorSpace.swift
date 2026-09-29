import CoreGraphics
import Foundation

/// The colour space a processing stage runs in, named explicitly on every call.
///
/// `docs/ARCHITECTURE.md` section 3.1 is the contract: `ColorSpace` is a parameter on
/// every processor, a mismatch between a LUT and an image is a **hard error with a log
/// line**, and a silent conversion never happens. This type exists so that rule is
/// enforced by the type system rather than by remembering it at each call site.
enum ColorSpace: Equatable, Sendable {

    /// Gamma-encoded sRGB. Where `.cube` files without a `DOMAIN` declaration are assumed
    /// to live, per the Adobe convention.
    case sRGB

    /// Gamma-encoded Display P3, for a capture that recorded wide colour.
    case displayP3

    /// Linear-light sRGB. The working space for tone curves, because a curve applied in
    /// gamma space produces muddy shadows.
    case linearSRGB

    /// The primaries the capture arrived in, and the only place a colour-space
    /// conversion is legitimate: at the very end, for display or for export.
    func converted(to destination: ColorSpace) -> ColorSpace {
        destination
    }

    /// The concrete Core Graphics colour space for this case.
    ///
    /// `linearSRGB` used to return the gamma-encoded sRGB space, which is the same object
    /// as `.sRGB` — so any pipeline stage that asked the enum to convert for it got a
    /// gamma space back and silently did no conversion at all. Tone curves are supposed
    /// to run in linear light, so that made the whole working space a no-op. `linearSRGB`
    /// is a distinct color space and is now returned as one.
    var cgColorSpace: CGColorSpace {
        switch self {
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        case .linearSRGB: return CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
    }

    var name: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .linearSRGB: return "linear sRGB"
        }
    }
}

/// Why a LUT could not be applied.
///
/// Separate from the parse errors: the file is perfectly valid, it just was authored for
/// a different colour space than the image it is being applied to, and that is a
/// decision the user has to make rather than something to guess at.
enum LUTApplicationError: LocalizedError, Equatable {

    /// A 1D table cannot be applied by the 3D pipeline Step 2 ships. Reported rather
    /// than silently converted: a 1D table is a different operation, not a smaller 3D
    /// one, and pretending otherwise would produce a subtly wrong look.
    case oneDimensionalTableNotSupported(size: Int)

    /// The table's declared domain is not the image's colour space.
    case domainMismatch(lut: String, image: String)

    /// The table's domain is log-encoded, or wider than 0…1, so it is not in a colour
    /// space this pipeline can apply.
    ///
    /// Distinct from `domainMismatch` on purpose. A log table is not "in the wrong colour
    /// space", it is in no colour space this code can name, and telling the user it is
    /// "linear sRGB" — which is what a non-unit domain used to be reported as — invites
    /// them to believe a conversion is possible. It is not, and saying so is the whole
    /// point of reporting it.
    case logEncodedTable(domain: String)

    /// Core Image would not build the filter. Carries the reason because three separate
    /// CI runs were spent on a bare `notUsable` that said nothing about which of the
    /// filter's parameters it disliked.
    case notUsable(reason: String)

    case intensityOutOfRange(Float)

    var errorDescription: String? {
        switch self {
        case .oneDimensionalTableNotSupported(let size):
            return "This is a 1D lookup table of \(size) entries. The 3D pipeline cannot apply it."
        case .domainMismatch(let lut, let image):
            return "This lookup table is in \(lut) and the image is in \(image). "
                + "Converting between them would change the colours, so it is not done automatically."
        case .logEncodedTable(let domain):
            return "This lookup table has the domain \(domain), which is a log or wide encoding "
                + "rather than a colour space. It would need its camera profile applied first, "
                + "so it is not applied."
        case .notUsable(let reason):
            return "This lookup table cannot be applied: \(reason)."
        case .intensityOutOfRange(let value):
            return "Intensity \(value) is outside 0…1."
        }
    }
}
