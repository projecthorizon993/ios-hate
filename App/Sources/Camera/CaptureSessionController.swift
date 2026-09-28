import AVFoundation
import Foundation
import UIKit

/// Owns the `AVCaptureSession` and every transition between its states.
///
/// Concurrency: every mutation AVFoundation is not thread-safe about happens on
/// `sessionQueue`; only the published state is hopped to the main actor. Nothing else
/// touches `session`, `videoInput`, or `device.activeFormat`.
///
/// The state machine exists so the UI never has to guess. `docs/DESIGN_SPEC.md`
/// requires that switching modes crossfades the chrome and never restarts the session,
/// which is only enforceable if "the session is up" is an explicit fact rather than an
/// assumption spread across the view.
@MainActor
final class CaptureSessionController: NSObject {

    /// Coarse state, enough for the UI to know what to show. A device that interrupts
    /// the session and comes back does not pass through `idle` — the interruption
    /// reason is surfaced, and the session restarts itself.
    enum State: Equatable {
        case idle
        case configuring
        case running
        /// The system took the session away: a call, another app, backgrounding.
        case interrupted(reason: String)
        case failed(reason: String)

        var isRunning: Bool { self == .running }

        /// True when the shutter must not fire.
        var isCapturable: Bool { self == .running }

        /// One line for the status row, `nil` when there is nothing worth saying.
        var statusText: String? {
            switch self {
            case .running: return nil
            case .idle: return "Camera idle"
            case .configuring: return "Starting camera…"
            case .interrupted(let reason): return reason
            case .failed(let reason): return reason
            }
        }
    }

    /// What a successful configuration produced. The caller needs the device and the
    /// exact active format to build capabilities, because capability gating that
    /// disagrees with the running session is worse than no gating.
    struct Configuration {
        var facing: CameraFacing
        var device: AVCaptureDevice
        var format: AVCaptureDevice.Format
        var exposureRange: ExposureRange
    }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?

    /// The session, for `AVCaptureVideoPreviewLayer` and nothing else. Mutating it from
    /// outside this type is a bug; the log and the code review are the enforcement.
    let session = AVCaptureSession()

    private(set) var configuration: Configuration?

    private let sessionQueue = DispatchQueue(label: "com.example.LumaFrame.session", qos: .userInitiated)
    private var videoInput: AVCaptureDeviceInput?
    private var photoOutput: AVCapturePhotoOutput?
    private var extraOutputs: [AVCaptureOutput] = []
    private var observers: [NSObjectProtocol] = []
    private var rotationAngle: CGFloat = 90

    // MARK: - Lifecycle

