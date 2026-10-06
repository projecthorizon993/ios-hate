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

    /// Rebinds the running session to a different back device — a constituent in Pro
    /// mode, the composite back in Auto — without stopping the session.
    ///
    /// Pro mode cannot work on a composite: Apple documents that composite devices
    /// refuse `ExposureMode.custom`, custom lens positions and custom WB gains, so a
    /// Pro dial on one is a control over nothing. Binding the constituent is a session
    /// reconfiguration per lens change, which is the accepted cost (`docs/IOS_PLAN.md`
    /// 3.2): a brief renegotiation instead of a smooth Auto-mode ramp.
    ///
    /// Validate-then-commit: the replacement input is constructed and `canAddInput`
    /// checked *before* `beginConfiguration`, so a refusal fails here with the old
    /// device still bound rather than mid-swap with neither. Outputs stay attached
    /// throughout — only the video input is exchanged. A `nil` uniqueID rebinds the
    /// default back device (the composite), which is the way back to Auto.
    ///
    /// Handed back on the main queue, like `configure`.
    func rebind(toConstituentUniqueID uniqueID: String?,
                completion: @escaping @MainActor (Result<Configuration, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let device: AVCaptureDevice?
            if let uniqueID {
                device = AVCaptureProbeLike.discoverDevices(facing: .back)
                    .first { $0.uniqueID == uniqueID }
                if device == nil {
                    AppLog.warn(AppLog.camera,
                                 "rebind: constituent \(uniqueID) vanished from discovery; keeping bound device")
                }
            } else {
                device = Self.pickDevice(facing: .back)
            }
            guard let device else {
                let result: Result<Configuration, Error> = .failure(CameraError.noDevice(.back))
                DispatchQueue.main.async {
                    completion(result)
                }
                return
            }
            if device.uniqueID == self.videoInput?.device.uniqueID {
                AppLog.note(AppLog.camera,
                            "rebind: already bound to \(device.deviceType.rawValue); reconfiguring anyway")
            }
            let result = self.rebindLocked(to: device)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if case .success(let configuration) = result {
                    self.configuration = configuration
                }
                completion(result)
            }
        }
    }

    /// Exchanges the video input. Must be called on `sessionQueue`, and performs its
    /// own `beginConfiguration`/`commitConfiguration` pair.
    private func rebindLocked(to device: AVCaptureDevice) -> Result<Configuration, Error> {
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            return .failure(error)
        }
        guard session.canAddInput(input) else {
            return .failure(CameraError.inputRejected(device.localizedName))
        }

        session.beginConfiguration()
        if let videoInput { session.removeInput(videoInput) }
        session.addInput(input)
        videoInput = input

        let requested = CaptureFormatChooser.bestFormat(for: device) ?? device.activeFormat
        let applied = applyConfiguration(device: device, format: requested)
        AppLog.note(AppLog.camera, "rebound to \(device.deviceType.rawValue), "
                     + "format \(CaptureFormatChooser.describe(applied))")
        if let photoOutput = self.photoOutput {
            applyMaxPhotoDimensions(on: photoOutput, format: applied)
        }
        observeActiveConstituent(device)
        session.commitConfiguration()

        return .success(Configuration(facing: device.position == .front ? .front : .back,
                                      device: device,
                                      format: applied,
                                      exposureRange: ExposureRange.from(applied)))
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

