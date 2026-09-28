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
    }

    /// A finished capture, before it is written anywhere.
    struct Capture: Equatable {
        var data: Data
        var container: PhotoContainer
        var metadata: CaptureMetadata
        /// What AVFoundation actually did, used for the log and the HDR badge.
        var resolvedQuality: AVCapturePhotoOutput.QualityPrioritization
        var resolvedProRaw: Bool
    }

    let output = AVCapturePhotoOutput()

    /// `true` from `willBeginCapture` until the result is delivered. Drives the
    /// processing indicator; the shutter itself is never blocked.
    var onProgressChange: ((Bool) -> Void)?
    var onCapture: ((Result<Capture, Error>) -> Void)?

    private var isCapturing = false
    private var pendingMetadata: CaptureMetadata?
    private var pendingRequest: Request?

    // MARK: - Capability driven setup

    /// Chooses the still codec and the ProRAW switch.
    ///
    /// ProRAW is only enabled when the output reports support, because
    /// `isAppleProRAWEnabled = true` on an unsupported output raises
    /// `NSInvalidArgumentException` — the exact failure `LumaFrameSafety` exists for.
    func configureOutput(capabilities: CameraCapabilities) {
        if let codec = Self.preferredCodec(for: output) {
            output.availablePhotoCodecTypes = [codec]
            AppLog.note(AppLog.camera, "photo codec set: \(Self.name(codec))")
        } else {
            AppLog.warn(AppLog.camera, "no preferred photo codec; leaving the output default")
        }

        guard capabilities.proRawSupported else {
            if output.isAppleProRAWEnabled {
                _ = LumaFrameSafety.perform { output.isAppleProRAWEnabled = false }
            }
            return
        }
        if let failure = LumaFrameSafety.perform({ output.isAppleProRAWEnabled = true }) {
            AppLog.warn(AppLog.camera, "ProRAW could not be enabled: \(failure)")
        } else {
            AppLog.note(AppLog.camera, "ProRAW enabled")
        }
    }

    /// HEVC when offered, because it is the only codec here that carries Display P3 and
    /// HDR gain maps, and this is a low-light app that cares about both. HEIF second,
    /// JPEG last.
    ///
    /// `nil` means the output has no usable codec, which is a hard failure at capture
    /// time rather than a silent drop to something lossier than what was asked for.
    nonisolated static func preferredCodec(for output: AVCapturePhotoOutput) -> AVVideoCodecType? {
        let available = output.availablePhotoCodecTypes
        for candidate in [AVVideoCodecType.hevc, .heif, .jpeg] where available.contains(candidate) {
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
        guard let codec = Self.preferredCodec(for: output) else {
            fail(Failure.noCodec)
            return
        }
        guard output.isReadyForPhotoCapture else {
            // Not an error state to hide, and not a failure to blame on the user: the
            // sensor is still settling. Saying so beats pretending a capture happened.
            AppLog.warn(AppLog.camera, "shutter ignored: output not ready for capture")
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
        pendingMetadata = metadata
        pendingRequest = request

        // The file records the **request**, because that is all that exists at the moment
        // the settings are built. AVFoundation resolves quality and ProRAW afterwards and
        // the resolution lands in the log and in the badge, not retroactively in the file.
        metadata.photoQualityPrioritization = request.preferQuality ? "quality" : "balanced"
        metadata.proRaw = request.proRaw
        metadata.raw = request.raw

        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
        settings.photoQualityPrioritization = request.preferQuality ? .quality : .balanced
        settings.isFlashEnabled = request.flash == .on && output.supportedFlashModes.contains(.on)
        if request.proRaw { settings.isAppleProRAWEnabled = true }
        if request.raw, let raw = Self.rawPixelType(for: output, proRaw: request.proRaw) {
            settings.rawPixelFormatType = raw
        }
        // The recipe travels with the file. AVFoundation merges this into the image
        // metadata it writes, which is what makes a capture re-renderable in step 9
        // without the original having been altered.
        settings.metadata = metadata.dictionary()

        AppLog.note(AppLog.camera,
                    "capture requested: codec=\(Self.name(codec)) "
                    + "quality=\(request.preferQuality ? "quality" : "balanced") "
                    + "flash=\(settings.isFlashEnabled ? "on" : "off") raw=\(request.raw) "
                    + "proRAW=\(request.proRaw) mode=\(metadata.mode)")

        // `onCapture` is the single result channel, so a rejected press reports through
        // exactly the same path as a finished one and the UI has one code path.
        onProgressChange?(true)
        output.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Result plumbing

    /// Rejects a press before the session is entered, so `onProgressChange` never has to
    /// be balanced for a capture that never started.
    private func fail(_ failure: Failure) {
        AppLog.fail(AppLog.camera, "capture rejected: \(failure.localizedDescription ?? "unknown")")
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
                         resolvedQuality: AVCapturePhotoOutput.QualityPrioritization,
                         resolvedProRaw: Bool,
                         dimensions: CMVideoDimensions) {
        var metadata = pendingMetadata ?? CaptureMetadata(mode: "auto")
        // Record what actually happened, not what was asked for. The badge reads this,
        // and the mismatch against the request is logged rather than hidden.
        metadata.photoQualityPrioritization = resolvedQuality == .quality ? "quality" : "balanced"
        metadata.proRaw = resolvedProRaw
        metadata.pixelWidth = dimensions.width
        metadata.pixelHeight = dimensions.height
        metadata.container = container.rawValue
        if let request = pendingRequest {
            if request.proRaw != resolvedProRaw {
                AppLog.warn(AppLog.camera, "ProRAW request \(request.proRaw) resolved to \(resolvedProRaw)")
            }
            if (request.preferQuality ? "quality" : "balanced") != metadata.photoQualityPrioritization {
                AppLog.warn(AppLog.camera,
                            "quality request \(request.preferQuality) resolved to \(metadata.photoQualityPrioritization)")
            }
        }
        finish(.success(Capture(data: data,
                                container: container,
                                metadata: metadata,
                                resolvedQuality: resolvedQuality,
                                resolvedProRaw: resolvedProRaw)))
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

        let resolved = photo.resolvedSettings
        AppLog.note(AppLog.camera,
                    "capture resolved: \(resolved.photoDimensions.width)x\(resolved.photoDimensions.height) "
                    + "quality=\(resolved.photoQualityPrioritization == .quality ? "quality" : "balanced") "
                    + "proRAW=\(resolved.isAppleProRAWEnabled) "
                    + "bytes=\(data.count) container=\(container.rawValue)")

        Task { @MainActor [weak self] in
            self?.deliver(data: data,
                          container: container,
                          resolvedQuality: resolved.photoQualityPrioritization,
                          resolvedProRaw: resolved.isAppleProRAWEnabled,
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
        let all = output.availableRawPhotoPixelFormatTypes.map(\.ostValue)
        let types = proRaw ? all.filter { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } : all
        guard let first = types.first else { return nil }
        AppLog.note(AppLog.camera,
                    "RAW pixel types (proRAW=\(proRaw)): "
                    + "\(types.map { ReportFormat.fourCC($0) }.joined(separator: ", "))")
        AppLog.note(AppLog.camera, "RAW pixel type chosen: \(ReportFormat.fourCC(first))")
        return first
    }

    nonisolated static func name(_ codec: AVVideoCodecType) -> String {
        switch codec {
        case .hevc: return "hevc"
        case .heif: return "heif"
        case .jpeg: return "jpeg"
        default: return codec.rawValue
        }
    }
}
