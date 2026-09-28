import AVFoundation
import Foundation
import UIKit

/// The mode switcher. Step 1 ships Auto only, and the other two entries stay visible
/// but disabled: they are part of the shipped design, and `docs/DESIGN_SPEC.md` requires
/// the chrome not to move when a mode is added.
enum CameraMode: String, CaseIterable, Equatable {
    case auto
    case pro
    case looks

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .pro: return "Pro"
        case .looks: return "Looks"
        }
    }

    /// Step 1 implements Auto. Pro is Step 4 and Looks is Step 3, so both report why
    /// they are unavailable rather than pretending to be switchable.
    var isImplemented: Bool { self == .auto }
}

/// Everything the camera screen renders, in one observable object.
///
/// Owns the session, the photo output and the preview meter, and is the only place that
/// decides what the user is allowed to do. Views read; they do not touch AVFoundation.
@MainActor
final class CameraViewModel: ObservableObject {

    /// Live capture parameters, exactly as the device reports them.
    struct Readout: Equatable {
        var iso: Float = 0
        var shutterSeconds: Double = 0
        var exposureTargetOffset: Float = 0
        var zoomFactor: CGFloat = 1
        var lensLabel: String?
        var relativeScale: Double?
    }

    /// A transient message. Not an alert — the camera screen must never put a modal over
    /// the viewfinder while composing.
    @Published private(set) var banner: String?
    @Published private(set) var isBannerError = false

    @Published private(set) var sessionState: CaptureSessionController.State = .idle
    @Published private(set) var capabilities: CameraCapabilities = .unknown
    @Published private(set) var exposureRange: ExposureRange?
    @Published private(set) var hdr: HDRStatus = .unsupported
    @Published private(set) var readout = Readout()
    @Published private(set) var sample: PreviewMeter.Sample?
    @Published private(set) var isCapturing = false
    @Published private(set) var mode: CameraMode = .auto
    @Published private(set) var facing: CameraFacing = .back
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var latestPhoto: SavedPhoto?
    @Published private(set) var storedBytes: Int64?
    @Published private(set) var canFlip = false
    @Published var showDebugOverlay = false

    /// Flash is `off` / `on` only. `AVCapturePhotoSettings` has no auto flash, so an
    /// "Auto" option here would be a control that silently does nothing.
    @Published private(set) var flashMode: AVCaptureDevice.FlashMode = .off

    private let sessionController = CaptureSessionController()
    private let photo = PhotoCaptureController()
    private let meter = PreviewMeter()

    /// The photo output, exposed only so the session can attach it.
    var captureSession: AVCaptureSession { sessionController.session }

    private var readoutTimer: Timer?
    private var hasConfigured = false

    // MARK: - Lifecycle

    init() {
        sessionController.onStateChange = { [weak self] state in
            guard let self else { return }
            self.sessionState = state
            if case .failed(let reason) = state {
                self.present(reason, isError: true)
            }
        }
        photo.onProgressChange = { [weak self] isCapturing in
            self?.isCapturing = isCapturing
        }
        photo.onCapture = { [weak self] result in
            self?.handle(result)
        }
        meter.onSample = { [weak self] sample in
            self?.sample = sample
        }
    }

