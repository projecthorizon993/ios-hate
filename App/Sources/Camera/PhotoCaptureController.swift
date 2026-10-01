import AVFoundation
import Foundation

/// Owns the `AVCapturePhotoOutput` and turns a shutter press into a file on disk.
///
/// This is the only place in Step 1 that touches photo settings, which is deliberate:
/// `photoQualityPrioritization` is the whole native-HDR story for stills, and it has to
/// be a per-decision, logged value rather than a constant.
@MainActor
final class PhotoCaptureController: NSObject {

    enum Failure: LocalizedError, Equatable {
        case notRunning
        case alreadyCapturing
        case noCodec
        case rawUnsupported
        case proRawUnsupported
        case notReady
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: return "The camera is not running"
            case .alreadyCapturing: return "A capture is already in progress"
            case .noCodec: return "This camera offers no photo codec the app can request"
            case .rawUnsupported: return "This camera has no RAW output"
            case .proRawUnsupported: return "Apple ProRAW is not supported on this device"
            case .notReady: return "The sensor is still settling — try again"
            case .failed(let reason): return reason
            }
        }
    }

    /// What the user asked for. Never the same thing as what the device did — the
    /// resolved settings come back from AVFoundation and the log records both.
    struct Request: Equatable {
        var raw = false
        var proRaw = false
        var flash: AVCaptureDevice.FlashMode = .off
        /// Set only when the active format reports high photo quality. Requesting
        /// `.quality` where it is unsupported is silently downgraded, so the app decides
        /// explicitly and logs the decision.
        var preferQuality = false
        /// Set when the user has dialled in a manual ISO, shutter or exposure lock.
        ///
        /// Decides `photoQualityPrioritization`, and it is the opposite of `preferQuality`.
        /// Apple documents that `.balanced` — the default — *allows photo capture to
        /// temporarily override the capture device's exposure duration and ISO if the
        /// scene is dark enough to require multi-image fusion*, so `.balanced` silently
        /// discards a manual exposure in exactly the low light where a manual camera is
        /// being used on purpose. `.speed` honours the values and gives up the fusion.
        ///
        /// A capture is either Auto or manual, so the two flags are never both meaningful;
        /// if they somehow are, manual wins, because losing a look the user chose is worse
        /// than losing an HDR badge.
        var manualExposureActive = false
    }

    /// The prioritisation a request resolves to, in one place.
    ///
    /// Manual wins over quality when both are set: losing a look the user chose is worse
    /// than losing an HDR badge, and the user can turn the manual value off.
    ///
    /// The enum is `AVCapturePhotoOutput.QualityPrioritization` even though the property
    /// being set is on `AVCapturePhotoSettings`. It was spelled the intuitive way —
    /// `AVCapturePhotoSettings.QualityPrioritization` — and that does not exist, so the
    /// file did not compile. The property and its type living on different types is the
    /// second instance of the same mistake as `isAppleProRAWSupported`; see
    /// `docs/HANDOFF.md` section 8.
    static func prioritization(for request: Request) -> AVCapturePhotoOutput.QualityPrioritization {
        if request.manualExposureActive { return .speed }
        if request.preferQuality { return .quality }
        return .balanced
    }

    /// The same string the recipe records, so the file and the request cannot disagree.
    static func name(for prioritization: AVCapturePhotoOutput.QualityPrioritization) -> String {
        switch prioritization {
        case .speed: return "speed"
        case .quality: return "quality"
        case .balanced: return "balanced"
        @unknown default: return "unknown"
        }
    }

    /// A finished capture, before it is written anywhere.
    struct Capture: Equatable {
        var data: Data
        var container: PhotoContainer
        var metadata: CaptureMetadata
        /// Measured, not requested: `AVCapturePhoto.isRawPhoto` is the one resolution
        /// signal AVFoundation actually exposes here.
        var isRawPhoto: Bool
    }

    /// The one and only photo output. The session is given **this** instance rather than
    /// making its own — see `CaptureSessionController.configure(facing:photoOutput:...)`
    /// for what happened when there were two.
    let output = AVCapturePhotoOutput()

    /// `true` from `willBeginCapture` until the result is delivered. Drives the
    /// processing indicator; the shutter itself is never blocked.
    var onProgressChange: ((Bool) -> Void)?
    var onCapture: ((Result<Capture, Error>) -> Void)?

    private var isCapturing = false
    private var pendingMetadata: CaptureMetadata?
    private var pendingRequest: Request?

    // MARK: - Capability driven setup

    /// Records what the output can deliver and sets the ProRAW switch.
    ///
    /// ProRAW is only enabled when the output reports support, because
    /// `isAppleProRAWEnabled = true` on an unsupported output raises
    /// `NSInvalidArgumentException` — the exact failure `LumaFrameSafety` exists for.
    func configureOutput(capabilities: CameraCapabilities) {
        let available = output.availablePhotoCodecTypes
        let codecText = available.map { "\($0.rawValue)" }.joined(separator: ", ")
        AppLog.note(AppLog.camera, "photo codecs available: \(codecText)")
        AppLog.note(AppLog.camera, "photo codec will be: \(Self.preferredCodec(for: output)?.rawValue ?? "output default")")

        // RAW and ProRAW availability, next to the flag it depends on.
        //
        // `isAppleProRAWSupported` and `availableRawPhotoPixelFormatTypes` are properties of
        // the **output in its current configuration**, and that configuration includes the
        // active *format*. An iPhone 11 Pro reported `raw=0 proRAW=false` until the format
        // changed — not because the hardware lacks RAW, which it does not, but because the
        // bound format did not report `isHighPhotoQualitySupported`. So the hardware answer
        // and the reason it disagrees are logged together; without the second half, a
        // `proRAW=false` line is indistinguishable from a device that has no RAW at all.
        AppLog.note(AppLog.camera,
                    "raw types: \(output.availableRawPhotoPixelFormatTypes.count), "
                    + "proRAW: \(output.isAppleProRAWSupported), "
                    + "format high photo quality: \(capabilities.photoQualitySupported)")

        guard capabilities.proRawSupported else {
            if output.isAppleProRAWEnabled {
                _ = LumaFrameSafety.perform({ self.output.isAppleProRAWEnabled = false })
            }
            return
        }
        if let failure = LumaFrameSafety.perform({ self.output.isAppleProRAWEnabled = true }) {
            AppLog.warn(AppLog.camera, "ProRAW could not be enabled: \(failure)")
        } else {
            AppLog.note(AppLog.camera, "ProRAW enabled")
        }
    }

    /// The codec to ask for, and **JPEG first**.
    ///
    /// It used to prefer `.hevc`, on the grounds that HEVC is the only still codec here
    /// that carries Display P3 and an HDR gain map, and this is a low-light app that cares
    /// about both. That reasoning was sound and the priority was backwards: on a device
    /// offering both — an iPhone 11 Pro offers `jpeg, hvc1` — every photo was captured as
    /// HEVC. Nothing was broken; the log shows `photo stored: heic 4032x3024` and the file
    /// is a valid HEIC. But HEIC is a container plenty of things outside this app do not
    /// handle, so a photo the user cannot open anywhere is a poor default for a camera
    /// whose whole job is producing pictures. Wide gamut is carried by the recipe and the
    /// working colour space, not by the container.
    ///
    /// Only `.jpeg` and `.hevc` are tested. `AVVideoCodecType` has no `.heif` case —
    /// naming one silently resolves it against `UTType` instead and produces a type error
    /// that points nowhere near the real mistake.
    ///
    /// This is `preferredCodec`, not `PhotoContainer.detect` — detection stays general,
    /// because a photo can still arrive as HEIC from a RAW pipeline or a future codec
    /// change, and refusing to open it would be worse than opening it.
    nonisolated static func preferredCodec(for output: AVCapturePhotoOutput) -> AVVideoCodecType? {
        preferredCodec(in: output.availablePhotoCodecTypes)
    }

    /// The preference order, separated from the output so it can be asserted without one.
    nonisolated static func preferredCodec(in available: [AVVideoCodecType]) -> AVVideoCodecType? {
        for candidate in [AVVideoCodecType.jpeg, .hevc] where available.contains(candidate) {
            return candidate
        }
        return available.first
    }

    // MARK: - Capture

    func capture(metadata: CaptureMetadata, request: Request) {
        guard !isCapturing else {
            fail(Failure.alreadyCapturing)
            return
        }
        guard !output.availablePhotoCodecTypes.isEmpty else {
            fail(Failure.noCodec)
            return
        }
        // `captureReadiness` is the supported readiness signal. `isReadyForPhotoCapture`
        // does not exist on this type.
        guard output.captureReadiness == .ready else {
            // Not an error state to hide, and not a failure to blame on the user: the
            // sensor is still settling. Saying so beats pretending a capture happened.
            AppLog.warn(AppLog.camera, "shutter ignored: capture readiness is \(output.captureReadiness.rawValue)")
            fail(Failure.notReady)
            return
        }

        if request.proRaw && !output.isAppleProRAWSupported {
            fail(Failure.proRawUnsupported)
            return
        }
        if request.raw, Self.rawPixelType(for: output, proRaw: request.proRaw) == nil {
            fail(Failure.rawUnsupported)
            return
        }

        isCapturing = true

        // The file records the **request**, because that is all that exists at the moment
        // the settings are built. AVFoundation resolves quality afterwards and the
        // resolution lands in the log, not retroactively in the file.
        //
        // The prioritisation is decided once, here, and both the metadata and the settings
        // read it. Deciding it twice is how the two drift: the first version of this set
        // `.speed` on the settings and wrote `"balanced"` into the recipe, so every manual
        // capture's own file would have said the opposite of what was done to it.
        let prioritization = Self.prioritization(for: request)

        var recorded = metadata
        recorded.photoQualityPrioritization = Self.name(for: prioritization)
        recorded.proRaw = request.proRaw
        recorded.raw = request.raw
        pendingMetadata = recorded
        pendingRequest = request

        let codec = Self.preferredCodec(for: output) ?? AVVideoCodecType.jpeg
        // RAW capture needs the dedicated initialiser; there is no
        // `rawPixelFormatType` property to assign on a plain settings object.
        let settings: AVCapturePhotoSettings
        if request.raw, let raw = Self.rawPixelType(for: output, proRaw: request.proRaw) {
            settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
        }
        // Three modes, not two, and the middle one is the bug this replaces.
        //
        // - manual:  `.speed` — honour the user's ISO and shutter, give up multi-frame
        // - quality: `.quality` — native HDR for stills, where the format supports it
        // - neither: `.balanced`, the default
        //
        // The old code had two cases, quality or balanced, which meant every capture on a
        // format with photo-quality support asked for `.balanced` and therefore let the
        // system override a manual exposure.
        settings.photoQualityPrioritization = prioritization
        if request.manualExposureActive && request.preferQuality {
            AppLog.note(AppLog.camera,
                        "manual exposure overrides quality prioritisation; "
                        + "multi-frame fusion is unavailable in this capture")
        }

        let wantsFlash = request.flash == .on && output.supportedFlashModes.contains(.on)
        settings.flashMode = wantsFlash ? .on : .off
        // There is no per-settings ProRAW switch: ProRAW is a property of the output,
        // already set in `configureOutput` from the reported capability.

        // The recipe travels with the file. AVFoundation merges this into the image
        // metadata it writes, which is what makes a capture re-renderable in step 9
        // without the original having been altered.
        settings.metadata = recorded.dictionary()

        // Read the same value the settings were given and the recipe records. Deriving it
        // again here meant a manual capture logged `quality=balanced` while being captured
        // at `.speed` — and this is the line someone reads to find out what a photo was.
        let quality = recorded.photoQualityPrioritization
        let flash = wantsFlash ? "on" : "off"
        AppLog.note(AppLog.camera,
                    "capture requested: codec=\(codec.rawValue) quality=\(quality) flash=\(flash) "
                    + "raw=\(request.raw) proRAW=\(request.proRaw) mode=\(recorded.mode)")

        // `onCapture` is the single result channel, so a rejected press reports through
        // exactly the same path as a finished one and the UI has one code path.
        onProgressChange?(true)
        output.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Result plumbing

    /// Rejects a press before the session is entered, so `onProgressChange` never has to
    /// be balanced for a capture that never started.
    private func fail(_ failure: Failure) {
        AppLog.fail(AppLog.camera, "capture rejected: \(failure.localizedDescription)")
        onCapture?(.failure(failure))
    }

    private func finish(_ result: Result<Capture, Error>) {
        isCapturing = false
        pendingMetadata = nil
        pendingRequest = nil
        onProgressChange?(false)
        switch result {
        case .success(let capture):
            AppLog.note(AppLog.camera, "capture delivered: \(capture.metadata.summariseForLog)")
            onCapture?(.success(capture))
        case .failure(let error):
            AppLog.fail(AppLog.camera, "capture failed: \(error.localizedDescription)")
            onCapture?(.failure(error))
        }
    }

    @MainActor
    private func deliver(data: Data,
                         container: PhotoContainer,
                         isRawPhoto: Bool,
                         dimensions: CMVideoDimensions) {
        var recorded = pendingMetadata ?? CaptureMetadata(mode: "auto")
        recorded.pixelWidth = Int(dimensions.width)
        recorded.pixelHeight = Int(dimensions.height)
        recorded.container = container.rawValue
        // `photo.isRawPhoto` is the one resolution signal AVFoundation actually exposes,
        // so it is recorded as measured. Quality prioritisation is **not** readable back
        // from `AVCaptureResolvedPhotoSettings` on this SDK, so the file keeps the value
        // that was requested and the badge is worded as a request, not a result.
        if let request = pendingRequest, request.raw != isRawPhoto {
            AppLog.warn(AppLog.camera, "RAW request \(request.raw) produced isRawPhoto=\(isRawPhoto)")
        }
        finish(.success(Capture(data: data,
                                container: container,
                                metadata: recorded,
                                isRawPhoto: isRawPhoto)))
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension PhotoCaptureController: AVCapturePhotoCaptureDelegate {

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        AppLog.note(AppLog.camera, "willBeginCapture")
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        if let error {
            AppLog.fail(AppLog.camera, "photo processing failed: \(error.localizedDescription)")
            Task { @MainActor [weak self] in
                self?.finish(.failure(error))
            }
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            AppLog.fail(AppLog.camera, "photo produced no file data representation")
            Task { @MainActor [weak self] in
                self?.finish(.failure(Failure.failed("The photo produced no data")))
            }
            return
        }
        guard let container = PhotoContainer.detect(from: data) else {
            AppLog.fail(AppLog.camera, "photo container not recognised from leading bytes")
            Task { @MainActor [weak self] in
                self?.finish(.failure(Failure.failed("Unrecognised photo format")))
            }
            return
        }

        // `AVCaptureResolvedPhotoSettings` exposes the resolved dimensions and the
        // unique ID, but **not** `photoQualityPrioritization` or `isAppleProRAWEnabled`
        // on this SDK. The raw flag is readable from the photo itself, so that is what
        // is logged; the quality priority is a request that cannot be confirmed, and
        // `HDRStatus` is worded accordingly.
        let resolved = photo.resolvedSettings
        let width = Int(resolved.photoDimensions.width)
        let height = Int(resolved.photoDimensions.height)
        AppLog.note(AppLog.camera,
                    "capture resolved: \(width)x\(height) raw=\(photo.isRawPhoto) "
                    + "bytes=\(data.count) container=\(container.rawValue) id=\(resolved.uniqueID)")

        Task { @MainActor [weak self] in
            self?.deliver(data: data,
                          container: container,
                          isRawPhoto: photo.isRawPhoto,
                          dimensions: resolved.photoDimensions)
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                                 error: Error?) {
        // A capture can be reported as finished *after* the image was processed, and a
        // RAW write failure arrives here rather than in the processing callback. The
        // processed image is the user's either way, so this only logs.
        if let error {
            AppLog.warn(AppLog.camera, "didFinishCaptureFor reported: \(error.localizedDescription)")
        }
    }
}

// MARK: - RAW selection

extension PhotoCaptureController {

    /// Which RAW pixel type to request.
    ///
    /// There is one list of RAW pixel types, `availableRawPhotoPixelFormatTypes`, and
    /// ProRAW is selected *out of it* with `isAppleProRAWPixelFormat(_:)`. There is no
    /// separate `availableAppleProRAWPhotoPixelTypes`, and Apple publishes no ordering
    /// or bit-depth contract for these values, so the **first** entry is used and the
    /// whole list is logged so the capability report shows what the device actually
    /// offers. A documented preference can be added in step 4 once the real codes have
    /// been seen on all three devices.
    nonisolated static func rawPixelType(for output: AVCapturePhotoOutput, proRaw: Bool) -> OSType? {
        let all = output.availableRawPhotoPixelFormatTypes
        let types = proRaw ? all.filter { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } : all
        guard let first = types.first else { return nil }
        AppLog.note(AppLog.camera,
                    "RAW pixel types (proRAW=\(proRaw)): "
                    + "\(types.map { ReportFormat.fourCC($0) }.joined(separator: ", "))")
        AppLog.note(AppLog.camera, "RAW pixel type chosen: \(ReportFormat.fourCC(first))")
        return first
    }
}
