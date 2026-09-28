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
    /// 35 mm equivalent, which is the only focal length a user can reason about.
    var focalLength35mm: Double
    /// Optical-equivalent steps, present only on devices that report a virtual
    /// multi-camera device. Empty on a single-lens device, which is exactly why the
    /// zoom UI must come from this list and not from a hard-coded `0.5x 1x 2x`.
    var virtualZoomFactors: [Double]
    /// Negative when the device does not report it.
    var minimumFocusDistance: Double
    var flashAvailable: Bool

    static func describe(_ device: AVCaptureDevice) -> BackCameraCapabilities {
        let virtual = device.virtualDeviceSwitchOverVideoZoomFactors.map { Double($0) }
        return BackCameraCapabilities(
            uniqueID: device.uniqueID,
            kind: kind(of: device.deviceType),
            // There is no 35 mm equivalent focal length in the iOS SDK on either the
            // device or its format, so the video field of view of the active format is
            // used instead. It is a measured value, it is on the format, and the zoom
            // labels below are ratios of these so they stay internally consistent.
            focalLength35mm: Self.relativeFocalLength(of: device.activeFormat),
            virtualZoomFactors: virtual.isEmpty ? [] : [1.0] + virtual,
            minimumFocusDistance: Double(device.minimumFocusDistance),
            flashAvailable: device.isFlashAvailable
        )
    }

    /// The format's diagonal field of view in millimetres of 35 mm film, which is a
    /// stand-in for focal length: a wider field of view means a shorter equivalent
    /// length, so lens ordering and zoom ratios both come out right.
    ///
    /// The diagonal, not the horizontal field of view: portrait and landscape capture
    /// would otherwise swap the ordering of the lenses depending on how the phone is
    /// held.
    private static func relativeFocalLength(of format: AVCaptureDevice.Format) -> Double {
        let fov = CMVideoFieldOfView(diagonal: format.formatDescription)
        guard fov.degrees > 0 else { return 0 }
        return 43.2666 / tan(fov.degrees * .pi / 360)
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
            ?? backCameras.filter { $0.kind != .composite }.min { $0.focalLength35mm < $1.focalLength35mm }
            ?? backCameras.first
    }

    /// Zoom chip label for a lens, as a measured ratio against `referenceCamera`.
    ///
    /// `nil` when the ratio cannot be established, in which case the UI shows no chip
    /// rather than a made-up `0.5x`.
    func zoomLabel(for camera: BackCameraCapabilities) -> String? {
        guard let reference = referenceCamera, reference.focalLength35mm > 0 else { return nil }
        let ratio = camera.focalLength35mm / reference.focalLength35mm
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
        if lenses.count > 1 { return .available }
        if lenses.isEmpty { return .unavailable(reason: "No back camera reported") }
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
        let hasSteps = physicalLenses.contains { $0.virtualZoomFactors.count > 1 }
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

    /// Fills in `backCameras` from a discovery result.
    ///
    /// Physical lenses win over composites: an iPhone 11 Pro Max reports its three
    /// lenses *and* a `builtInTripleCamera`, and offering four buttons for three lenses
    /// would be a lie.
    mutating func attachBackCameras(_ devices: [AVCaptureDevice]) {
        let described = devices
            .filter { $0.position == .back }
            .map(BackCameraCapabilities.describe)
        let physical = described.filter { $0.kind != .composite && $0.kind != .unknown }
        backCameras = physical.isEmpty ? described : physical
        backCameras.sort { $0.focalLength35mm < $1.focalLength35mm }
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
/// ourselves. `capturedWithQualityPriority` is the only case where we know the request
/// was honoured, and even then it says quality priority, not "HDR frames".
enum HDRStatus: Equatable, Sendable {
    /// The active format reports no HDR support at all.
    case unsupported
    /// Hardware can, nothing requested yet.
    case ready
    /// We asked for `photoQualityPrioritization = .quality` and AVFoundation confirmed
    /// it came back as `.quality` on the resolved settings.
    case capturedWithQualityPriority

    var label: String {
        switch self {
        case .unsupported: return "HDR n/a"
        case .ready: return "HDR ready"
        case .capturedWithQualityPriority: return "HDR quality"
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
/// Uses `videoRotationAngle` rather than the deprecated `videoOrientation`, which is
/// the API available on the iOS 17 deployment target.
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
