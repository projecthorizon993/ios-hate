import AVFoundation
import CoreMedia
import Foundation
import UIKit

/// Performance tier. Tier controls preview ML frequency and resolution only, and it is
/// recomputed from the Step 5 render/inference benchmark. Until that benchmark exists
/// it is `nil` — a guessed tier would be a fabricated measurement, which
/// `IOS_CAMERA_APP_PLAN.md` rule 8 forbids.
enum DeviceTier: String, Equatable, Sendable, CaseIterable {
    case high
    case mid
    case low
}

/// Which way the camera faces. A plain `String` rather than
/// `AVCaptureDevice.Position` so the whole model stays `Sendable` and trivially
/// comparable in tests.
enum CameraFacing: String, Equatable, Sendable {
    case back
    case front
}

/// Result of asking the capability model whether a control may exist.
///
/// `docs/ARCHITECTURE.md` section 5: hide what does not exist, disable what exists
/// but is unavailable right now, and never simulate. The reason string is not
/// decoration — it is what the UI shows next to a disabled control, and it is why a
/// control was disabled is the first thing to check when a report comes back odd.
enum FeatureAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// `nil` when available. Callers must not invent a reason for an available feature.
    var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// One back-facing camera, described only by what the device reported at runtime.
///
/// No device name or model string appears anywhere in this type. The iPhone SE 2022
/// has a single back camera and must therefore show no lens UI, and the only
/// trustworthy way to know that is to enumerate the device.
struct BackCameraCapabilities: Equatable, Identifiable, Sendable {

    enum Kind: String, Equatable, Sendable {
        case ultraWide
        case wide
        case telephoto
        /// A `builtInDualCamera` / `builtInTripleCamera` composite. Real physical
        /// lenses are always preferred when discovery also reports them, so a
        /// composite only survives when nothing else was found.
        case composite
        case unknown
    }

    var id: String { uniqueID }

    var uniqueID: String
    var kind: Kind
    /// A relative measure of this lens's reach, used only for ordering the lenses and
    /// for the zoom ratios below.
    ///
    /// iOS exposes no 35 mm equivalent focal length — not on `AVCaptureDevice`, not on
    /// `AVCaptureDevice.Format` — so this is not millimetres and is not named as if it
    /// were. See `relativeScale(of:)` for how it is derived.
    var relativeScale: Double
    /// Whether the device reports a virtual multi-camera device with optical
    /// switch-over points. The points themselves are read in step 6, when there is a
    /// real device to verify them against; step 1 only needs the yes or no to decide
    /// whether a zoom control may exist at all.
    var hasOpticalZoomSteps: Bool
    /// Negative when the device does not report it.
    var minimumFocusDistance: Double
    var flashAvailable: Bool

    /// Video dimensions of the format the device is currently on, as width x height.
    ///
    /// Recorded because `relativeScale` is unusable — it came back as one constant for
    /// every lens on an iPhone 11 Pro, since the lenses share a still resolution *and* the
    /// virtual devices report a shared default `activeFormat`. The video dimensions are a
    /// different per-lens quantity and are the most likely place a real focal-length ratio
    /// could come from. Whether they actually differ per lens on that hardware is
    /// **unknown** — this row exists so the next device run answers it.
    var videoDimensions: String = "n/a"
    /// `device.virtualDeviceSwitchOverVideoZoomFactors`, verbatim.
    ///
    /// The only documented way iOS offers to learn where a composite hands over to a
    /// different physical lens, so this is the natural basis for lens chips on a multi-lens
    /// device. Recorded rather than used, because what it actually reports on this hardware
    /// has not been observed.
    var switchOverZoomFactors: [Double] = []

    static func describe(_ device: AVCaptureDevice) -> BackCameraCapabilities {
        BackCameraCapabilities(
            uniqueID: device.uniqueID,
            kind: kind(of: device.deviceType),
            relativeScale: Self.relativeScale(of: device.activeFormat),
            hasOpticalZoomSteps: !device.virtualDeviceSwitchOverVideoZoomFactors.isEmpty,
            minimumFocusDistance: Double(device.minimumFocusDistance),
            flashAvailable: device.isFlashAvailable,
            videoDimensions: Self.videoDimensions(of: device.activeFormat),
            // `virtualDeviceSwitchOverVideoZoomFactors` is `[NSNumber]`; converted here so
            // every consumer of this type deals in `Double` and nothing has to remember.
            switchOverZoomFactors: device.virtualDeviceSwitchOverVideoZoomFactors
                .map { Double($0.doubleValue) }
        )
    }