    /// Configures the session and starts the meter. Safe to call more than once: only
    /// the first call configures, later ones just restart.
    func start() {
        canFlip = CaptureSessionController.hasDevice(facing: .back)
            && CaptureSessionController.hasDevice(facing: .front)
        guard !hasConfigured else { return }
        hasConfigured = true
        AppLog.note(AppLog.camera, "camera screen start, facing=\(facing.rawValue)")

        var capabilities = CameraCapabilities.unknown
        capabilities.attachBackCameras(CaptureSessionController.discoverBackCameras())
        self.capabilities = capabilities

        sessionController.configure(facing: facing, extraOutputs: [photo.output, meter.output]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let configuration):
                self.finishConfiguration(configuration)
            case .failure(let error):
                self.present(error.localizedDescription, isError: true)
            }
        }
    }

    func stop() {
        readoutTimer?.invalidate()
        readoutTimer = nil
        sessionController.tearDown()
    }

    private func finishConfiguration(_ configuration: CaptureSessionController.Configuration) {
        exposureRange = configuration.exposureRange
        facing = configuration.facing
        hdr = configuration.format.isVideoHDRSupported ? .ready : .unsupported

        var probed = CameraCapabilities.probe(device: configuration.device,
                                              format: configuration.format,
                                              photoOutput: photo.output)
        probed.facing = configuration.facing
        probed.attachBackCameras(CaptureSessionController.discoverBackCameras())
        capabilities = probed

        photo.configureOutput(capabilities: probed)
        startReadout()
        storedBytes = PhotoStore.totalBytes()

        AppLog.note(AppLog.camera,
                    "camera ready: facing=\(configuration.facing.rawValue) "
                    + "lenses=\(probed.physicalLenses.count) "
                    + "flash=\(probed.flash.isAvailable) "
                    + "hdr=\(self.hdr.label)")
    }

    // MARK: - Readout

    /// The device meters itself in Auto mode, so the numbers are polled rather than
    /// pushed. 2 Hz is fast enough to feel live and slow enough to be free.
    private func startReadout() {
        readoutTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshReadout() }
        }
        RunLoop.main.add(timer, forMode: .common)
        readoutTimer = timer
        refreshReadout()
    }

    private func refreshReadout() {
        guard let device = sessionController.configuration?.device, sessionState == .running else { return }
        var value = Readout()
        value.iso = device.iso
        value.shutterSeconds = CMTimeGetSeconds(device.exposureDuration)
        value.exposureTargetOffset = device.exposureTargetOffset
        value.zoomFactor = device.videoZoomFactor
        value.relativeScale = BackCameraCapabilities.describe(device).relativeScale
        let active = activeCamera(relativeScale: value.relativeScale)
        value.lensLabel = active.flatMap { capabilities.zoomLabel(for: $0) }
        readout = value
    }

    /// Closest reported lens to the reach the device is actually running at. The
    /// device may be mid-zoom between two lenses, so this is a match, not an identity.
    private func activeCamera(relativeScale: Double?) -> BackCameraCapabilities? {
        guard let relativeScale else { return nil }
        return capabilities.backCameras.min {
            abs($0.relativeScale - relativeScale) < abs($1.relativeScale - relativeScale)
        }
    }

    // MARK: - Actions

    func capture() {
        guard sessionState.isCapturable else {
            AppLog.warn(AppLog.camera, "shutter pressed while state is \(sessionState)")
            return
        }
        guard !isCapturing else { return }
        Haptics.shutter()

        var metadata = makeMetadata()
        let request = makeRequest()
        metadata.hdrStatus = hdr.label
        photo.capture(metadata: metadata, request: request)
    }

    /// The request is derived from capabilities, never from a stored preference, so a
    /// control that a device does not have cannot be re-applied through stale state.
    private func makeRequest() -> PhotoCaptureController.Request {
        var request = PhotoCaptureController.Request()
        request.flash = capabilities.flash.isAvailable ? flashMode : .off
        // Native HDR for stills is exactly this flag, and it is only worth asking for
        // where the active format reports high photo quality.
        request.preferQuality = HDRStatus.requestedQuality(
            hasPhotoQualitySupport: capabilities.photoQualitySupported)
        return request
    }

    private func makeMetadata() -> CaptureMetadata {
        var metadata = CaptureMetadata(mode: mode.rawValue)
        metadata.iso = readout.iso > 0 ? readout.iso : nil
        metadata.shutterSeconds = readout.shutterSeconds > 0 ? readout.shutterSeconds : nil
        metadata.exposureTargetOffset = Double(readout.exposureTargetOffset)
        metadata.lensRelativeScale = readout.relativeScale
        metadata.lensKind = activeCamera(relativeScale: readout.relativeScale)?.kind.rawValue
        metadata.zoomFactor = Double(readout.zoomFactor)
        metadata.frontCamera = facing == .front
        metadata.colorSpace = capabilities.wideGamut ? "display-p3" : "srgb"
        metadata.raw = false
        metadata.proRaw = false
        return metadata
    }

    private func handle(_ result: Result<PhotoCaptureController.Capture, Error>) {
        switch result {
        case .success(let capture):
            do {
                let saved = try PhotoStore.write(capture.data,
                                                 container: capture.container,
                                                 metadata: capture.metadata)
                latestPhoto = saved
                storedBytes = PhotoStore.totalBytes()
                // The badge records that a quality-priority capture was requested on a
                // format that supports it. The resolution is not readable back from
                // `AVCaptureResolvedPhotoSettings`, so this is a request, not a result.
                if capture.metadata.photoQualityPrioritization == "quality",
                   capabilities.photoQualitySupported {
                    hdr = .qualityRequested
                }
                refreshThumbnail(from: capture.data)
            } catch {
                present(error.localizedDescription, isError: true)
            }
        case .failure(let error):
            present(error.localizedDescription, isError: true)
        }
    }

    /// Thumbnail generation is off the main actor: it decodes a full resolution capture.
    /// Only the encoded bytes cross back, because `UIImage` is not `Sendable`, and
    /// `self` is never captured inside the detached task.
    private func refreshThumbnail(from data: Data) {
        Task.detached(priority: .utility) {
            let encoded = PhotoStore.thumbnail(from: data)
            await MainActor.run {
                guard let encoded, let image = UIImage(data: encoded) else { return }
                self.thumbnail = image
            }
        }
    }

    func setFlash(_ mode: AVCaptureDevice.FlashMode) {
        guard capabilities.flash.isAvailable else {
            present(capabilities.flash.reason ?? "Flash unavailable", isError: false)
            return
        }
        flashMode = mode
        Haptics.selection()
    }

    func toggleFlash() {
        setFlash(flashMode == .on ? .off : .on)
    }

    /// Reconfigures for the other side. This is the only action in Step 1 that rebuilds
    /// the session, and the viewfinder is expected to cut rather than animate.
    func flip() {
        guard canFlip else {
            present("Only one camera on this device", isError: false)
            return
        }
        let next: CameraFacing = facing == .back ? .front : .back
        AppLog.note(AppLog.camera, "flip to \(next.rawValue)")
        facing = next
        flashMode = .off
        hasConfigured = true
        sessionController.configure(facing: next, extraOutputs: [photo.output, meter.output]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let configuration): self.finishConfiguration(configuration)
            case .failure(let error): self.present(error.localizedDescription, isError: true)
            }
        }
    }

    /// Tap to focus. Auto mode only: the exposure slider that DESIGN_SPEC pairs with the
    /// reticle is a manual control and belongs to Pro in Step 4.
    func focus(atDevicePoint point: CGPoint) {
        guard let device = sessionController.configuration?.device,
              device.isFocusPointOfInterestSupported
        else { return }
        do {
            try device.lockForConfiguration()
        } catch {
            AppLog.warn(AppLog.camera, "focus: lock failed \(error.localizedDescription)")
            return
        }
        defer { device.unlockForConfiguration() }

        // These mode properties raise an Objective-C exception when the device is not
        // locked rather than throwing a Swift error, so they go through
        // `LumaFrameSafety`, which converts the exception into a log line.
        if device.isFocusModeSupported(.autoFocus) {
            if let failure = LumaFrameSafety.perform({ device.focusMode = .autoFocus }) {
                AppLog.warn(AppLog.camera, "focus: auto focus rejected \(failure)")
            }
        }
        if let failure = LumaFrameSafety.perform({ device.focusPointOfInterest = point }) {
            AppLog.warn(AppLog.camera, "focus: point rejected \(failure)")
            return
        }
        if let failure = LumaFrameSafety.perform({ device.focusMode = .locked }) {
            AppLog.warn(AppLog.camera, "focus: lock rejected \(failure)")
            return
        }
        Haptics.focusLocked()
        AppLog.note(AppLog.camera, "focus locked at device point \(point.x), \(point.y)")
    }

    // MARK: - Presentation

    func present(_ message: String, isError: Bool) {
        banner = message
        isBannerError = isError
        if isError { AppLog.fail(AppLog.ui, "banner: \(message)") }
    }

    func dismissBanner() {
        banner = nil
    }

    /// The one line from `docs/DESIGN_SPEC.md`. Missing values print as `—` rather than
    /// as a zero, so "not measured" never looks like "measured as zero".
    var debugLine: String {
        let fps = sample.map { String(format: "%.1f", $0.framesPerSecond) } ?? "—"
        let exposure = readout.shutterSeconds > 0
            ? "ISO \(Int(readout.iso.rounded())) \(ReportFormat.shutter(readout.shutterSeconds)) "
                + String(format: "EV %+.1f", readout.exposureTargetOffset)
            : "ISO — — EV —"
        // The format's own limits, because "ISO 400" means nothing without them and this
        // is the line a report gets compared against.
        let limits = exposureRange
            .map { " ISO \(ReportFormat.number(Double($0.minISO)))-\(ReportFormat.number(Double($0.maxISO)))" }
            ?? ""
        let memory = MemoryProbe.usedMegabytes().map { String(format: "%.0f MB", $0) } ?? "—"
        return "\(fps) fps | \(exposure)\(limits) | \(mode.rawValue) | \(memory)"
    }
}
