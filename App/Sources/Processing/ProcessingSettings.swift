import CoreGraphics
import Foundation

/// Everything the pipeline does to a frame, in one value.
///
/// The point of a single recipe type is that **the preview and the saved photo run the
/// exact same thing**. Two code paths is how a grade ends up looking correct on screen and
/// wrong in the file, and it is the single most common bug in a camera app. So there is
/// one of these, and both callers pass the same instance.
///
/// `Codable` because the recipe has to survive in the capture metadata: the original bytes
/// are written untouched and the recipe sits beside them, so any photo can be re-rendered
/// later from the original rather than from a derived file.
///
/// Recipes written before looks were removed may still carry `look`, `lookIntensity` and
/// `subjectMask` keys. `Decodable` ignores unknown keys, so those files decode into a
/// recipe with no grade in it and render as the original — which is the declared
/// behaviour for old look photos, not a migration.
struct ProcessingSettings: Equatable, Codable, Sendable {

    /// Manual corrections. `nil` rather than `.neutral` so "never touched" is
    /// distinguishable from "set back to zero", and the stage is skipped when nil.
    var tone: ToneCurve?

    /// An imported color table, applied by the engine between tone and finish.
    /// `nil` (or zero intensity) means no table stage at all.
    var lut: LutReference?

    /// What the last segmentation found. Travels so preview and file blend by the
    /// same numbers; the pixels are always recomputed from the frame being graded.
    /// `nil` (or unusable numbers) grades globally — the honest fallback.
    var subject: SubjectStat?

    /// 0…1. Grain in linear light is invisible in shadows, so this runs in gamma space.
    var grain: Float = 0
    /// 0…2.5, the CISharpness radius, applied after denoise thinking — never before
    /// it, so noise is not sharpened into texture.
    var sharpen: Float = 0

    static let none = ProcessingSettings()

    /// Clamped, as the boundary contract the controls rely on.
    func clamped() -> ProcessingSettings {
        var copy = self
        copy.tone = tone?.clamped()
        copy.lut = lut?.clamped()
        copy.subject = subject?.clamped()
        copy.grain = min(max(grain.isFinite ? grain : 0, 0), 1)
        copy.sharpen = min(max(sharpen.isFinite ? sharpen : 0, 0), 2.5)
        return copy
    }

    /// `true` when every stage would be a no-op, so the caller can skip Core Image
    /// entirely. Worth having: on an iPhone SE this is the difference between a live
    /// preview and a warm one.
    ///
    /// Subject statistics never break identity on their own: without an active table
    /// there is nothing to blend, so a stats-only recipe still gets the direct
    /// preview layer rather than a processed pass that changes nothing.
    var isIdentity: Bool {
        (tone?.isIdentity ?? true)
            && (lut == nil || lut?.intensity == 0)
            && grain == 0
            && sharpen == 0
    }

    /// One line for the log and for the capture metadata.
    func summarise() -> String {
        var parts: [String] = []
        if let tone, !tone.isIdentity { parts.append("tone(\(tone))") }
        if let lut, lut.intensity > 0 {
            parts.append("table(\(lut.filename)@\(lut.intensity))")
        }
        if let subject, subject.isUsable { parts.append("subject(\(subject.decision()))") }
        if grain > 0 { parts.append("grain(\(grain))") }
        if sharpen > 0 { parts.append("sharpen(\(sharpen))") }
        return parts.isEmpty ? "identity" : parts.joined(separator: " ")
    }
}