    /// Width x height of the format's video, which is lens-specific where the still
    /// dimensions are not.
    private static func videoDimensions(of format: AVCaptureDevice.Format) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return "\(dimensions.width)x\(dimensions.height)"
    }

    /// Derived from the largest still the format can produce.
    ///
    /// **This does not measure focal length, and on a modern iPhone it returns a
    /// constant.** It was justified as "still area scales with the square of the focal
    /// length, so the ratio of these square roots between two lenses *is* the focal length
    /// ratio". That reasoning is only sound if each lens's still dimensions track its own
    /// focal length. Two things break it, both observed on an iPhone 11 Pro
    /// (`docs/device-record-01.md` finding 3):
    ///
    /// 1. **The lenses share a resolution.** Ultra wide, wide and telephoto are all 12MP,
    ///    so the ratio is 1.0 between every pair regardless of the optics.
    /// 2. **The read is not lens-specific.** Six separately discovered devices — three of
    ///    them distinct composites — all reported the identical value 3168.0. Each virtual
    ///    device comes up with the same default `activeFormat`, and on a composite that
    ///    format is shared, so this reads the same dimensions every time. 3168 is also not
    ///    the 11 Pro's 12MP still (4032x3024 gives √ ≈ 3492), so it is not even a real
    ///    still size.
    ///
    /// The value is kept because it still orders lenses correctly where it is not
    /// degenerate, but it must never be used to label one. `lensesAreDistinguishable` is
    /// what consumers are required to ask first, and `lensSelector` hides the control
    /// entirely when the answer is no. Showing three chips that all read "1x" — three
    /// controls that do nothing — is the exact defect rule 4 in `docs/HANDOFF.md` exists to
    /// prevent.
    private static func relativeScale(of format: AVCaptureDevice.Format) -> Double {
        let largest = format.supportedMaxPhotoDimensions.max {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }
        guard let largest else { return 0 }
        return Double(Int(largest.width) * Int(largest.height)).squareRoot()
    }

    static func kind(of type: AVCaptureDevice.DeviceType) -> Kind {
        switch type {
        case .builtInUltraWideCamera: return .ultraWide
        case .builtInWideAngleCamera: return .wide
        case .builtInTelephotoCamera: return .telephoto
        case .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera: return .composite
        default: return .unknown
        }
    }
}

/// The one place that decides which back camera the session binds and which lenses the
/// UI is allowed to offer.
///
/// Two halves of the same fact used to disagree. `CaptureSessionController.pickDevice`
/// preferred a **composite** device, with a comment saying this keeps one session alive,
/// while `CameraCapabilities.attachBackCameras` filtered composites **out** of the
/// capability model. So the UI offered physical lens chips for a session that was running
/// a different device, and no test covered the session half — which is why CI stayed green
/// on a contradiction.
///
/// The fix is not two matching copies of the rule; it is one rule with two readers.
/// `pickDevice` and `attachBackCameras` both consume this value, so they cannot drift
/// without a test failing.
///
/// Binding a **constituent** device in Pro mode is deliberately *not* done here. It is a
/// session reconfiguration per lens change, it has never been run on a device, and
/// `docs/PHASES.md` 3.1 records it as Phase 3. Until then the composite is bound and the
/// Pro panel is empty by design rather than by accident — and `ProCapabilities` gates
/// itself on the bound device, so the empty panel and the session agree.
struct CameraPlan: Equatable, Sendable {

    /// The device the session binds, or `nil` when discovery found nothing.
    var bound: BackCameraCapabilities?
    /// The lenses reachable from `bound`, in reach order. Never more than the bound device
    /// can actually switch to.
    var offeredLenses: [BackCameraCapabilities]
    /// Whether a constituent device exists that Pro mode could bind instead.
    ///
    /// Recorded rather than acted on, because binding it is Phase 3 work that needs a
    /// device to verify. It is here so the "Pro is empty" state has a recorded cause
    /// instead of being an unexplained gap.
    var hasConstituentForPro: Bool

