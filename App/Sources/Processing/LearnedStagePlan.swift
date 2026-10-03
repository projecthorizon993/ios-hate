import CoreGraphics
import Foundation

/// Which lens took a shot, as a routing decision rather than as a lens name.
///
/// The lens is read from what the device reported at the moment of capture and resolved
/// through `BackCameraCapabilities.Kind`, so it is a measurement. Nothing here compares a
/// marketing name or a device model, which are the two things that cannot be tested against.
enum CaptureLens: String, Equatable, Sendable {

    case ultraWide
    case wide
    case telephoto
    /// A composite whose active constituent could not be resolved. Routed as `wide`, because
    /// the wide is the constituent a composite falls back to and therefore the safer default.
    case composite
    case front
    case unknown

    /// The lens from what the capture actually recorded.
    ///
    /// The recipe's `lensKind` holds a `deviceType` raw value, not one of these cases, because
    /// a file that stored the app's own enum would become unreadable the moment the app
    /// renamed or extended it. So the mapping happens here, at read time.
    init(lensKind: String?, frontCamera: Bool) {
        if frontCamera {
            self = .front
            return
        }
        guard let lensKind, !lensKind.isEmpty else {
            self = .unknown
            return
        }
        self = CaptureLens(kind: BackCameraCapabilities.kind(ofRawValue: lensKind))
    }

    init(kind: BackCameraCapabilities.Kind) {
        switch kind {
        case .ultraWide: self = .ultraWide
        case .wide: self = .wide
        case .telephoto: self = .telephoto
        case .composite: self = .composite
        case .unknown: self = .unknown
        }
    }

    var isFront: Bool { self == .front }

    /// The lens whose stages this one borrows.
    ///
    /// A composite is the wide for processing purposes, because Apple documents a composite
    /// falling back to its wide constituent — so when the active constituent could not be
    /// resolved, the wide is the constituent that will actually have taken the shot. Without
    /// this the composite would match no stage at all and silently get nothing, which is the
    /// wrong answer for the common 1x composite shot.
    ///
    /// `unknown` maps to itself, and therefore to nothing: a lens this app does not recognise
    /// runs no model rather than a guessed one.
    var routingLens: CaptureLens {
        self == .composite ? .wide : self
    }
}

/// What a learned stage is for, and which lens earns it.
///
/// The three cases are **not** interchangeable, and treating them as one "AI enhance" toggle
/// is how a model ends up inventing detail where none was captured. Each is chosen because
/// that lens has that specific defect:
///
/// - **Denoise, ultra wide.** The ultra wide opens to f/2.4 against the wide's f/1.8, so at
///   matched ISO it gathers less light and reads noisier. This is the one case where a
///   denoise model does work the arithmetic does not: it can separate noise from texture
///   rather than blurring both together.
/// - **Super-resolution, telephoto.** Past the optical limit the frame is a crop, so there
///   is no more real detail to recover — only pixels to make convincing. Worth shipping
///   because it looks better than blocky interpolation, not because the information is
///   there. Gated by zoom rather than by lens alone, since the telephoto is sharp inside its
///   optical range and needs nothing.
/// - **Low-light, wide.** **Not** a denoise. A night shot is multi-frame fusion and a long
///   exposure, and by the time the photo reaches this app the ISP has already done that work;
///   denoising on top tends to remove the shadow detail the fusion deliberately preserved. A
///   real fix here is a tonemapping model, which competes with Apple rather than
///   complementing them, so it is declared and not faked.
///
/// Declared rather than implemented, and every function here is pure. What the models will
/// actually do is the next step, and the routing has to be settled before any of it: a model
/// running on the wrong lens is worse than no model at all.
enum LearnedStage: String, Equatable, Sendable {

    case denoise
    case superResolution
    case lowLightToneMap

    /// The lens this stage is for. A stage never runs on a lens other than its own, so a
    /// missing model degrades to "nothing happens" rather than to the wrong enhancement.
    var lens: CaptureLens {
        switch self {
        case .denoise: return .ultraWide
        case .superResolution: return .telephoto
        case .lowLightToneMap: return .wide
        }
    }

    /// Whether this stage applies to a shot from `lens`.
    ///
    /// The front camera is excluded from every stage: it has no low-light problem to solve
    /// worth solving, and the front sensor is not one these models were trained for.
    func applies(to lens: CaptureLens) -> Bool {
        lens.routingLens == self.lens
    }
}

/// Which learned stages a single capture calls for.
///
/// This is the routing decision, kept as one pure function so it can be asserted without a
/// device, a model file or a Neural Engine. Everything downstream — which stage runs, at what
/// strength, or whether it is skipped for want of a model — reads this.
enum LearnedStagePlan: Equatable, Sendable {

    case none
    case stages([LearnedStage])

    var stages: [LearnedStage] {
        if case .stages(let list) = self { return list }
        return []
    }

    /// Decides what should run for one capture.
    ///
    /// Super-resolution additionally requires being past the optical range. The telephoto is
    /// genuinely sharp on its own inside that range, and running an SR model there would
    /// smooth real detail to add invented detail — the exact failure the stage is supposed to
    /// avoid, applied to the one lens where it would be most visible.
    ///
    /// `minimumSuperResolutionZoom` is injectable so the threshold can be asserted against a
    /// known device's optical range rather than a number someone assumed; the default is the
    /// point past which the telephoto begins cropping.
    static func plan(for metadata: CaptureMetadata,
                     minimumSuperResolutionZoom: Double = 4) -> LearnedStagePlan {
        // Routed, not raw: a composite borrows the wide's stages, because that is the
        // constituent a composite falls back to and so the one that took the shot.
        let lens = CaptureLens(lensKind: metadata.lensKind,
                               frontCamera: metadata.frontCamera).routingLens
        guard !lens.isFront else { return .none }

        var chosen: [LearnedStage] = []
        for stage in [LearnedStage.denoise, .lowLightToneMap] where stage.applies(to: lens) {
            chosen.append(stage)
        }
        // Only a genuine crop earns super-resolution.
        if let zoom = metadata.zoomFactor, zoom >= minimumSuperResolutionZoom,
           LearnedStage.superResolution.applies(to: lens) {
            chosen.append(.superResolution)
        }
        return chosen.isEmpty ? .none : .stages(chosen)
    }
}