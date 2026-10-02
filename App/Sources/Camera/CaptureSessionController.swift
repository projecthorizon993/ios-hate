import AVFoundation
import Foundation
import UIKit

/// Owns the `AVCaptureSession` and every transition between its states.
///
/// Concurrency, stated precisely because the compiler enforces it:
///
/// - This type is **deliberately not `@MainActor`**. It does its work on
///   `sessionQueue`, so an actor annotation would be a lie about where the work
///   happens, and it produced seventeen "main actor-isolated property can not be
///   referenced from a Sendable closure" warnings that are all the same warning.
/// - `session`, `videoInput`, `photoOutput` and `extraOutputs` are touched **only on
///   `sessionQueue`**. `session` is additionally read from the main thread by the
///   preview layer, which AVFoundation explicitly allows.
/// - `state`, `configuration` and `onStateChange` are touched **only on the main
///   queue**. `publish` is therefore the single writer, and every caller reaches it
///   through a `DispatchQueue.main.async`.
///
/// Nothing else in the app mutates the session.
///
/// The state machine exists so the UI never has to guess. `docs/DESIGN_SPEC.md`
/// requires that switching modes crossfades the chrome and never restarts the session,
/// which is only enforceable if "the session is up" is an explicit fact rather than an
/// assumption spread across the view.
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

    /// Main-queue only. `publish` is the single writer.
    private(set) var state: State = .idle
    /// Main-queue only. Assigned once, by the owner, before the session starts.
    var onStateChange: ((State) -> Void)?

    /// The session, for `AVCaptureVideoPreviewLayer` and nothing else. Mutating it from
    /// outside this type is a bug; the log and the code review are the enforcement.
    let session = AVCaptureSession()

    /// Main-queue only.
    private(set) var configuration: Configuration?

    private let sessionQueue = DispatchQueue(label: "com.example.LumaFrame.session", qos: .userInitiated)
    /// `sessionQueue` only.
    private var videoInput: AVCaptureDeviceInput?
    /// `sessionQueue` only.
    private var photoOutput: AVCapturePhotoOutput?
    /// `sessionQueue` only.
    private var extraOutputs: [AVCaptureOutput] = []
    private var observers: [NSObjectProtocol] = []
    /// KVO on the bound device's `activePrimaryConstituent`, so a lens hand-over is logged
    /// when it happens rather than only when something else asks.
    ///
    /// `NSKeyValueObservation` must be retained or it unregisters on deallocation, and the
    /// stored-property form of `observe(_:changeHandler:)` is what keeps it alive.
    /// `sessionQueue` only, torn down with the device it observes.
    private var constituentObservation: NSKeyValueObservation?

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
    /// `photoOutput` is the caller's own `AVCapturePhotoOutput` — the one it will call
    /// `capturePhoto` on — and this type adds *that instance* rather than making its own.
    /// It used to create a second one here, while the caller's went in through
    /// `extraOutputs`; the session accepted the first and refused the second, so the
    /// output the shutter actually used was never attached. An unattached output reports
    /// no `availablePhotoCodecTypes`, which is the "this camera offers no photo codec"
    /// refusal that made the app unable to take a picture at all. A session holds one
    /// photo output; the owner has to own it.
    ///
    /// `extraOutputs` are added after the video input and before the session starts, so
    /// a consumer such as the preview meter is already attached on the very first
    /// frame. Adding one later would drop frames and, on some devices, force a
    /// renegotiation.
    /// Handed back on the main queue, so the owner can assign straight into its own
    /// main-actor state without a hop of its own.
    func configure(facing: CameraFacing,
                   photoOutput: AVCapturePhotoOutput,
                   extraOutputs: [AVCaptureOutput],
                   completion: @escaping @MainActor (Result<Configuration, Error>) -> Void) {
        publish(.configuring)

        // `AVCaptureOutput` is not `Sendable`, and the session queue block is. The
        // outputs are handed over exactly once, by the owner that created them, and
        // are never mutated inside the block, so this is the one place the unchecked
        // claim is honest. Every other hop in this type passes plain values.
        let box = OutputBox(extraOutputs)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let result = self.configureLocked(facing: facing,
                                             photoOutput: photoOutput,
                                             extraOutputs: box.outputs)
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
            let failure = LumaFrameSafety.perform({ self.session.stopRunning() })
            if let failure {
                AppLog.warn(AppLog.camera, "stopRunning raised \(failure)")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, case .running = self.state else { return }
                self.publish(.idle)
            }
        }
    }

    /// Releases the session's resources, and **does not return until it has.**
    ///
    /// This used to dispatch onto `sessionQueue` and return immediately, which meant
    /// `CameraViewModel.releaseForDiagnostics()` could call `markReleased()` — telling
    /// the capability report it now owned the camera — while this session was still
    /// running and still had its input attached. The report then opened a second
    /// `AVCaptureSession` from a detached task with no ordering whatsoever against this
    /// queue: one physical camera, two sessions in one process, and a race. That is what
    /// the report kept dying on, and it is why two earlier attempts to fix it by adding
    /// a flag did not hold — the flag was never synchronised with anything.
    ///
    /// Awaited rather than synchronous on purpose. Making this a blocking `sync` on the
    /// caller would hold the main thread for the whole of `stopRunning()` plus whatever
    /// `sessionQueue` happened to be doing, which trades a crash for a main-thread stall
    /// on the watchdog. `async` gives the same ordering guarantee — the continuation
    /// cannot resume until the teardown block has finished — without pinning the main
    /// thread at all.
    func tearDown() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                if self.session.isRunning {
                    let failure = LumaFrameSafety.perform({ self.session.stopRunning() })
                    if let failure {
                        AppLog.warn(AppLog.camera, "stopRunning raised \(failure)")
                    }
                }
                self.session.beginConfiguration()
                for output in self.extraOutputs { self.session.removeOutput(output) }
                if let photoOutput = self.photoOutput { self.session.removeOutput(photoOutput) }
                if let input = self.videoInput { self.session.removeInput(input) }
                self.session.commitConfiguration()
                self.extraOutputs = []
                self.photoOutput = nil
                self.videoInput = nil
                AppLog.note(AppLog.camera, "session torn down")
                continuation.resume()
            }
        }

        await MainActor.run { [weak self] in
            guard let self, case .running = self.state else { return }
            self.publish(.idle)
        }
    }

    private func configureLocked(facing: CameraFacing,
                                 photoOutput: AVCapturePhotoOutput,
                                 extraOutputs: [AVCaptureOutput]) -> Result<Configuration, Error> {
        // `startRunning` deliberately happens after `commitConfiguration`: AVFoundation
        // serialises a running session against its own configuration block, and
        // starting inside the block leaves the session stopped on several devices.
        session.beginConfiguration()
        let configured = reconfigureLocked(facing: facing,
                                           photoOutput: photoOutput,
                                           extraOutputs: extraOutputs)
        session.commitConfiguration()
        guard case .success(let configuration) = configured else { return configured }

        if let failure = LumaFrameSafety.perform({ self.session.startRunning() }) {
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
                                   photoOutput: AVCapturePhotoOutput,
                                   extraOutputs: [AVCaptureOutput]) -> Result<Configuration, Error> {
        // A previous configuration is always removed before a new one is added, so
        // flipping the camera cannot accumulate inputs and outputs.
        for output in self.extraOutputs { session.removeOutput(output) }
        // `self.photoOutput` spelled out: the parameter below shadows the property, and
        // that shorthand was reading the non-optional parameter.
        if let previous = self.photoOutput { session.removeOutput(previous) }
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

        // The caller's instance, added here and nowhere else. See `configure(facing:photoOutput:...)`
        // for what the previous second-instance arrangement cost.
        guard session.canAddOutput(photoOutput) else {
            return .failure(CameraError.photoOutputRejected)
        }
        session.addOutput(photoOutput)
        self.photoOutput = photoOutput

        // Only meaningful once the output is attached, which is why it is not part of
        // the format choice above.
        let maxStill = photoOutput.maxPhotoDimensions
        if maxStill.width > 0, maxStill.height > 0 {
            let failure = LumaFrameSafety.perform { photoOutput.maxPhotoDimensions = maxStill }
            if let failure { AppLog.warn(AppLog.camera, "maxPhotoDimensions rejected: \(failure)") }
        }

        observeActiveConstituent(device)

        for output in extraOutputs {
            guard session.canAddOutput(output) else {
                // A refused extra output is fatal, not something to skip past. The previous
                // version logged and continued, which is how the capture path came to be
                // silently unusable: the only output the shutter used was refused here, the
                // session carried on, and the app reported itself ready. An output the
                // session will not take cannot be replaced by another one, so continuing
                // only hides the failure until something downstream asks for it.
                return .failure(CameraError.outputRejected(String(describing: type(of: output))))
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

    /// The capture-mode setters on `AVCaptureDevice` are plain properties, not throwing
    /// methods, and they raise an Objective-C exception rather than throwing a Swift
    /// error when the device is not locked. So each one is guarded by a support check
    /// and then run through `LumaFrameSafety`, which is the wrapper that actually
    /// converts a raised exception into a log line.
    /// Returns whether the device actually took the mode.
    ///
    /// It used to return `Void`, which meant a caller reporting "applied" after calling it
    /// was reporting a request, not an outcome. That is the specific thing this function's
    /// own log line warns against, six lines above where it was happening.
    @discardableResult
    private func setExposureMode(_ mode: AVCaptureDevice.ExposureMode,
                                 on device: AVCaptureDevice,
                                 name: String) -> Bool {
        guard device.isExposureModeSupported(mode) else {
            AppLog.warn(AppLog.camera, "\(name) mode \(mode) is not supported by this device")
            return false
        }
        if let failure = LumaFrameSafety.perform({ device.exposureMode = mode }) {
            AppLog.warn(AppLog.camera, "\(name) mode rejected: \(failure)")
            return false
        }
        return true
    }

    /// Writes the user's manual settings to the device.
    ///
    /// Every value is gated on the capability that owns it, checked against the range it
    /// came from, and wrapped in the exception trap. AVFoundation raises
    /// `NSInvalidArgumentException` for an unsupported mode or an out-of-range value, and
    /// Swift cannot catch that — so the checks here are what keep an out-of-range value
    /// from becoming a crash rather than a log line.
    ///
    /// Clamping already happened in `ManualSettings.clamped(to:)`. This re-checks rather
    /// than trusting it, because the values arriving here have been through a `@Published`
    /// round trip and the capability set may have changed underneath them.
    @discardableResult
    func apply(manual: ManualSettings, to configuration: Configuration) -> Bool {
        let device = configuration.device
        // `lockForConfiguration()` is `throws` and returns `Void`. Comparing it to `nil`
        // does not compile, and the failure has to come from the `catch`, not from a
        // sentinel.
        do {
            try device.lockForConfiguration()
        } catch {
            AppLog.fail(AppLog.camera, "manual: lockForConfiguration failed: \(error.localizedDescription)")
            return false
        }
        defer { device.unlockForConfiguration() }

        let applied = applyExposure(manual, to: device)
        let focused = applyFocus(manual, to: device)
        let balanced = applyWhiteBalance(manual, to: device)
        let any = applied || focused || balanced

        // "Asked for" and "the device accepted" are logged as two facts, never one.
        // `summarise` is the request; what follows is the outcome.
        if manual.isExposureManual || manual.lockFocus || manual.lockWhiteBalance {
            AppLog.note(AppLog.camera,
                        "manual requested [\(manual.summarise)] applied=\(any) "
                        + "exposure=\(applied) focus=\(focused) wb=\(balanced)")
        }
        return any
    }

    /// ISO, shutter and exposure bias, resolved to one pair and written once.
    ///
    /// `setExposureModeCustom(duration:iso:)` takes duration and ISO together and there is
    /// no partial form of it, so a caller that wants to change one of them must also name
    /// the other. **The value named for the one the user did not choose has to be the
    /// device's current value.** Substituting a constant — which is what an earlier
    /// version of this did, writing 1/60 s whenever only ISO was set — applies an exposure
    /// nobody dialled in, which is the same defect as a control that does nothing, only
    /// harder to notice because the slider did move.
    ///
    /// The bias is written after that call rather than before, and via
    /// `setExposureTargetBias` rather than by assigning `exposureMode`. Entering `.custom`
    /// through the property setter can reset duration and ISO to values this function never
    /// chose, which would discard the pair written a line earlier.
    ///
    /// `exposureTargetOffset` is the read-only *metered* offset from the target, and there
    /// is no `setExposureTargetOffset`. The writable quantity is the bias, and the
    /// `min/maxExposureTargetBias` used for the clamp above are its limits.
    private func applyExposure(_ manual: ManualSettings, to device: AVCaptureDevice) -> Bool {
        let format = device.activeFormat

        guard device.isExposureModeSupported(.custom) else {
            if manual.isExposureManual {
                AppLog.warn(AppLog.camera,
                            "manual exposure requested on \(device.deviceType.rawValue), "
                            + "which does not support .custom; not applied")
            }
            return false
        }

        // Clamp to the *live* format rather than the probed one: the format can be
        // renegotiated between the probe and this call.
        let isoRange = format.minISO <= format.maxISO ? format.minISO...format.maxISO : nil
        let minShutter = CMTimeGetSeconds(format.minExposureDuration)
        let maxShutter = CMTimeGetSeconds(format.maxExposureDuration)
        let shutterRange = minShutter > 0 && maxShutter >= minShutter ? minShutter...maxShutter : nil

        var wrote = false

        // `.custom` is only entered when there is something to enter it for. A settings
        // value of `lockExposure` alone locks whatever the device is already running, so
        // forcing `.custom` first would replace the auto exposure the user did not ask to
        // change.
        let wantsCustom = manual.iso != nil
            || manual.shutterSeconds != nil
            || manual.exposureTargetOffset != 0

        if wantsCustom {
            let pair = Self.resolveExposurePair(manual,
                                                currentSeconds: CMTimeGetSeconds(device.exposureDuration),
                                                currentISO: device.iso,
                                                shutterRange: shutterRange,
                                                isoRange: isoRange)

            if let failure = LumaFrameSafety.perform({
                device.setExposureModeCustom(
                    duration: CMTime(seconds: pair.seconds, preferredTimescale: 1_000_000_000),
                    iso: pair.iso,
                    completionHandler: nil)
            }) {
                AppLog.warn(AppLog.camera, "manual exposure rejected: \(failure)")
            } else {
                wrote = true
                // What was sent, which is not always what was asked for: the clamp may
                // have moved a value, and an unset one was carried over from the device.
                // Both halves are in the line because the difference between them is the
                // thing that has to be explainable from a device log.
                AppLog.note(AppLog.camera,
                            "manual exposure applied: iso=\(Int(pair.iso)) shutter=\(pair.seconds)s"
                            + " requested iso=\(manual.iso.map { String(Int($0)) } ?? "auto")"
                            + " shutter=\(manual.shutterSeconds.map { String($0) } ?? "auto")")
            }

            if manual.exposureTargetOffset != 0 {
                let lower = device.minExposureTargetBias
                let upper = device.maxExposureTargetBias
                let clamped = min(max(manual.exposureTargetOffset, lower), upper)
                if let failure = LumaFrameSafety.perform({
                    device.setExposureTargetBias(clamped, completionHandler: nil)
                }) {
                    AppLog.warn(AppLog.camera, "manual exposure bias rejected: \(failure)")
                } else {
                    wrote = true
                    AppLog.note(AppLog.camera,
                                "manual bias applied: \(clamped)EV"
                                + (clamped == manual.exposureTargetOffset ? "" : " (clamped)"))
                }
            }
        }

        if manual.lockExposure {
            // The return value is used, not ignored: a refused lock must not be reported
            // as applied.
            if setExposureMode(.locked, on: device, name: "exposure") {
                wrote = true
            }
        }
        return wrote
    }

    /// A duration and an ISO, which is the only shape `setExposureModeCustom` accepts.
    struct ExposurePair: Equatable {
        var seconds: Double
        var iso: Float
    }

    /// Resolves what to actually send, given what was asked for and what the device is
    /// doing now.
    ///
    /// Pure, and separate from the write, for one reason: the rule worth protecting here is
    /// **a value the user did not set must come from the device**. That rule cannot be
    /// tested through `AVCaptureDevice`, which does not exist in a headless test process,
    /// and an untestable rule is the rule that comes back. Extracted, the bug this replaces
    /// — writing a fixed 1/60 s whenever only ISO was dialled in — is a two-line test.
    ///
    /// The current values are passed in rather than read from a device, and the ranges are
    /// the live format's rather than the probed ones, because the format can be
    /// renegotiated between the probe and the write.
    static func resolveExposurePair(_ manual: ManualSettings,
                                    currentSeconds: Double,
                                    currentISO: Float,
                                    shutterRange: ClosedRange<Double>?,
                                    isoRange: ClosedRange<Float>?) -> ExposurePair {
        let requestedISO = manual.iso ?? currentISO
        let requestedSeconds = manual.shutterSeconds ?? currentSeconds
        return ExposurePair(
            seconds: shutterRange.map { min(max(requestedSeconds, $0.lowerBound), $0.upperBound) }
                ?? requestedSeconds,
            iso: isoRange.map { min(max(requestedISO, $0.lowerBound), $0.upperBound) }
                ?? requestedISO
        )
    }

    private func applyFocus(_ manual: ManualSettings, to device: AVCaptureDevice) -> Bool {
        guard manual.lockFocus else { return false }
        // Both are needed and they are different questions: a composite supports the locked
        // focus mode and refuses a new lens position.
        guard device.isFocusModeSupported(.locked),
              device.isLockingFocusWithCustomLensPositionSupported else {
            AppLog.warn(AppLog.camera, "manual focus requested but refused by this device; not applied")
            return false
        }
        let position = Float(device.lensPosition)
        if let failure = LumaFrameSafety.perform({
            device.setFocusModeLocked(lensPosition: position)
        }) {
            AppLog.warn(AppLog.camera, "manual focus rejected: \(failure)")
            return false
        }
        return true
    }

    private func applyWhiteBalance(_ manual: ManualSettings, to device: AVCaptureDevice) -> Bool {
        guard manual.lockWhiteBalance else { return false }
        guard device.isWhiteBalanceModeSupported(.locked) else {
            AppLog.warn(AppLog.camera, "manual white balance requested but refused; not applied")
            return false
        }
        // `AVCaptureDevice.currentWhiteBalanceGains`, **not** a `device.whiteBalanceGains`
        // property — there is no such property, and the branch that wrote it had never been
        // compiled. Apple documents this constant as "a special constant representing the
        // current white balance setting", and using it is the one value that is always legal:
        // `isLockingWhiteBalanceWithCustomDeviceGainsSupported` documents that passing any
        // *other* gains value **throws** when that flag is false, which is what a composite
        // reports. So a lock with no user-chosen gains locks whatever the device is doing now,
        // and cannot raise.
        //
        // A UI that let the user dial a Kelvin value would go through
        // `temperatureAndTintValues` and gain the flag above; that is a different feature and
        // is `docs/PHASES.md` 3.2.
        let gains = AVCaptureDevice.currentWhiteBalanceGains
        if let failure = LumaFrameSafety.perform({
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }) {
            AppLog.warn(AppLog.camera, "manual white balance rejected: \(failure)")
            return false
        }
        return true
    }

    private func setFocusMode(_ mode: AVCaptureDevice.FocusMode,
                              on device: AVCaptureDevice,
                              name: String) {
        guard device.isFocusModeSupported(mode) else { return }
        if let failure = LumaFrameSafety.perform({ device.focusMode = mode }) {
            AppLog.warn(AppLog.camera, "\(name) mode rejected: \(failure)")
        }
    }

    private func setWhiteBalanceMode(_ mode: AVCaptureDevice.WhiteBalanceMode,
                                     on device: AVCaptureDevice,
                                     name: String) {
        guard device.isWhiteBalanceModeSupported(mode) else { return }
        if let failure = LumaFrameSafety.perform({ device.whiteBalanceMode = mode }) {
            AppLog.warn(AppLog.camera, "\(name) mode rejected: \(failure)")
        }
    }

    /// Device selection prefers the built-in camera for the requested side, and falls
    /// back to whatever that side reports. No device name is ever compared.
    ///
    /// Which of the reported devices is bound is decided by `CameraPlan.resolve`, the same
    /// function `CameraCapabilities.attachBackCameras` uses to decide which lenses the UI
    /// offers. It used to have its own copy of the rule — a composite preferred here,
    /// composites filtered out there — so the UI could offer lens chips for a session
    /// running a device the capability model had never heard of. One rule, two readers.
    ///
    /// A composite is still preferred, for the recorded reason that switching its virtual
    /// devices keeps one session alive. The cost is that the Pro panel is empty on a Pro
    /// iPhone, because Apple documents composites as refusing `ExposureMode.custom`.
    /// Binding a constituent instead is a session reconfiguration per lens change and is
    /// `docs/PHASES.md` 3.1; it has never been run on a device, so it is not done here.
    static func pickDevice(facing: CameraFacing) -> AVCaptureDevice? {
        // The same discovery the capability model reads, in the same order. This used to
        // build its own `DiscoverySession` with its own type list, and the two lists were in
        // opposite order — so the session bound the TripleCamera while the plan recorded the
        // DualWideCamera as bound. Apple documents that the `devices` array is sorted by the
        // type order requested, so the order *is* the choice, and there is now only one.
        let devices = AVCaptureProbeLike.discoverDevices(facing: facing)
        // `CameraPlan` decides from back cameras, so the front side passes an empty set and
        // the first discovered device is used directly.
        let back = devices.filter { $0.position == .back }
        guard !back.isEmpty else { return devices.first }
        let plan = CameraPlan.resolve(discovered: back.map(BackCameraCapabilities.describe))
        guard let bound = plan.bound else { return devices.first }
        return back.first { $0.uniqueID == bound.uniqueID } ?? devices.first
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
            // The userInfo key is the global `AVCaptureSessionErrorKey`; there is no
            // `AVCaptureSession.errorKey` member.
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
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
            if let failure = LumaFrameSafety.perform({ self.session.startRunning() }) {
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

    /// Logs every hand-over between the physical lenses of a virtual device.
    ///
    /// `activePrimaryConstituent` is documented as key-value observable and as changing
    /// "when zoom, exposure, or focus changes", so this catches the composite switching
    /// sensors underneath a zoom ramp — the thing the user could see happening and the log
    /// could previously only misreport.
    ///
    /// The handler is called on whatever thread KVO delivers on, so it only logs; nothing
    /// is published from here, because the readout is refreshed from the same property on
    /// its own timer.
    private func observeActiveConstituent(_ device: AVCaptureDevice) {
        // Only virtual devices have one, and Apple documents `nil` for everything else, so
        // there is nothing to watch and nothing to say.
        guard device.isVirtualDevice else {
            constituentObservation = nil
            return
        }
        constituentObservation = device.observe(\.activePrimaryConstituent) { device, change in
            // The key path's own type is `AVCaptureDevice?`, so `change.newValue` arrives
            // as `Any?` wrapping a *double* optional — `.some(nil)` when the device is not
            // virtual or has no active constituent, which is not the same as no change at
            // all. Casting through flattens it and both cases read as "single", which is
            // what a nil constituent means.
            let active = change.newValue as? AVCaptureDevice
            AppLog.note(AppLog.camera,
                        "sensor hand-over: now \(active?.lensName ?? "single") "
                        + "(bound \(device.deviceType.rawValue), "
                        + "zoom \(String(format: "%.3f", device.videoZoomFactor))x)")
        }
        let initial = device.activePrimaryConstituent?.lensName ?? "single"
        AppLog.note(AppLog.camera,
                    "sensor initial: \(initial) on \(device.deviceType.rawValue)")
    }

}

// MARK: - Errors

/// Carries the caller's outputs across a queue boundary. See `configure` for why the
/// unchecked `Sendable` claim is sound here.
private final class OutputBox: @unchecked Sendable {
    let outputs: [AVCaptureOutput]
    init(_ outputs: [AVCaptureOutput]) { self.outputs = outputs }
}

enum CameraError: LocalizedError, Equatable {
    case noDevice(CameraFacing)
    case inputRejected(String)
    case photoOutputRejected
    /// An output beyond the photo one that the session refused. Carries the type name so
    /// the message says *which* consumer lost its frames.
    case outputRejected(String)
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDevice(let facing):
            return facing == .front ? "No front camera on this device" : "No back camera on this device"
        case .inputRejected(let name):
            return "The capture session rejected the input for \(name)"
        case .photoOutputRejected:
            return "The capture session rejected the photo output"
        case .outputRejected(let type):
            return "The capture session rejected \(type)"
        case .startFailed(let reason):
            return "The capture session would not start: \(reason)"
        }
    }
}

// MARK: - Discovery

/// Discovery shared by the session, the capability model and the report, so none of them
/// can enumerate a different device set or a different order.
///
/// **One type list, and the order is the priority.** Apple documents that a
/// `DiscoverySession` "automatically sorts its `devices` list based on the device types you
/// asked for, so you can use the array order to find the best device with certain
/// features". So this array is not a set — it is the preference order, and every caller
/// must use this one.
///
/// It did not, and that was a real bug rather than a tidy-up. `pickDevice` asked for
/// `[triple, dualWide, dual, telephoto, wide, ultraWide]` while `discoverBackDevices` asked
/// for the exact reverse. The session therefore bound the `builtInTripleCamera` while
/// `CameraPlan` recorded the `builtInDualWideCamera` as bound — the two halves of one fact
/// disagreeing again, which is precisely what `CameraPlan` was added to prevent, reintroduced
/// by handing it a differently ordered discovery. The log showed the plan reporting
/// `switch points [2.0]`, which is the DualWide's, while the TripleCamera was actually
/// running.
///
/// Composites first, because a composite is the only device that hands between its own
/// physical lenses at the switch-over factors, which is what the zoom control needs. Then
/// the single lenses, widest first, so a device with no composite binds its wide lens.
enum AVCaptureProbeLike {
    /// The device types to look for, **in preference order**.
    static let backDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
        .builtInTelephotoCamera, .builtInWideAngleCamera, .builtInUltraWideCamera
    ]

    static func discoverBackDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: backDeviceTypes,
                                                          mediaType: .video,
                                                          position: .back)
        var seen = Set<String>()
        return discovery.devices.filter { seen.insert($0.uniqueID).inserted }
    }

    /// Discovery for a given side, in the same preference order.
    static func discoverDevices(facing: CameraFacing) -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: backDeviceTypes,
            mediaType: .video,
            position: facing == .front ? .front : .back)
        var seen = Set<String>()
        return discovery.devices.filter { seen.insert($0.uniqueID).inserted }
    }
}