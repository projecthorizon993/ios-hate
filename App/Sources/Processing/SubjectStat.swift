import Foundation

/// What the engine records about a found subject.
///
/// Statistics only — never pixels. The pixels belong to the frame they were
/// computed from and are gone with it; these numbers ride in the recipe so a
/// re-render can record that a subject was found, and the mask is recomputed
/// from the original rather than stored.
struct SubjectStat: Equatable, Codable, Sendable {

    /// Mean mask value, 0…1. Near 0 is no subject; near 1 is no background.
    var coverage: Float
    /// Bimodality proxy, 0…1. A confident mask splits cleanly into subject and
    /// background; an uncertain one hovers around the mean.
    var confidence: Float

    /// Whether the numbers describe a subject worth blending around.
    ///
    /// Pure, so the gate is unit tested: a full-frame "subject" is a close-up or
    /// (with no bimodality) a segmentation with nothing to say, and either way
    /// blending by it is worse than applying the grade globally.
    var isUsable: Bool {
        coverage > 0.01 && coverage < 0.98 && confidence >= 0.2
    }

    /// One line for the log, naming the rejection rather than just refusing.
    func decision() -> String {
        if coverage <= 0.01 { return "no subject" }
        if coverage >= 0.98 { return "covers the frame" }
        if confidence < 0.2 { return "low confidence" }
        return "blend \(Int((coverage * 100).rounded()))%"
    }

    /// Clamped copy: statistics arrive from pixel sampling and must never carry
    /// a NaN into a recipe comparison or a Codable file.
    func clamped() -> SubjectStat {
        func clamp(_ value: Float) -> Float {
            guard value.isFinite else { return 0 }
            return min(max(value, 0), 1)
        }
        return SubjectStat(coverage: clamp(coverage), confidence: clamp(confidence))
    }
}
