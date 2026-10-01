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

        /// The name shown to the user and written into a photo's metadata.
        ///
        /// Present because the user asked what sensor a photo came from and the app had no
        /// answer. It is the *type* of lens, read from `deviceType` at runtime — never a
        /// device name, marketing name or `hw.machine`, all of which are barred by rule 6 of
        /// `docs/HANDOFF.md` precisely because they cannot be tested against.
        var zoomLabel: String {
            switch self {
            case .ultraWide: return "Ultra wide"
            case .wide: return "Wide"
            case .telephoto: return "Telephoto"
            case .composite: return "Multi-lens"
            case .unknown: return "Unknown"
            }
        }
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
    /// different physical lens, so it is what the zoom chips and the active-lens readout are
    /// built from. Observed on an iPhone 11 Pro: `[2.0]` and `[2.0, 4.0]` on the composite
    /// devices, empty on each physical lens.
    var switchOverZoomFactors: [Double] = []
    /// `device.minAvailableVideoZoomFactor`.
    ///
    /// A property of the **active format**, so it is captured at discovery rather than read
    /// at press time. `1.0` on every format of an iPhone 11 Pro, which is why there is no
    /// 0.5x stop on that device: the ultra wide is not reachable by zoom there.
    var minAvailableVideoZoomFactor: Double = 1

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
                .map { Double($0.doubleValue) },
            minAvailableVideoZoomFactor: device.minAvailableVideoZoomFactor
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
    /// degenerate, but it must never be used to label one. `zoomStops` and
    /// `plan.activeLens(atZoomFactor:)` are what the UI reads instead.
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

    /// The zoom factors at which a lens can actually be selected, in reach order.
    ///
    /// Built from `bound.switchOverZoomFactors`, which is
    /// `AVCaptureDevice.virtualDeviceSwitchOverVideoZoomFactors` — the only documented way
    /// iOS offers to learn where a composite hands over to a different physical lens. On an
    /// iPhone 11 Pro it reports `[2.0]` and `[2.0, 4.0]`, so 1x, 2x and 4x are real
    /// switch points. **1.0 is always included**: it is the wide lens and the destination
    /// every other stop is measured from.
    ///
    /// This replaces deriving zoom labels from still resolution, which produced three chips
    /// reading "1x" on a device that switches lenses perfectly well. Observed on that phone:
    /// six devices, every `relativeScale` identically 3168.0, because the lenses share a
    /// sensor resolution and the virtual devices report a shared default `activeFormat`.
    /// See `relativeScale(of:)` for why that measurement cannot work.
    ///
    /// **There is no 0.5x here, and that is correct rather than missing.** The same device
    /// reported `minAvailableVideoZoomFactor == 1.0` on every one of its formats, so the
    /// ultra wide is not reachable by zoom at all on this hardware. A 0.5x chip would be a
    /// control that cannot do anything.
    var zoomStops: [ZoomStop] {
        var factors: [Double] = [1.0]
        factors.append(contentsOf: (bound?.switchOverZoomFactors ?? []).filter { $0 > 1.0 })
        // De-duplicated because a device can report the same point twice, and sorted so the
        // chips read shortest-reach first.
        return Array(Set(factors))
            .sorted { $0 < $1 }
            .map { ZoomStop(factor: $0, kind: activeLens(atZoomFactor: $0)) }
    }

    /// The physical lenses behind the bound composite, shortest reach first.
    ///
    /// Ordered by `Kind`, **not** by `relativeScale`. The scale is unusable — every lens on
    /// a modern iPhone reports the same still dimensions — but `Kind` is a semantic
    /// ordering of lens types (ultra wide, then wide, then telephoto), which is a fact
    /// about what a lens *is* rather than a measurement, and it is all that is needed to
    /// pair lenses with switch points.
    var constituentOrder: [BackCameraCapabilities.Kind] {
        let rank: [BackCameraCapabilities.Kind: Int] = [
            .ultraWide: 0, .wide: 1, .telephoto: 2
        ]
        return offeredLenses
            .filter { $0.kind != .composite && $0.kind != .unknown }
            .sorted { (rank[$0.kind] ?? 99) < (rank[$1.kind] ?? 99) }
            .map(\.kind)
    }

    /// Which physical lens the bound device is using at `zoomFactor`.
    ///
    /// iOS never says this directly, so it is read off the switch points: they partition
    /// the zoom range into one band per lens, and the band the current factor falls in is
    /// the lens in use. On an iPhone 11 Pro — constituents ultra wide, wide, telephoto, and
    /// switch points 2.0 and 4.0 — the bands are 1.0–2.0 wide, 2.0–4.0 telephoto, and 4.0
    /// and above still telephoto, with anything below 1.0 the ultra wide.
    ///
    /// **`nil` when the arithmetic does not line up**, rather than a guess. Three
    /// constituents need exactly two switch points; if the device reports a different
    /// number, this returns `nil` and the UI says it does not know, because a name in a
    /// photo's metadata that is a plausible fabrication is worse than no name. That is the
    /// same reason `relativeScale` is not used to label anything.
    func activeLens(atZoomFactor zoomFactor: Double) -> BackCameraCapabilities.Kind? {
        let lenses = constituentOrder
        let points = (bound?.switchOverZoomFactors ?? []).filter { $0 > 0 }.sorted()
        guard lenses.count >= 2, points.count == lenses.count - 1 else { return nil }
        // Below the first point is the shortest lens, when the range extends that far.
        if let lowest = belowOneXMinimum, zoomFactor < lowest, let first = lenses.first {
            return first
        }
        // Otherwise find the last switch point the factor is at or above; that index is the
        // lens in use. Clamped to the last lens so a factor beyond the final point does not
        // run off the end.
        var index = 0
        for (offset, point) in points.enumerated() where zoomFactor >= point {
            index = offset + 1
        }
        return index < lenses.count ? lenses[index] : lenses.last
    }

    /// The lowest zoom factor the bound device will accept, or `nil` when it reports none
    /// below 1.0.
    ///
    /// Recorded on the device rather than read at press time, because
    /// `minAvailableVideoZoomFactor` is a property of the **active format** and this is
    /// captured at discovery. On an iPhone 11 Pro it came back as exactly 1.0 on every
    /// format, which is why no 0.5x stop exists: the ultra wide is not reachable by zoom
    /// on that hardware, and a 0.5x chip there would be a control that does nothing.
    var belowOneXMinimum: Double? {
        guard let minimum = bound?.minAvailableVideoZoomFactor, minimum < 1.0 else { return nil }
        return minimum
    }

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