    override init() {
        super.init()
        observeSystemEvents()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Configuration

    /// Configures and starts the session for one facing direction.
    ///
    /// `extraOutputs` are added after the video input and before the session starts, so
    /// a consumer such as the preview meter is already attached on the very first
    /// frame. Adding one later would drop frames and, on some devices, force a
    /// renegotiation.
    func configure(facing: CameraFacing,
                   extraOutputs: [AVCaptureOutput],
                   completion: @escaping (Result<Configuration, Error>) -> Void) {
        publish(.configuring)

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let result = self.configureLocked(facing: facing, extraOutputs: extraOutputs)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let configuration):
                    self.configuration = configuration
                    self.publish(.running)
                case .failure(let error):
                    self.publish(.failed(reason: error.localizedDescription))
                }
                completion(result)
            }
        }
    }

    /// Stops the session without tearing it down. Used on backgrounding and on
    /// interruption end, where the session object is still valid and restarting is
    /// cheaper than reconfiguring.
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            let failure = LumaFrameSafety.perform { self.session.stopRunning() }
            if let failure {
                AppLog.warn(AppLog.camera, "stopRunning raised \(failure)")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, case .running = self.state else { return }
                self.publish(.idle)
            }
        }
    }

    /// Releases the session's resources. Called when the camera screen goes away.
    func tearDown() {
        stop()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            for output in self.extraOutputs { self.session.removeOutput(output) }
            if let photoOutput = self.photoOutput { self.session.removeOutput(photoOutput) }
            if let input = self.videoInput { self.session.removeInput(input) }
            self.session.commitConfiguration()
            self.extraOutputs = []
            self.photoOutput = nil
            self.videoInput = nil
            AppLog.note(AppLog.camera, "session torn down")
        }
    }

    private func configureLocked(facing: CameraFacing,
                                 extraOutputs: [AVCaptureOutput]) -> Result<Configuration, Error> {
        // `startRunning` deliberately happens after `commitConfiguration`: AVFoundation
        // serialises a running session against its own configuration block, and
        // starting inside the block leaves the session stopped on several devices.
        session.beginConfiguration()
        let configured = reconfigureLocked(facing: facing, extraOutputs: extraOutputs)
        session.commitConfiguration()
        guard case .success(let configuration) = configured else { return configured }

        if let failure = LumaFrameSafety.perform { session.startRunning() } {
            return .failure(CameraError.startFailed(failure))
        }
        guard session.isRunning else {
            return .failure(CameraError.startFailed("session reported not running"))
        }
        return .success(configuration)
    }

    /// Rebuilds inputs and outputs. Must be called between `beginConfiguration` and
    /// `commitConfiguration`.
    private func reconfigureLocked(facing: CameraFacing,
                                   extraOutputs: [AVCaptureOutput]) -> Result<Configuration, Error> {
        // A previous configuration is always removed before a new one is added, so
        // flipping the camera cannot accumulate inputs and outputs.
        for output in self.extraOutputs { session.removeOutput(output) }
        if let photoOutput { session.removeOutput(photoOutput) }
        if let videoInput { session.removeInput(videoInput) }
        self.extraOutputs = []
        self.photoOutput = nil
        self.videoInput = nil

        let device = Self.pickDevice(facing: facing)
        guard let device else {
            return .failure(CameraError.noDevice(facing))
        }

        session.sessionPreset = .photo
        if session.sessionPreset != .photo {
            AppLog.warn(AppLog.camera, "session refused .photo preset; continuing with \(session.sessionPreset.rawValue)")
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            return .failure(error)
        }
        guard session.canAddInput(input) else {
            return .failure(CameraError.inputRejected(device.localizedName))
        }
        session.addInput(input)
        videoInput = input

        let requested = CaptureFormatChooser.bestFormat(for: device) ?? device.activeFormat
        let applied = applyConfiguration(device: device, format: requested)
        AppLog.note(AppLog.camera, "requested format: \(CaptureFormatChooser.describe(requested))")
        AppLog.note(AppLog.camera, "active format: \(CaptureFormatChooser.describe(applied))")

        let photo = AVCapturePhotoOutput()
        guard session.canAddOutput(photo) else {
            return .failure(CameraError.photoOutputRejected)
        }
        session.addOutput(photo)
        photoOutput = photo

        // Only meaningful once the output is attached, which is why it is not part of
        // the format choice above.
        let maxStill = photo.maxPhotoDimensions
        if maxStill.width > 0, maxStill.height > 0 {
            let failure = LumaFrameSafety.perform { photo.maxPhotoDimensions = maxStill }
            if let failure { AppLog.warn(AppLog.camera, "maxPhotoDimensions rejected: \(failure)") }
        }

        for output in extraOutputs {
            guard session.canAddOutput(output) else {
                AppLog.warn(AppLog.camera, "output rejected by the session: \(type(of: output))")
                continue
            }
            session.addOutput(output)
            self.extraOutputs.append(output)
        }

        return .success(Configuration(facing: device.position == .front ? .front : .back,
                                      device: device,
                                      format: applied,
                                      exposureRange: ExposureRange.from(applied)))
    }

    /// Applies device-level configuration.
    ///
    /// Two different failure mechanisms are handled here, and conflating them was the
    /// bug that used to crash this app: an out-of-range *value* raises an Objective-C
    /// exception inside AVFoundation, which `LumaFrameSafety` converts to a string,
    /// while a *lock* failure is a Swift `throw`, which is handled here. Neither
    /// silently continues.
    private func applyConfiguration(device: AVCaptureDevice,
                                    format: AVCaptureDevice.Format) -> AVCaptureDevice.Format {
        do {
            try device.lockForConfiguration()
        } catch {
            AppLog.fail(AppLog.camera, "lockForConfiguration failed: \(error.localizedDescription)")
            return format
        }
        defer { device.unlockForConfiguration() }

        if let failure = LumaFrameSafety.perform({ device.activeFormat = format }) {
            AppLog.warn(AppLog.camera, "activeFormat rejected: \(failure)")
            return device.activeFormat
        }

        // Auto mode: the system meters. Every one of these is continuous auto, which is
        // what "Auto" means; Pro (Step 4) is the mode that writes custom values here.
        setExposureMode(.continuousAutoExposure, on: device, name: "exposure")
        setFocusMode(.continuousAutoFocus, on: device, name: "focus")
        setWhiteBalanceMode(.autoWhiteBalance, on: device, name: "white balance")

        let duration = CaptureFormatChooser.previewFrameDuration(for: device.activeFormat)
        if let failure = LumaFrameSafety.perform({
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }) {
            AppLog.warn(AppLog.camera, "preview frame duration rejected: \(failure)")
        }

        // `isVideoHDREnabled` is deliberately left alone. It is the only writable HDR
        // knob and it affects **video streaming only** — it does not change how a still
        // is captured. Writing it here would make the badge claim something it cannot
        // deliver. See docs/ARCHITECTURE.md section 2.4.

        return device.activeFormat
    }

    private func setExposureMode(_ mode: AVCaptureDevice.ExposureMode,
                                 on device: AVCaptureDevice,
                                 name: String) {
        guard device.isExposureModeSupported(mode) else { return }
        do {
            try device.setExposureMode(mode)
        } catch {
            AppLog.warn(AppLog.camera, "\(name) mode rejected: \(error.localizedDescription)")
        }
    }

    private func setFocusMode(_ mode: AVCaptureDevice.FocusMode,
                              on device: AVCaptureDevice,
                              name: String) {
        guard device.isFocusModeSupported(mode) else { return }
        do {
            try device.setFocusMode(mode)
        } catch {
            AppLog.warn(AppLog.camera, "\(name) mode rejected: \(error.localizedDescription)")
        }
    }

    private func setWhiteBalanceMode(_ mode: AVCaptureDevice.WhiteBalanceMode,
                                     on device: AVCaptureDevice,
                                     name: String) {
        guard device.isWhiteBalanceModeSupported(mode) else { return }
        do {
            try device.setWhiteBalanceMode(mode)
        } catch {
            AppLog.warn(AppLog.camera, "\(name) mode rejected: \(error.localizedDescription)")
        }
    }

    /// Device selection prefers the built-in camera for the requested side, and falls
    /// back to whatever that side reports. No device name is ever compared.
    static func pickDevice(facing: CameraFacing) -> AVCaptureDevice? {
        let position: AVCaptureDevice.Position = facing == .front ? .front : .back
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
            .builtInTelephotoCamera, .builtInWideAngleCamera, .builtInUltraWideCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                          mediaType: .video,
                                                          position: position)
        // A composite (triple/dual) device is preferred because switching its virtual
        // devices keeps one session alive; a single-lens device is a valid fallback.
        if let composite = discovery.devices.first,
           BackCameraCapabilities.kind(of: composite.deviceType) == .composite {
            return composite
        }
        return discovery.devices.first
    }

    /// Every back camera the device reports, for the capability model.
    static func discoverBackCameras() -> [AVCaptureDevice] {
        AVCaptureProbeLike.discoverBackDevices()
    }

    /// Whether a camera exists on this side at all. Cheap: discovery only, no session.
    /// The flip control hides rather than disables when this is `false`, because a flip
    /// that goes nowhere is not a disabled feature, it is a missing one.
    static func hasDevice(facing: CameraFacing) -> Bool {
        let position: AVCaptureDevice.Position = facing == .front ? .front : .back
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: position)
        return !discovery.devices.isEmpty
    }

    // MARK: - System events

    /// Every observer body hops explicitly to the main actor rather than relying on
    /// `queue: .main`. The queue makes delivery main-threaded in practice, but an
    /// explicit hop is what the compiler can prove, and this is the code that has to
    /// survive the session losing its camera to a phone call.
    private func observeSystemEvents() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? 0
            Task { @MainActor in
                self?.publish(.interrupted(reason: "Camera in use by \(Self.describeInterruption(raw))"))
            }
        })

        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                AppLog.note(AppLog.camera, "interruption ended; restarting")
                self.restart()
            }
        })

        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSession.errorKey] as? NSError
            Task { @MainActor in
                self?.publish(.failed(reason: error?.localizedDescription ?? "Camera runtime error"))
                if let error {
                    AppLog.fail(AppLog.camera,
                                "runtime error \(error.domain) \(error.code): \(error.localizedDescription)")
                }
            }
        })

        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                AppLog.note(AppLog.camera, "resigning active; stopping session")
                self?.stop()
            }
        })

        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.configuration != nil, self.state == .idle else { return }
                AppLog.note(AppLog.camera, "became active; restarting session")
                self.restart()
            }
        })
    }

    private func restart() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            if let failure = LumaFrameSafety.perform { self.session.startRunning() } {
                AppLog.fail(AppLog.camera, "restart failed: \(failure)")
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.publish(.running)
            }
        }
    }

    private func publish(_ newState: State) {
        guard newState != state else { return }
        if case .running = newState {
            AppLog.note(AppLog.camera, "state -> running")
        } else {
            AppLog.note(AppLog.camera, "state -> \(newState)")
        }
        state = newState
        onStateChange?(newState)
    }

    private static func describeInterruption(_ raw: Int) -> String {
        // `InterruptionReason` is imported as a struct rather than an enum, so a plain
        // `default` is used instead of `@unknown default`.
        switch AVCaptureSession.InterruptionReason(rawValue: raw) {
        case .videoDeviceNotAvailableInBackground: return "background"
        case .videoDeviceInUseByAnotherClient: return "another app"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "split screen"
        default: return "another app"
        }
    }
}

// MARK: - Errors

enum CameraError: LocalizedError, Equatable {
    case noDevice(CameraFacing)
    case inputRejected(String)
    case photoOutputRejected
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDevice(let facing):
            return facing == .front ? "No front camera on this device" : "No back camera on this device"
        case .inputRejected(let name):
            return "The capture session rejected the input for \(name)"
        case .photoOutputRejected:
            return "The capture session rejected the photo output"
        case .startFailed(let reason):
            return "The capture session would not start: \(reason)"
        }
    }
}

// MARK: - Discovery

/// Discovery shared with the Step 0 probe so the capability model and the report can
/// never enumerate different device sets.
enum AVCaptureProbeLike {
    static func discoverBackDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
            .builtInDualWideCamera, .builtInDualCamera, .builtInTripleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                          mediaType: .video,
                                                          position: .back)
        var seen = Set<String>()
        return discovery.devices.filter { seen.insert($0.uniqueID).inserted }
    }
}