    /// Whether Pro mode would have to bind a **different** device than Auto mode does.
    ///
    /// The one that explains an empty Pro panel, and deliberately narrower than
    /// `hasConstituentForPro`. A single-lens device has a constituent — itself — so
    /// `hasConstituentForPro` is true there, and that is not a problem: the bound device
    /// already supports `.custom`. The empty-panel case is exactly "a composite is bound
    /// *and* a constituent exists to bind instead", which is what this is.
    var proRequiresRebinding: Bool

    /// Derives the plan from a discovery result.
    ///
    /// Takes `BackCameraCapabilities` rather than `AVCaptureDevice` so the rule is a pure
    /// function of runtime-reported data and can be tested without a camera — which is the
    /// only way the two readers can be proven to agree in CI.
    static func resolve(discovered: [BackCameraCapabilities]) -> CameraPlan {
        let back = discovered.filter { $0.kind != .unknown }
        let constituents = back.filter { $0.kind != .composite }
            .sorted { $0.relativeScale < $1.relativeScale }
        let composites = back.filter { $0.kind == .composite }

        // A composite is preferred for the session, and the reason is recorded rather than
        // assumed: switching its virtual devices keeps one session alive. A device that
        // reports constituents but no composite binds its own wide lens, which is still a
        // real lens and still supports `.custom`.
        let bound = composites.first ?? constituents.first
        let isBoundComposite = bound?.kind == .composite

        // The offered lenses are the constituents whenever there are any, because a
        // composite *is* the constituents — that is what a composite is. A composite only
        // stands in as its own single lens when discovery reported nothing else, which is
        // the one case where there is no second lens to lie about.
        let offered = isBoundComposite
            ? (constituents.isEmpty ? [bound].compactMap { $0 } : constituents)
            : [bound].compactMap { $0 }

        return CameraPlan(bound: bound,
                          offeredLenses: offered,
                          hasConstituentForPro: !constituents.isEmpty,
                          proRequiresRebinding: isBoundComposite && !constituents.isEmpty)
    }
}

/// Everything the camera UI is allowed to know about the device.
///
/// Produced once at launch and refreshed whenever the configuration changes. There is
/// exactly one instance per running session, so two screens can never disagree about
/// whether a control exists.
struct CameraCapabilities: Equatable, Sendable {

    var facing: CameraFacing = .back
    /// Physical lenses, in the order they should be offered. Empty when the device
    /// has no back camera at all (front-only tablets, and the simulator).
    var backCameras: [BackCameraCapabilities] = []
    /// Which camera the session binds and which lenses may be offered, derived once by
    /// `CameraPlan.resolve` and read by both `attachBackCameras` and
    /// `CaptureSessionController.pickDevice`. `.unknown` until a discovery result is
    /// attached, so nothing can act on a guess.
    var plan = CameraPlan(bound: nil,
                          offeredLenses: [],
                          hasConstituentForPro: false,
                          proRequiresRebinding: false)
    /// `AVCapturePhotoOutput.availableRawPhotoPixelFormatTypes`. Empty means no RAW.
    /// The property is spelled `...PixelFormatTypes`, not `...PixelTypes`.
    var rawPixelTypes: [OSType] = []
    /// `AVCapturePhotoOutput.isAppleProRAWSupported`. Independent of `rawPixelTypes`:
    /// a device can support one and not the other.
    var proRawSupported = false
    /// Display P3 capture, from the active format's primaries.
    var wideGamut = false
    /// `isHighPhotoQualitySupported` on the active format. Without it,
    /// `photoQualityPrioritization = .quality` buys nothing.
    var photoQualitySupported = false
    /// `isHighestPhotoQualitySupported` on the active format.
    var highestPhotoQualitySupported = false
    /// `isVideoHDRSupported` on the active format. Hardware HDR ability.
    var videoHDRSupported = false
    /// Populated by the Step 5 benchmark. `nil` until then.
    var deviceTier: DeviceTier?

    /// Value used before probing completes, and the value the UI shows while it waits.
    /// Everything is unavailable, so no control can be enabled on a guess.
    static let unknown = CameraCapabilities()

    // MARK: - Derived