/// One selectable sensor, and the label it gets.
///
/// A stop is a **zoom factor the device reported**, not a focal length the app guessed. On a
/// multi-lens phone the physical lenses sit behind one `AVCaptureDevice` and iOS hands over
/// between them at the reported switch points, so setting the factor *is* selecting a
/// sensor — the two are the same mechanism.
///
/// That is why the chip reads as a sensor name and the factor is secondary. "Telephoto" is
/// what the user is choosing; "2x" is the number that achieves it. Presenting it the other
/// way round makes the user do arithmetic, and it hides the thing they actually care about.
struct ZoomStop: Hashable, Sendable, Identifiable {
    var factor: Double
    /// The sensor this factor selects, when the switch points can be resolved to one.
    /// `nil` rather than a name when the bands do not line up — see `activeLens`.
    var kind: BackCameraCapabilities.Kind?
    var id: Double { factor }

    /// The chip text: the sensor name.
    ///
    /// Falls back to the factor when the sensor is unknown, because a chip that says
    /// something is better than a blank one, and the factor is at least true.
    var label: String {
        kind?.zoomLabel ?? factorLabel
    }

    /// The factor on its own, for the readout and accessibility.
    var factorLabel: String {
        if abs(factor - factor.rounded()) < 0.001 {
            return "\(Int(factor.rounded()))x"
        }
        return String(format: "%.1fx", factor)
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

    /// Zoom chip label for a lens, as a ratio against `referenceCamera`.
    ///
    /// **No longer used.** Kept only because `referenceCamera` still has a caller, and
    /// deleting a public helper on a struct this size is a separate piece of work. Nothing
    /// in the app labels a lens from this any more: the zoom chips come from the device's
    /// reported switch-over factors, and the active-lens readout comes from the bands those
    /// factors define. `relativeScale` returned one constant for every lens on an iPhone 11
    /// Pro, so this computes `1.0` for all three — which is the "1 1 1" the user saw.
    ///
    /// If a future caller reaches for this, it will produce meaningless labels. Use
    /// `zoomStops` or `plan.activeLens(atZoomFactor:)` instead.
    func zoomLabel(for camera: BackCameraCapabilities) -> String? {
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

    /// Whether the app can offer a lens selector at all.
    ///
    /// Now driven by whether the **bound device reported switch-over factors**, not by
    /// whether its lenses can be told apart by still resolution. Those are different
    /// questions and only the first one is about switching: an iPhone 11 Pro reports the
    /// same still dimensions for all three lenses and yet switches perfectly well, at
    /// 2x and 4x. Hiding the selector because the labels were unmeasurable threw away a
    /// working feature.
    ///
    /// Fewer than two stops means there is nothing to switch between, which is the honest
    /// reason to hide it — a single lens, or a device that reports no switch points.
    var lensSelector: FeatureAvailability {
        let stops = plan.zoomStops
        if physicalLenses.isEmpty && stops.count < 2 {
            return .unavailable(reason: "No back camera reported")
        }
        if stops.count > 1 { return .available }
        if physicalLenses.count == 1 {
            return .unavailable(reason: "Single camera — no lens switching")
        }
        // Constituents were found but the bound device reported no switch points, so there
        // is no way to reach any lens other than the wide one. Not a label problem this
        // time — a real absence of reachable positions.
        return .unavailable(reason: "Camera reports no reachable lens positions")
    }

    /// The chips to draw, or empty when there is nothing to switch between.
    var zoomStops: [ZoomStop] {
        plan.zoomStops.count > 1 ? plan.zoomStops : []
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
