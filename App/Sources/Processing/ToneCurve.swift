import CoreGraphics
import CoreImage
import Foundation

/// The manual corrections, as a value the user can dial in.
///
/// This is a **recipe**, not a filter graph. It is `Equatable` and `Codable` so it can
/// ride along in the capture metadata and re-render the photo later from the untouched
/// original, which is why `PhotoStore` writes raw bytes and this travels beside them
/// rather than being baked into the file.
///
/// All of it is identity by default, because a native pipeline already applies white
/// balance and tone mapping (`docs/ARCHITECTURE.md` section 3). A correction only runs
/// when the user asked for it, which is the rule that stops a photo looking washed out
/// through being corrected twice.
struct ToneCurve: Equatable, Codable, Sendable {

    /// Neutral in linear light. `CIVector` is not `Codable`, so this is stored as the two
    /// components and rebuilt on demand.
    var temperatureOffset: Float = 0
    var tintOffset: Float = 0

    /// -1…1. Negative lifts blacks, positive pushes them down.
    var lift: Float = 0
    /// -1…1 around mid grey.
    var contrast: Float = 0
    /// -1…1.
    var saturation: Float = 0
    /// 0…1 multiplier.
    var exposure: Float = 0

    static let neutral = ToneCurve()

    /// `true` when nothing has been dialled in, in which case the stage is skipped
    /// entirely rather than run as a no-op pass.
    var isIdentity: Bool { self == .neutral }

    /// Clamped copy. Every control feeds raw user input into Core Image, and a value
    /// outside the documented range produces a black frame or an exception rather than a
    /// clamped one, so this is applied at the boundary and not at each stage.
    func clamped() -> ToneCurve {
        func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float {
            guard value.isFinite else { return 0 }
            return min(max(value, low), high)
        }
        var copy = self
        copy.temperatureOffset = clamp(temperatureOffset, -2500, 2500)
        copy.tintOffset = clamp(tintOffset, -150, 150)
        copy.lift = clamp(lift, -1, 1)
        copy.contrast = clamp(contrast, -1, 1)
        copy.saturation = clamp(saturation, -1, 1)
        copy.exposure = clamp(exposure, 0, 1)
        return copy
    }

    /// The neutral point as Core Image wants it.
    ///
    /// `CIVector(x: 6500, y: 0)` is the D65 white point in the units
    /// `CITemperatureAndTint` uses, and it is the documented value for "no change" —
    /// passing a zero vector instead would shift everything wildly.
    ///
    /// The components are `CGFloat`; the offsets are `Float` because that is what the
    /// slider and the metadata carry. The conversion is explicit rather than inferred.
    var neutralVector: CIVector { CIVector(x: 6500, y: 0) }

    var targetNeutralVector: CIVector {
        CIVector(x: CGFloat(6500) + CGFloat(temperatureOffset), y: CGFloat(tintOffset))
    }

    /// `CIExposureAdjust`'s EV input, from a 0…1 slider.
    ///
    /// The slider is linear in *stops of exposure the user thinks they are asking for*
    /// only loosely, so the range is capped at +2 EV. Beyond that a phone photo is
    /// clipping and the slider should be asking for a different correction.
    var exposureEV: Float { exposure * 2.0 }

    /// `CIColorControls` contrast is centred on 1.0, not 0.0, so a -1…1 dial is mapped
    /// onto 0…2. Doing that mapping here rather than in the stage keeps the maths next to
    /// the numbers it explains.
    var colorControlsContrast: Float { 1.0 + contrast }

    /// `CIColorControls` saturation is centred on 1.0 too.
    var colorControlsSaturation: Float { 1.0 + saturation }

    /// Lift as a brightness offset, where -1…1 maps onto -0.5…0.5. A full -1 would be a
    /// completely black frame, which is not a correction anybody wants.
    var brightness: Float { lift * 0.5 }
}