    /// The camera the 1x button maps to. Real focal length, not a convention.
    var referenceCamera: BackCameraCapabilities? {
        backCameras.first { $0.kind == .wide }
            ?? backCameras.filter { $0.kind != .composite }.min { $0.relativeScale < $1.relativeScale }
            ?? backCameras.first
    }

    /// Whether the app can tell these lenses apart, which it cannot on most modern iPhones.
    ///
    /// The requirement is that each lens report a **distinct** `relativeScale`. Equal scales
    /// mean the zoom label for every lens computes to 1.0 — three chips reading "1x", and a
    /// tap that computes a destination of 1.0, which is where the camera already is. That
    /// is the state observed on an iPhone 11 Pro, where six discovered devices all reported
    /// the same value.
    ///
    /// `false` therefore means **hide the lens selector**, not "label them arbitrarily" and
    /// certainly not a hard-coded `0.5x 1x 2x`, which is a guess dressed as a measurement.
    var lensesAreDistinguishable: Bool {
        let scales = physicalLenses.map(\.relativeScale)
        guard scales.count > 1 else { return true }
        // A zero scale is the "could not measure" value and carries no information either.
        guard scales.allSatisfy({ $0 > 0 }) else { return false }
        return Set(scales).count == scales.count
    }

    /// Zoom chip label for a lens, as a measured ratio against `referenceCamera`.
    ///
    /// `nil` when the ratio cannot be established — including the case where the lenses
    /// cannot be told apart at all — in which case the UI shows no chip rather than a
    /// `1x` that means nothing.
    func zoomLabel(for camera: BackCameraCapabilities) -> String? {
        guard lensesAreDistinguishable else { return nil }
        guard let reference = referenceCamera, reference.relativeScale > 0 else { return nil }
        let ratio = camera.relativeScale / reference.relativeScale
        guard ratio > 0 else { return nil }
        return String(format: "%.1fx", ratio)
    }

    /// A device with one lens has no lens selector and no zoom steps at all.
    var physicalLenses: [BackCameraCapabilities] {
        let physical = backCameras.filter { $0.kind != .composite && $0.kind != .unknown }
        return physical.isEmpty ? backCameras : physical
    }

    // MARK: - Gating

    var lensSelector: FeatureAvailability {
        let lenses = physicalLenses
        if lenses.isEmpty { return .unavailable(reason: "No back camera reported") }
        if lenses.count > 1 && !lensesAreDistinguishable {
            // Observed on an iPhone 11 Pro, where every discovered lens reported the same
            // focal-length proxy and so every chip would read "1x". Three controls that do
            // nothing are worse than no control, and a hard-coded 0.5x/1x/2x would be a
            // guess presented as a measurement. Hidden until the app can measure the
            // lenses; see `docs/device-record-01.md` finding 3.
            return .unavailable(reason: "Lenses report identical optical data — nothing to switch between")
        }
        if lenses.count > 1 { return .available }
        return .unavailable(reason: "Single camera — no lens switching")
    }

    var rawCapture: FeatureAvailability {
        if !rawPixelTypes.isEmpty { return .available }
        return .unavailable(reason: "This camera has no RAW output")
    }

    var proRawCapture: FeatureAvailability {
        if proRawSupported { return .available }
        return .unavailable(reason: "Apple ProRAW is not supported on this device")
    }

    /// The badge wording is derived, so the hardware half of the gate is
    /// `isVideoHDRSupported` on the active format. See `HDRStatus`.
    var hdr: FeatureAvailability {
        if videoHDRSupported { return .available }
        return .unavailable(reason: "Active format does not support HDR")
    }

    var flash: FeatureAvailability {
        if backCameras.contains(where: { $0.flashAvailable }) { return .available }
        return .unavailable(reason: "No flash on this camera")
    }

    /// Optical zoom is only advertised when the device reports a virtual multi-camera
    /// device with switch-over factors. A single-lens device has no zoom steps.
    var opticalZoom: FeatureAvailability {
        let hasSteps = physicalLenses.contains { $0.hasOpticalZoomSteps }
        if hasSteps { return .available }
        return .unavailable(reason: "No optical zoom range reported")
    }

    // MARK: - Probing

