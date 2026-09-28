import CoreGraphics
import Foundation

/// Everything the pipeline does to a frame, in one value.
///
/// The point of a single recipe type is that **the preview and the saved photo run the
/// exact same thing**. Two code paths is how a look ends up looking correct on screen and
/// wrong in the file, and it is the single most common bug in a camera app. So there is
/// one of these, and both callers pass the same instance.
///
/// `Codable` because the recipe has to survive in the capture metadata: the original bytes
/// are written untouched and the recipe sits beside them, so any photo can be re-rendered
/// later from the original rather than from a derived file.
struct ProcessingSettings: Equatable, Codable, Sendable {

    /// Manual corrections. `nil` rather than `.neutral` so "never touched" is
    /// distinguishable from "set back to zero", and the stage is skipped when nil.
    var tone: ToneCurve?

    /// The look. `nil` means no LUT at all, which is the default and the common case.
    var look: Look?

    /// 0…1. Kept here rather than on `Look` so the same look can be dialled per photo and
    /// the value is part of the recipe rather than of the look's definition.
    var lookIntensity: Float = 0

    /// Step 5. Nil until the ML layer exists, and then only where a subject was found.
    var subjectMask: SubjectMask?

    /// 0…1, applied after the look. Grain in linear light is invisible in shadows, so
    /// this runs in gamma space.
    var grain: Float = 0
    /// 0…2.5, the CISharpness radius, applied only after the look.
    var sharpen: Float = 0

    static let none = ProcessingSettings()

    /// Clamped, as the boundary contract the controls rely on.
    func clamped() -> ProcessingSettings {
        var copy = self
        copy.tone = tone?.clamped()
        copy.lookIntensity = min(max(lookIntensity.isFinite ? lookIntensity : 0, 0), 1)
        copy.grain = min(max(grain.isFinite ? grain : 0, 0), 1)
        copy.sharpen = min(max(sharpen.isFinite ? sharpen : 0, 0), 2.5)
        return copy
    }

    /// `true` when every stage would be a no-op, so the caller can skip Core Image
    /// entirely. Worth having: on an iPhone SE this is the difference between a live
    /// preview and a warm one.
    var isIdentity: Bool {
        (tone?.isIdentity ?? true)
            && (look == nil || lookIntensity == 0)
            && subjectMask == nil
            && grain == 0
            && sharpen == 0
    }

    /// One line for the log and for the capture metadata.
    func summarise() -> String {
        var parts: [String] = []
        if let tone, !tone.isIdentity { parts.append("tone(\(tone))") }
        if let look, lookIntensity > 0 { parts.append("look(\(look.name)@\(lookIntensity))") }
        if let subjectMask, !subjectMask.isEmpty { parts.append("subject(\(subjectMask.coverage))") }
        if grain > 0 { parts.append("grain(\(grain))") }
        if sharpen > 0 { parts.append("sharpen(\(sharpen))") }
        return parts.isEmpty ? "identity" : parts.joined(separator: " ")
    }
}
