import Foundation

/// What Step 5's ML layer found, and whether it is worth acting on.
///
/// This is **statistics, not pixel data**, and the distinction is forced rather than
/// stylistic. A `CVPixelBuffer` is neither `Equatable` nor `Codable`, so a struct that held
/// one could not be part of a recipe — and a recipe is what has to survive in the photo's
/// metadata. The mask image itself belongs to the frame it was computed for and is passed
/// to the pipeline alongside this value, never inside it.
///
/// `coverage` and `confidence` are both kept because both change what the pipeline should
/// do: a mask covering 95% of the frame is a segmentation failure, not a subject, and
/// applying a look to "the subject" in that case means applying it to everything.
struct SubjectMask: Equatable, Codable, Sendable {

    /// Fraction of the frame the mask covers, 0…1.
    var coverage: Float

    /// How sure the detector is, 0…1. `VNGeneratePersonSegmentationRequest` does not
    /// report a score, so this comes from the mask buffer's own statistics and is a
    /// proxy, which is why it is named `confidence` and not `score`.
    var confidence: Float

    /// A mask covering more than this is treated as "no subject found" rather than as a
    /// segmentation that happened to fill the frame.
    ///
    /// ## Why this is 0.98 and not 0.85
    ///
    /// This gate rejected nearly every mask the app computed. The log said so on frame after
    /// frame:
    ///
    ///     subject mask not used: mask rejected: covers the frame
    ///
    /// `coverage` is the **mean** of Vision's mask buffer, so it is the fraction of the frame
    /// the person occupies. At 0.85 that discards any shot where the subject fills more than
    /// about six sevenths of the frame — which is most close-ups, and is precisely the
    /// photograph where a subject mask is worth having. The gate was rejecting good
    /// segmentation as though it were a failure.
    ///
    /// The value that actually indicates failure is 1.0: a mask that is uniformly foreground
    /// has found no boundary at all, which is a different fault and is caught properly by the
    /// confidence proxy below, since a uniform mask has no bimodality and so scores near 0.
    /// Keeping a separate coverage gate at 0.98 catches the literal no-boundary case without
    /// rejecting a close-up.
    static let maximumCoverage: Float = 0.98

    /// Below this the mask is too weak to act on, and the look goes on globally instead.
    static let minimumConfidence: Float = 0.25

    var isEmpty: Bool { coverage <= 0 }

    /// Whether the pipeline should blend by this mask at all.
    ///
    /// Both bounds exist because a mask that is wrong in either direction produces a worse
    /// photo than no mask: too large and the "subject" is the background, too weak and the
    /// blend edge shows as a halo.
    var isUsable: Bool {
        coverage > 0 && coverage < Self.maximumCoverage && confidence >= Self.minimumConfidence
    }

    /// What the pipeline should actually do, as a log-friendly word.
    func decision() -> String {
        if isEmpty { return "no subject" }
        if coverage >= Self.maximumCoverage { return "mask rejected: covers the frame" }
        if confidence < Self.minimumConfidence { return "mask rejected: low confidence" }
        return "blend \(Int(coverage * 100))%"
    }
}