    /// Builds the model from a live device, its active format, and a photo output that
    /// is already attached to a session with that input.
    ///
    /// The session and the output are both required: `availableRawPhotoPixelFormatTypes`
    /// and `isAppleProRAWSupported` are documented as properties of the output in its
    /// current environment, and reading them from the device alone is not possible.
    static func probe(device: AVCaptureDevice,
                      format: AVCaptureDevice.Format,
                      photoOutput: AVCapturePhotoOutput) -> CameraCapabilities {
        var capabilities = CameraCapabilities()
        capabilities.facing = device.position == .front ? .front : .back
        capabilities.rawPixelTypes = photoOutput.availableRawPhotoPixelFormatTypes
        capabilities.proRawSupported = photoOutput.isAppleProRAWSupported
        capabilities.photoQualitySupported = format.isHighPhotoQualitySupported
        capabilities.highestPhotoQualitySupported = format.isHighestPhotoQualitySupported
        capabilities.videoHDRSupported = format.isVideoHDRSupported
        capabilities.wideGamut = carriesWideGamut(format)
        AppLog.note(AppLog.camera,
                    "capabilities: facing=\(capabilities.facing.rawValue) "
                    + "raw=\(capabilities.rawPixelTypes.count) proRAW=\(capabilities.proRawSupported) "
                    + "photoQuality=\(capabilities.photoQualitySupported) "
                    + "highestQuality=\(capabilities.highestPhotoQualitySupported) "
                    + "videoHDR=\(capabilities.videoHDRSupported) p3=\(capabilities.wideGamut)")
        return capabilities
    }

    /// Fills in `backCameras` and `plan` from a discovery result.
    ///
    /// Delegates entirely to `CameraPlan.resolve`, which is also what the session reads to
    /// choose its device. Physical lenses still win over composites here — an iPhone 11 Pro
    /// Max reports its three lenses *and* a `builtInTripleCamera`, and offering four buttons
    /// for three lenses would be a lie — but that is now a consequence of the shared rule
    /// rather than a second copy of it.
    mutating func attachBackCameras(_ devices: [AVCaptureDevice]) {
        let described = devices
            .filter { $0.position == .back }
            .map(BackCameraCapabilities.describe)
        let resolved = CameraPlan.resolve(discovered: described)
        plan = resolved
        backCameras = resolved.offeredLenses
    }

    /// Display P3 capture, read from the format description rather than from
    /// `Format.videoSupportedColorSpaces`, which Apple deprecated in iOS 16.
    ///
    /// `P3_D65` is the direct answer. `ITU_R_2020` is also wide-gamut, and a format
    /// that declares it can hold P3 primaries, so both count.
    static func carriesWideGamut(_ format: AVCaptureDevice.Format) -> Bool {
        guard let extensions = CMFormatDescriptionGetExtensions(format.formatDescription)
            as? [String: Any],
            let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        else { return false }
        return primaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String)
            || primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
    }
}

// MARK: - Exposure ranges

/// The real, device-reported limits of the active format.
///
/// Auto mode never writes these — the system does — but the app still has to *read*
/// them, and any recovery path that re-applies a stored value (Step 4 presets, a
/// device rotation that restores state) has to clamp through the same numbers. Putting
/// the arithmetic in a plain value type is what makes it testable without a device.
struct ExposureRange: Equatable, Sendable {

    var minISO: Float
    var maxISO: Float
    var minShutterSeconds: Double
    var maxShutterSeconds: Double
    var minExposureTargetOffset: Double
    var maxExposureTargetOffset: Double

    /// `supportedExposureTargetOffsetRange` is not exposed on iOS, on either the device
    /// or its format, so the bounds fall back to the EV range every iPhone camera
    /// documents rather than being reported as something the device said. The current
    /// offset is read from the device, so this range is only ever used for clamping a
    /// value the app is about to write, and step 4 verifies it on device.
    static let defaultOffsetRange = -8.0...8.0

    static func from(_ format: AVCaptureDevice.Format) -> ExposureRange {
        ExposureRange(
            minISO: format.minISO,
            maxISO: format.maxISO,
            minShutterSeconds: CMTimeGetSeconds(format.minExposureDuration),
            maxShutterSeconds: CMTimeGetSeconds(format.maxExposureDuration),
            minExposureTargetOffset: defaultOffsetRange.lowerBound,
            maxExposureTargetOffset: defaultOffsetRange.upperBound
        )
    }

    func clampedISO(_ value: Float) -> Float {
        guard maxISO > minISO else { return minISO }
        return min(max(value, minISO), maxISO)
    }