// Full-size stills. The output is attached by this point, which is the only reason
        // this can happen here at all.
        applyMaxPhotoDimensions(on: photoOutput, format: applied)

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

        configureConstituentSwitching(on: device)

        return device.activeFormat
    }

    /// Raises the still resolution to the largest the active format advertises.
    ///
    /// ## Why this exists
    ///
    /// Every capture came back **1920x1440** while the format's `supportedMaxPhotoDimensions`
    /// advertised 4032x3024:
    ///
    ///     requested format: 4032x3024 still | 1920x1440 video | highQuality=true ...
    ///     capture requested: codec=jpeg quality=quality ...
    ///     capture resolved: 1920x1440 raw=false bytes=617192 container=jpeg
    ///
    /// 1920x1440 is exactly the format's **video** dimensions, which is the tell: the still
    /// was never raised off the video-linked default.
    ///
    /// There was code here that looked like it addressed this and did nothing:
    ///
    ///     let maxStill = photoOutput.maxPhotoDimensions
    ///     photoOutput.maxPhotoDimensions = maxStill
    ///
    /// Reading a property and writing the same value straight back is a no-op, so it read as
    /// high-resolution configuration while never changing a thing. The value has to come from
    /// the format's `supportedMaxPhotoDimensions` instead — the property is on
    /// **`AVCapturePhotoOutput`**, not on `AVCaptureDevice.Format`, which is worth stating
    /// because writing it on the format does not compile.
    ///
    /// This is the other half of `photoQualityPrioritization = .quality`, which the capture
    /// path already asks for and reserves resources for: with the output never told to deliver
    /// at full size there is nothing for the quality prioritisation to preserve.
    ///
    /// Called after the output is attached, which is why it cannot live in `applyConfiguration`
    /// — that runs before the output exists.
    private func applyMaxPhotoDimensions(on photoOutput: AVCapturePhotoOutput,
                                         format: AVCaptureDevice.Format) {
        let before = photoOutput.maxPhotoDimensions
        let describe = { (d: CMVideoDimensions) in "\(d.width)x\(d.height)" }

        guard format.isHighPhotoQualitySupported else {
            // Not a failure: without this flag the format cannot raise the still above the
            // video-linked size at all, and the capture path already downgrades the quality
            // prioritisation rather than pretending otherwise.
            AppLog.note(AppLog.camera,
                        "max photo dimensions: left at \(describe(before)); "
                        + "this format does not support high photo quality")
            return
        }
        guard let largest = CaptureFormatChooser.largestPhotoDimensions(
            in: format.supportedMaxPhotoDimensions) else {
            AppLog.warn(AppLog.camera,
                        "max photo dimensions: format advertises no still sizes; left at \(describe(before))")
            return
        }
        if largest.width == before.width, largest.height == before.height {
            AppLog.note(AppLog.camera,
                        "max photo dimensions: already at \(describe(before))")
            return
        }
        if let failure = LumaFrameSafety.perform({
            photoOutput.maxPhotoDimensions = largest
        }) {
            AppLog.warn(AppLog.camera,
                        "max photo dimensions: \(describe(largest)) rejected (\(failure)); "
                        + "still at \(describe(before))")
            return
        }
        AppLog.note(AppLog.camera,
                    "max photo dimensions: \(describe(before)) -> \(describe(photoOutput.maxPhotoDimensions))")
    }

    /// Hands lens selection back to iOS.
    ///
    /// This started as the opposite: `setPrimaryConstituentDeviceSwitchingBehavior(.restricted, …)`
    /// was applied with an empty condition set to stop iOS quietly abandoning the telephoto. A
    /// telephoto with a 40 cm minimum focus distance cannot deliver a sharp image on a closer
    /// subject, so Apple documents that the virtual device switches to the wide in that case —
    /// and a photo taken at "4x" would really be a wide-lens photo.
    ///
    /// ## Restricting it made things worse, twice
    ///
    /// With an empty condition set the device accepted `.restricted` (the read-back reported
    /// `restricted`, so nothing warned) and then refused to move off the wide at 4x.
    ///
    /// `.videoZoomChanged` was the documented condition for "the zoom factor changed", and the
    /// device accepted that too — `conditions=1 zoomChangedAllowed=true` — and still did not
    /// move. Three 4x requests in a row, each overshooting to 4.080x, past the 4.0 switch-over
    /// point the app is aiming at:
    ///
    ///     zoom -> 4.080x asked 4.0x, switch points [2.0, 4.0]
    ///     settled: lens=Wide zoom=4.080x asked=4.080x target=4.0x landed
    ///     settled: lens=Wide zoom=4.080x asked=4.080x target=4.0x landed
    ///     settled: lens=Ultra wide zoom=1.000x asked=1.000x target=1.0x landed
    ///
    /// The factor arrived every time. The constituent did not, and on one request it ended up
    /// on the **ultra wide** — the user reported a 4x chip with a visibly worse image, which is
    /// exactly a 4x crop of the wrong sensor. Only the fourth request, from a state the device
    /// had already been left in, reported `settled: lens=Telephoto zoom=4.080x`.
    ///
    /// ## Why `.auto` is the fix
    ///
    /// A device nobody has told otherwise hands over by itself: `primaryConstituentDeviceSwitchingBehavior`
    /// "is `.auto` for devices that support camera switching". The composite device already
    /// publishes the answer — `virtualDeviceSwitchOverVideoZoomFactors` is `[2.0, 4.0]` on an
    /// iPhone 11 Pro, which are precisely the optical transitions the zoom control is asking for.
    /// Under `.auto`, "the device automatically selects the best camera for the current scene"
    /// and "places no restrictions on when a camera switch can occur". That is the mechanism
    /// that actually worked in the one run that reached the telephoto; restricting it switched
    /// that mechanism off. The zoom labels and the ramp are not at fault.
    ///
    /// The enum also has a `.locked` case, which pins switching to the active constituent. That
    /// is the behaviour the restriction was reaching for and losing, and it is why the behavior
    /// is now written explicitly rather than left to the default: the read-back below is what
    /// proves it.
    ///
    /// The close-subject downgrade the restriction was written to prevent is iOS choosing a
    /// sharper image over a blurrier one, and it only applies to the *fallback* constituent —
    /// it does not decide the hand-over at 4x, which is what the restriction broke.
    ///
    /// Not applicable to a physical device, which has no constituents to switch between.
    private func configureConstituentSwitching(on device: AVCaptureDevice) {
        guard device.isVirtualDevice else { return }
        // Apple: "Setting the switching behavior to a value other than `.restricted` requires
        // that you set this argument to an empty option set."
        if let failure = LumaFrameSafety.perform({
            device.setPrimaryConstituentDeviceSwitchingBehavior(
                .auto, restrictedSwitchingBehaviorConditions: [])
        }) {
            AppLog.warn(AppLog.camera,
                        "lens switching could not be handed back to iOS: \(failure)")
            return
        }
        let applied = device.primaryConstituentDeviceSwitchingBehavior
        AppLog.note(AppLog.camera,
                    "lens switching handed to iOS: behavior=\(applied.rawValue) "
                    + "points=\(device.virtualDeviceSwitchOverVideoZoomFactors)")
        if applied != .auto {
            AppLog.warn(AppLog.camera,
                        "lens switching is \(applied.rawValue) after being set to auto")
        }
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

    /// Writes the user's manual settings to the device, off the main thread.
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
    ///
    /// Fire-and-forget on `sessionQueue`: `lockForConfiguration` plus up to four
    /// AVFoundation writes used to run on the main thread in the frame-rate-sensitive
    /// dial path. The values are snapshotted at the call and the outcome is logged
    /// where it happens, never returned — by the time it exists the dial has moved
    /// on. What the UI shows is the request; what the device took is the log line.
    func apply(manual: ManualSettings, to configuration: Configuration) {
        let device = configuration.device
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // `lockForConfiguration()` is `throws` and returns `Void`. Comparing it to
            // `nil` does not compile, and the failure has to come from the `catch`,
            // not from a sentinel.
            do {
                try device.lockForConfiguration()
            } catch {
                AppLog.fail(AppLog.camera, "manual: lockForConfiguration failed: \(error.localizedDescription)")
                return
            }
            defer { device.unlockForConfiguration() }

            let applied = self.applyExposure(manual, to: device)
            let focused = self.applyFocus(manual, to: device)
            let balanced = self.applyWhiteBalance(manual, to: device)
            let any = applied || focused || balanced

            // "Asked for" and "the device accepted" are logged as two facts, never one.
            // `summarise` is the request; what follows is the outcome.
            if manual.isExposureManual || manual.lockFocus || manual.lockWhiteBalance {
                AppLog.note(AppLog.camera,
                            "manual requested [\(manual.summarise)] applied=\(any) "
                            + "exposure=\(applied) focus=\(focused) wb=\(balanced)")
            }
        }
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
        // A dialled Kelvin goes through `temperatureAndTintValues`, which is the
        // device-independent form — the panel speaks Kelvin and the device speaks
        // gains, and this conversion is the only honest bridge between them.
        // `deviceWhiteBalanceGains(for:)` can hand back gains past
        // `maxWhiteBalanceGain` for temperatures at the range edges, so the clamp
        // below is against the device's real maximum, not the request.
        if let kelvin = manual.kelvin {
            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                AppLog.warn(AppLog.camera, "kelvin requested but custom gains refused; not applied")
                return false
            }
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: kelvin, tint: 0)
            let gains = Self.clampedGains(device.deviceWhiteBalanceGains(for: values),
                                          ceiling: device.maxWhiteBalanceGain)
            if let failure = LumaFrameSafety.perform({
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }) {
                AppLog.warn(AppLog.camera, "kelvin white balance rejected: \(failure)")
                return false
            }
            AppLog.note(AppLog.camera,
                        "kelvin white balance applied: \(Int(kelvin))K "
                        + "gains=\(gains.redGain)/\(gains.greenGain)/\(gains.blueGain)")
            return true
        }
        // `AVCaptureDevice.currentWhiteBalanceGains`, **not** a `device.whiteBalanceGains`
        // property — there is no such property, and the branch that wrote it had never been
        // compiled. Apple documents this constant as "a special constant representing the
        // current white balance setting", and using it is the one value that is always legal:
        // `isLockingWhiteBalanceWithCustomDeviceGainsSupported` documents that passing any
        // *other* gains value **throws** when that flag is false, which is what a composite
        // reports. So a lock with no user-chosen gains locks whatever the device is doing now,
        // and cannot raise. A dialled Kelvin takes the temperature branch above instead.
        let gains = AVCaptureDevice.currentWhiteBalanceGains
        if let failure = LumaFrameSafety.perform({
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }) {
            AppLog.warn(AppLog.camera, "manual white balance rejected: \(failure)")
            return false
        }
        return true
    }

    /// Gains clamped to what the device will accept: [1, max], per channel.
    ///
    /// Pure, because the conversion from temperature can overshoot on real hardware
    /// and the rule "never write a value the device refused" has to hold without a
    /// camera attached to prove it against.
    nonisolated static func clampedGains(_ gains: AVCaptureDevice.WhiteBalanceGains,
                                        ceiling: Float) -> AVCaptureDevice.WhiteBalanceGains {
        func clamp(_ value: Float) -> Float {
            guard value.isFinite else { return 1 }
            return min(max(value, 1), max(ceiling, 1))
        }
        return AVCaptureDevice.WhiteBalanceGains(redGain: clamp(gains.redGain),
                                                 greenGain: clamp(gains.greenGain),
                                                 blueGain: clamp(gains.blueGain))
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