    /// Shutter is clamped to the format's own limits. A `CMTime` built from an
    /// out-of-range `CMTimeSeconds` raises an Objective-C exception inside
    /// AVFoundation, which is why every write site is clamped first and additionally
    /// wrapped in `LumaFrameSafety`.
    func clampedShutterSeconds(_ value: Double) -> Double {
        guard maxShutterSeconds > minShutterSeconds else { return minShutterSeconds }
        guard value.isFinite, value > 0 else { return minShutterSeconds }
        return min(max(value, minShutterSeconds), maxShutterSeconds)
    }

    func clampedExposureTargetOffset(_ value: Double) -> Double {
        guard maxExposureTargetOffset > minExposureTargetOffset else { return minExposureTargetOffset }
        guard value.isFinite else { return 0 }
        return min(max(value, minExposureTargetOffset), maxExposureTargetOffset)
    }

    func contains(iso: Float, shutterSeconds: Double) -> Bool {
        iso >= minISO && iso <= maxISO
            && shutterSeconds >= minShutterSeconds && shutterSeconds <= maxShutterSeconds
    }
}

// MARK: - Derived HDR badge

/// The HDR badge.
///
/// `docs/ARCHITECTURE.md` section 2.4: there is **no** public API that reports whether
/// the system chose an HDR path for a still, so a live "Smart HDR fired" badge cannot
/// be built. What is public is:
///
/// - `isVideoHDRSupported` on the active format — the hardware's ability;
/// - `isHighPhotoQualitySupported` / `isHighestPhotoQualitySupported` — whether
///   raising `photoQualityPrioritization` actually buys anything;
/// - our own highlight meter on the preview — whether the scene needs it.
///
/// So the badge is derived from those, and it never claims frames we did not merge
/// ourselves.
///
/// **And what is not public is the outcome.** `AVCaptureResolvedPhotoSettings` on this
/// SDK exposes the resolved dimensions and the unique ID, but not the resolved
/// `photoQualityPrioritization` and not the resolved ProRAW flag. So the third state
/// below records that a quality-priority capture was *requested* on a format that
/// supports it, which is the strongest claim public API allows. There is deliberately
/// no "HDR frames" state: the app merges no frames itself, and claiming a count it did
/// not produce is the exact dishonesty this enum exists to prevent.
enum HDRStatus: Equatable, Sendable, CaseIterable {
    /// The active format reports no HDR support at all.
    case unsupported
    /// Hardware can, nothing requested yet.
    case ready
    /// A quality-priority capture was requested on a format that supports it. The
    /// resolution is not observable, so this is a request, not a result.
    case qualityRequested

    var label: String {
        switch self {
        case .unsupported: return "HDR n/a"
        case .ready: return "HDR ready"
        case .qualityRequested: return "HDR requested"
        }
    }

    /// How the badge is drawn: an unavailable capability is muted, not amber. Amber is
    /// reserved for a setting the user asked for and the device refused.
    var isMuted: Bool {
        self == .unsupported
    }

    /// True when a `.quality` request can plausibly be honoured, which is the whole
    /// native-HDR promise of Step 1.
    static func requestedQuality(hasPhotoQualitySupport: Bool) -> Bool {
        hasPhotoQualitySupport
    }
}

// MARK: - Orientation

/// Preview and capture rotation, as a plain mapping so it can be unit tested.
///
/// Uses `videoRotationAngle` rather than the deprecated `videoOrientation`.
enum PreviewRotation {

    /// Degrees clockwise, matching `AVCaptureConnection.videoRotationAngle`.
    ///
    /// The front camera is mirrored, so the landscape angles swap. Getting this wrong
    /// shows up as a preview that is upright in portrait and sideways in landscape,
    /// which is exactly the bug the Step 0 crash log was tracked for.
    static func angle(for orientation: UIDeviceOrientation, facing: CameraFacing) -> CGFloat {
        switch orientation {
        case .portrait: return facing == .front ? 270 : 90
        case .portraitUpsideDown: return facing == .front ? 90 : 270
        case .landscapeLeft: return facing == .front ? 180 : 0
        case .landscapeRight: return facing == .front ? 0 : 180
        default: return facing == .front ? 270 : 90
        }
    }
}
