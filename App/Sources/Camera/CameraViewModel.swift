import AVFoundation
import CoreImage
import Foundation
import UIKit

    /// The mode switcher. Three modes, and the names are the three things a photographer
    /// actually chooses between.
    ///
    /// Colour grading is not one of them. It lived here once as a fourth mode holding a
    /// look and a strength slider, and that surface is removed: grading belongs to the
    /// photography engine now being planned (see `docs/ENGINE_PLAN.md`), where a look is
    /// one input among tone and custom colour rather than a separate path. Until the
    /// engine lands, Pro holds the manual capture controls and tone.
    enum CameraMode: String, CaseIterable, Equatable {
        case photo
        case video
        case pro

        var label: String {
            switch self {
            case .photo: return "Photo"
            case .video: return "Video"
            case .pro: return "Pro"
            }
        }

        /// Whether this mode can actually capture.
        ///
        /// **Video is `false` and this is a real gap, not a placeholder.** There is no
        /// recorder in the app: `AVAssetWriter` appears only in the still-export path, and
        /// there is no `AVCaptureMovieFileOutput`, no start/stop, and no audio input wired.
        /// A Video button that switched to a viewfinder you could not record from would be
        /// worse than no button, so it is disabled and says why. It stays in the switcher so
        /// the three-mode shape the user asked for is visible and the gap is honest rather
        /// than hidden until someone wonders where it went.
var isImplemented: Bool {
            switch self {
            case .photo, .pro: return true
            case .video: return false
            }
        }
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
    /// What this device can do, discovered at run time. Filled in at launch and again
    /// whenever the session is configured, because the format-level answers change when
    /// the lens does.
    @Published private(set) var runtimeCapabilities = RuntimeCapabilities()

    func setRuntimeCapabilities(_ capabilities: RuntimeCapabilities) {
        runtimeCapabilities = capabilities
    }

    /// The photographer's view of the same hardware, derived from the same read. Kept
    /// separate from `RuntimeCapabilities` because the two answer different questions and
    /// have different lifetimes: this one is rebuilt on every configuration change and
    /// holds only what the UI needs.
    @Published private(set) var capabilities: CameraCapabilities = .unknown
    @Published private(set) var exposureRange: ExposureRange?
    @Published private(set) var hdr: HDRStatus = .unsupported
    @Published private(set) var readout = Readout()
    @Published private(set) var sample: PreviewMeter.Sample?
    @Published private(set) var isCapturing = false
    /// Photo on launch: it is the mode that always works, and the
    /// switcher highlights it before the user touches anything.
    @Published private(set) var mode: CameraMode = .photo
    @Published private(set) var facing: CameraFacing = .back
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var latestPhoto: SavedPhoto?
    @Published private(set) var storedBytes: Int64?
    @Published private(set) var canFlip = false
    @Published var showDebugOverlay = false

    // MARK: - Processing

    /// The recipe. **One value, read by the preview and by the save path**, which is the
    /// only way a grade can be guaranteed to look the same in the photo as it did on
    /// screen. Neither caller may hold its own copy.
    @Published private(set) var settings = ProcessingSettings.none

    /// The live processed preview. Created once and reused; the renderer owns a
    /// `CIContext` and a video output, and both are far too expensive to make per frame.
    let processedPreview = ProcessedPreview()

    /// Bumped whenever the processed preview should redraw. SwiftUI will not redraw a
    /// `MTKView` on its own.
    @Published private(set) var previewRedrawToken = 0

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
        // Frames for the processed preview, straight from the meter's buffer.
        meter.onFrame = { [weak self] pixelBuffer in
            self?.processedPreview.render(pixelBuffer: pixelBuffer)
        }
    }

    /// Configures the session and starts the meter. Safe to call more than once: only
    /// the first call configures, later ones just restart.
    func start() {
        canFlip = CaptureSessionController.hasDevice(facing: .back)
            && CaptureSessionController.hasDevice(facing: .front)
        // Discovered before the session, so the developer panel has something to show the
        // moment it is opened. The output-level values are filled in later, by
        // `finishConfiguration`, because they are empty until the photo output is on a
        // running session.
        let discovered = RuntimeCapabilities.discover(
            display: RuntimeCapabilities.displayFacts(),
            cameraIsOwned: false)
        discovered.logEverything()
        setRuntimeCapabilities(discovered)

        guard !hasConfigured else { return }
        hasConfigured = true
        AppLog.note(AppLog.camera,
                    "camera screen start, build \(AppVersion.description), facing=\(facing.rawValue)")
        // Marks where this run begins. One log file accumulates every session, so without
        // this a run boundary has to be inferred from timestamps.
        LumaFrameLogFile.markRun("launch facing=\(facing.rawValue)")
        configure()
    }

    private func configure() {
        var capabilities = CameraCapabilities.unknown
        capabilities.attachBackCameras(CaptureSessionController.discoverBackCameras())
        self.capabilities = capabilities

        // The meter's video output is the session's **only** video data output, and the
        // processed preview reads from it too. The preview used to own a second one: it
        // was never added to the session, so the processed viewfinder got no frames and
        // rendered black, and the first fix — adding it unconditionally — put two video
        // data outputs of different pixel formats on one session for no benefit. Sharing
        // is fewer bytes and one fewer thing to fail.
        sessionController.configure(facing: facing,
                                    photoOutput: photo.output,
                                    extraOutputs: [meter.output]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let configuration):
                self.finishConfiguration(configuration)
            case .failure(let error):
                self.present(error.localizedDescription, isError: true)
            }
        }
    }

    /// The camera is **never** handed over now.
    ///
    /// The capability report used to need the physical camera to itself, because it opened
    /// a second `AVCaptureSession` to read output-level RAW and ProRAW. That was the
    /// contention the first on-device hang was blamed on, and the handover around it was
    /// the race that made things worse before it was understood.
    ///
    /// The report is gone. `RuntimeCapabilities.attachingOutput(_:)` reads the same
    /// properties from the photo output that is **already attached to the running session**,
    /// so nothing needs a second session and nothing needs the camera given up.
    ///
    /// The methods are kept as no-ops rather than deleted, because the call sites in the
    /// view are the clearest statement of what used to happen and a reader comparing
    /// against an older checkout needs to find that.
    func releaseForDiagnostics() async {
        AppLog.note(AppLog.camera, "no camera handover needed: capabilities read from the live session")
    }

    /// Counterpart to `releaseForDiagnostics()`, and equally a no-op.
    func resumeAfterDiagnostics() {
        AppLog.note(AppLog.camera, "no camera resume needed")
    }

    func stop() async {
        readoutTimer?.invalidate()
        readoutTimer = nil
        await sessionController.tearDown()
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

        // The developer-facing capability table is read here rather than at launch,
        // because this is the first moment the photo output is attached to a session with
        // a video source and **running** — which is the only state in which
        // `availableRawPhotoPixelFormatTypes` and `isAppleProRAWSupported` mean anything.
        // Read earlier they would come back empty, and an empty codec list is what makes a
        // capture report "this camera offers no codec".
        var runtime = runtimeCapabilities
        runtime.applying(format: configuration.format, device: configuration.device)
        runtime.attachingOutput(photo.output)
        runtime.logEverything()
        setRuntimeCapabilities(runtime)

        proCapabilities = ProCapabilities
            .probe(device: configuration.device, format: configuration.format)
            .withRaw(raw: !probed.rawPixelTypes.isEmpty,
                     proRaw: probed.proRawSupported,
                     maxDimensions: runtime.maxPhotoDimensions)
        AppLog.note(AppLog.camera,
                    "pro panel: \(proCapabilities.availabilitySummary)")
        // Re-apply rather than assume: the device has just been configured, so any manual
        // value held across a reconfiguration is still only a value until the device is
        // told.
        if let configuration = sessionController.configuration, manual != .none {
            sessionController.apply(manual: manual, to: configuration)
        }
        pushSettingsToPreview()
        startReadout()
        storedBytes = PhotoStore.totalBytes()

        AppLog.note(AppLog.camera,
                    "camera ready: facing=\(configuration.facing.rawValue) "
                    + "lenses=\(probed.physicalLenses.count) "
                    + "flash=\(probed.flash.isAvailable) "
                    + "hdr=\(self.hdr.label)")
        // The bound device is a fact - the app chose it - so it is logged by name here, at
        // every session start, rather than only at the shutter.
        logCameraSource()
    }

    // MARK: - Recipe

    /// The single place the recipe changes.
    ///
    /// Every mutator funnels through here so the preview is pushed exactly once and the
    /// value the preview is showing and the value a capture will use cannot diverge.
    private func updateSettings(_ transform: (inout ProcessingSettings) -> Void) {
        var copy = settings
        transform(&copy)
        settings = copy.clamped()
        pushSettingsToPreview()
    }

    private func pushSettingsToPreview() {
        let recipe = settings
        // The preview arrives in the video pipeline's own space and leaves as sRGB for
        // display. A P3 capture is handled in the save path, where the file's real colour
        // space is known.
        processedPreview.update(settings: recipe,
                                inputSpace: .sRGB,
                                outputSpace: .sRGB,
                                segmentationAllowed: runtimeCapabilities.personSegmentationAvailable)
        previewRedrawToken += 1
        AppLog.note(AppLog.processing, "recipe: \(recipe.summarise())")
    }

    func setTone(_ tone: ToneCurve) {
        // A dialled-in correction is exactly the case where the native pipeline's own
        // white balance must not also be assumed, so the recipe records it explicitly.
        updateSettings { $0.tone = tone.isIdentity ? nil : tone }
    }

    func setGrain(_ value: Float) {
        updateSettings { $0.grain = value }
    }

    func setSharpen(_ value: Float) {
        updateSettings { $0.sharpen = value }
    }

    /// Imports a `.cube` file into the engine as a color table.
    ///
    /// Parse and validation happen here, once, at import — a table that cannot be
    /// proven correct never reaches the store and can never meet a frame. The space
    /// is declared sRGB: a `.cube` file cannot state one, and the engine bans
    /// inferring it.
    func importTable(from url: URL) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            present("That file could not be read", isError: true)
            return false
        }
        guard let text = String(data: data, encoding: .utf8) else {
            present("That file is not plain text, so it is not a table", isError: true)
            return false
        }
        do {
            let parsed = try LutParser.parse(text: text)
            guard let reference = LutStore.importTable(size: parsed.size,
                                                       samples: parsed.samples,
                                                       filename: url.lastPathComponent,
                                                       space: .sRGB) else {
                present("That table could not be stored", isError: true)
                return false
            }
            updateSettings { $0.lut = reference }
            AppLog.note(AppLog.processing,
                         "table imported: \(reference.filename) size=\(parsed.size)")
            return true
        } catch {
            present(error.localizedDescription, isError: true)
            return false
        }
    }

    func setTableIntensity(_ value: Float) {
        updateSettings {
            if $0.lut != nil { $0.lut?.intensity = value }
        }
    }

    func removeTable() {
        if let reference = settings.lut {
            LutStore.remove(reference)
        }
        updateSettings { $0.lut = nil }
    }

    /// `true` when the recipe does nothing, which is when the app uses the direct preview
    /// layer instead of the processed one.
    var isProcessingActive: Bool { !settings.isIdentity && processedPreview.isAvailable }

    func setMode(_ mode: CameraMode) {
        self.mode = mode
        rebindForMode(mode)
    }

    /// `true` while a lens rebind is in flight. A second rebind on top of the first
    /// would interleave two `beginConfiguration` blocks on the session queue against
    /// one device — so the second tap waits rather than racing. Published so the
    /// pills can disable themselves instead of swallowing the tap silently.
    @Published private(set) var isRebinding = false

    /// Binds the device the mode needs: a constituent in Pro (the only binding on
    /// which manual exposure exists), the composite everywhere else.
    ///
    /// Entering Pro keeps the framing: the constituent matching the composite's
    /// currently active lens is bound where one is offered, so the viewfinder does
    /// not jump to a different lens as a side effect of opening the dials. Leaving
    /// Pro hands switching back to iOS. Either way a refusal keeps the old device —
    /// `rebind` fails with the previous input still bound — and says so in a banner.
    private func rebindForMode(_ mode: CameraMode) {
        guard facing == .back, capabilities.plan.proRequiresRebinding else { return }
        if mode == .pro {
            let current = sessionController.configuration?.device.activePrimaryConstituent
                .map { BackCameraCapabilities.kind(of: $0.deviceType) }
            let match = current.flatMap { kind in
                capabilities.plan.offeredLenses.first { $0.kind == kind }
            }
            let target = match ?? capabilities.plan.offeredLenses.first { $0.kind == .wide }
            guard let target else { return }
            AppLog.note(AppLog.camera,
                         "pro mode: binding constituent \(target.kind.rawValue) (\(target.uniqueID))")
            rebind(toConstituentUniqueID: target.uniqueID)
        } else {
            AppLog.note(AppLog.camera, "leaving pro mode: handing lens switching back to iOS")
            rebind(toConstituentUniqueID: nil)
        }
    }

    /// A lens pill tap. In Pro with constituents offered this binds the pill's lens;
    /// everywhere else it zooms the composite to the translated factor, as before.
    func selectLensPill(_ lens: Double) {
        if mode == .pro,
           facing == .back,
           capabilities.plan.proRequiresRebinding,
           let kind = Self.kindForLensPill(lens),
           let target = capabilities.plan.offeredLenses.first(where: { $0.kind == kind }) {
            AppLog.note(AppLog.camera,
                         "lens pill \(lens)x: binding constituent \(kind.rawValue)")
            rebind(toConstituentUniqueID: target.uniqueID)
            return
        }
        let minimum = capabilities.plan.bound?.minAvailableVideoZoomFactor ?? 1
        let asked = Self.requestedFactor(forLens: lens, minimumAvailableFactor: minimum)
        selectZoom(ZoomStop(factor: asked))
    }

    /// The pill factor the bound lens answers to, for the highlight — or `nil` when
    /// the composite is bound and the zoom-band logic owns the highlight instead.
    ///
    /// A constituent has no switch-over points, so banding its zoom factor against the
    /// composite's points would light the wrong pill. Its own kind is the answer.
    func lensPillFactor() -> Double? {
        guard let bound = sessionController.configuration?.device, !bound.isVirtualDevice else {
            return nil
        }
        switch BackCameraCapabilities.kind(of: bound.deviceType) {
        case .ultraWide: return 0.5
        case .wide: return 1.0
        case .telephoto: return 2.0
        case .composite, .unknown: return nil
        }
    }

    private func rebind(toConstituentUniqueID uniqueID: String?) {
        guard !isRebinding else {
            AppLog.warn(AppLog.camera, "rebind already in flight; tap ignored")
            return
        }
        guard sessionState.isCapturable else {
            AppLog.warn(AppLog.camera, "rebind refused: session is \(sessionState)")
            return
        }
        isRebinding = true
        sessionController.rebind(toConstituentUniqueID: uniqueID) { [weak self] result in
            guard let self else { return }
            self.isRebinding = false
            switch result {
            case .success(let configuration):
                self.finishConfiguration(configuration)
            case .failure(let error):
                self.present(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: - Pro (Step 4)

    /// What this device and this format can actually do. Re-probed on every configuration
    /// change, because a capability like a locked exposure belongs to the *format*, and
    /// switching lenses or formats changes it.
    @Published private(set) var proCapabilities: ProCapabilities = .none

    /// What the user dialled in. Clamped against `proCapabilities` on every change, so a
    /// value that a format cannot honour never reaches AVFoundation to raise.
    @Published private(set) var manual = ManualSettings.none

    private func updateManual(_ transform: (inout ManualSettings) -> Void) {
        var copy = manual
        transform(&copy)
        // The clamp is the whole reason this method exists. Writing an out-of-range ISO or
        // exposure raises inside AVFoundation, and the resulting log line names the
        // property, not the fact that the panel offered a value the format does not have.
        let clamped = copy.clamped(to: proCapabilities)
        if clamped != manual {
            AppLog.note(AppLog.camera, "manual: \(manual.summarise) -> \(clamped.summarise)")
        }
        manual = clamped
        // Clamping stops an illegal value reaching AVFoundation. It does not put the
        // legal one there — the device has to be told, or the panel is a control over
        // nothing, which is the state this was in for five steps.
        if let configuration = sessionController.configuration {
            sessionController.apply(manual: clamped, to: configuration)
        }
    }

    func setManual(iso: Float) { updateManual { $0.iso = iso } }
    func setManual(shutterSeconds: Double) { updateManual { $0.shutterSeconds = shutterSeconds } }
    func setManual(exposureTargetOffset: Float) { updateManual { $0.exposureTargetOffset = exposureTargetOffset } }
    func setManual(lockExposure: Bool) { updateManual { $0.lockExposure = lockExposure } }
    func setManual(lockFocus: Bool) { updateManual { $0.lockFocus = lockFocus } }
    func setManual(lockWhiteBalance: Bool) { updateManual { $0.lockWhiteBalance = lockWhiteBalance } }
    func setManual(kelvin: Float) {
        updateManual {
            $0.kelvin = kelvin
            // A temperature without the lock contradicts itself; `clamped(to:)` also
            // sets it, so the two cannot disagree whichever path runs first.
            $0.lockWhiteBalance = true
        }
    }
    func setManual(raw: Bool) { updateManual { $0.raw = raw } }
    func setManual(proRaw: Bool) { updateManual { $0.proRaw = proRaw } }

    func setManualISO(automatic: Bool) {
        updateManual { $0.iso = automatic ? nil : (proCapabilities.isoRange?.lowerBound) }
    }

    func setManualShutter(automatic: Bool) {
        updateManual {
            $0.shutterSeconds = automatic ? nil : proCapabilities.shutterRange?.lowerBound
        }
    }

    /// Exposure compensation has no "automatic" in the enum sense — 0 EV *is* the neutral
    /// point, and AVFoundation meters to it. So automatic means "back to zero", and the
    /// toggle only exists because the slider cannot express it.
    func setManualEV(automatic: Bool) {
        updateManual { $0.exposureTargetOffset = automatic ? 0 : $0.exposureTargetOffset }
        if !automatic, manual.exposureTargetOffset == 0 {
            updateManual { $0.exposureTargetOffset = 0.25 }
        }
    }

    /// Kelvin on or off. Turning it on starts from the device's own temperature —
    /// read from the current gains — so the dial continues from the scene rather
    /// than jumping to a range edge. Daylight fallback when no device is bound,
    /// which only happens before the first configuration.
    func setManualKelvin(automatic: Bool) {
        if automatic {
            updateManual {
                $0.kelvin = nil
                $0.lockWhiteBalance = false
            }
            return
        }
        var start: Float = 5200
        if let device = sessionController.configuration?.device {
            start = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains).temperature
        }
        updateManual {
            $0.kelvin = start
            $0.lockWhiteBalance = true
        }
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
        // The physical lens, **read** from `activePrimaryConstituent` rather than worked out
        // from the switch-over factors. iOS reports it (iOS 15+) and it is key-value
        // observable; the three inferences tried before this all produced the wrong answer,
        // one of them observed by the user on an iPhone 11 Pro.
        //
        // `nil` from `activePrimaryConstituent` is documented for a nonvirtual device —
        // and there the bound device's own type *is* the lens, which is exactly the
        // Pro-mode constituent case. A composite mid-handover also reads nil, and
        // there "Multi-lens" would be a lie about a transition, so virtual devices
        // keep showing nothing rather than the container's name.
        value.lensLabel = device.activePrimaryConstituent?.lensName
            ?? (device.isVirtualDevice ? nil : device.lensName)
        readout = value
    }

    // MARK: - Actions

    /// Zooms to a lens, or back to the wide one.
    ///
    /// Implemented as a **zoom factor**, not as a format change. On a phone with a
    /// composite back camera there is one `AVCaptureDevice` and several physical lenses
    /// behind it; changing `activeFormat` would be changing the sensor's output format
    /// rather than picking a lens, and it is what makes a multi-lens phone refuse to zoom
    /// in a way that reads as a bug. `videoZoomFactor` is the supported control and it is
    /// the only one that spans lenses.
    ///
    /// Moves to a zoom stop the device itself reported.
    ///
    /// `videoZoomFactor` is the control, because on a multi-lens phone the physical lenses
    /// sit behind one `AVCaptureDevice`; changing `activeFormat` would be changing the
    /// sensor's output format rather than picking a lens. Tapping the current stop returns
    /// to 1x, which is the standard behaviour.
    ///
    /// The stop is a **reported** switch-over factor, not a focal length derived from still
    /// resolution. That derivation produced three chips reading "1x" on an iPhone 11 Pro,
    /// and every tap computed a destination of 1.0 — the position the camera was already
    /// in — while the log recorded it as a successful lens change. The device reported its
    /// switch points as 2.0 and 4.0 all along.
    func selectZoom(_ stop: ZoomStop) {
        guard let device = sessionController.configuration?.device else { return }

        // `minAvailableVideoZoomFactor` and `maxAvailableVideoZoomFactor` are the range the
        // *current configuration* allows. Apple documents that setting `videoZoomFactor`
        // above the active format's `videoMaxZoomFactor` **always raises**, and that a
        // value between `maxAvailableVideoZoomFactor` and the format's maximum silently
        // clamps. So the clamp happens here rather than being left to raise.
        let lower = max(1, device.minAvailableVideoZoomFactor)
        let upper = max(lower, device.maxAvailableVideoZoomFactor)
        // Read from the plan rather than from `device.virtualDeviceSwitchOverVideoZoomFactors`
        // directly. Same numbers — the plan captured them at discovery — but already
        // de-duplicated, sorted and typed `[Double]`, so this call site does not depend on
        // how the Objective-C array bridges into Swift.
        let switchOver = capabilities.plan.bound?.switchOverZoomFactors ?? []

        // "Is this the chip I am already on" has to be a **band** question, not an equality
        // one, because the camera now settles just past a switch-over point. Comparing the
        // raw factor would make a second tap on the same chip look like a different zoom and
        // send the user somewhere new instead of back to 1x.
        let band = Self.band(containing: Double(readout.zoomFactor), switchOver: switchOver)
        let isCurrent = abs(band - Double(stop.factor)) < 0.005

        let destination = CGFloat(isCurrent ? 1 : stop.factor)
        let clamped = min(max(destination, lower), upper)

        // A clamp that moves the destination is a real failure and is logged as one.
        if abs(clamped - destination) > 0.001 {
            AppLog.warn(AppLog.camera,
                        "zoom stop \(stop.factor)x is outside the active format's "
                        + "\(lower)x...\(upper)x range; it will not be honoured")
        }

        // Land **past** a reported switch-over point, never on it.
        //
        // Apple documents the condition precisely: "When the video zoom factor increases
        // **and crosses** a camera's switch-over zoom factor, this camera becomes eligible
        // to set as the activePrimaryConstituent." Asking for exactly 4.0 *touches* the
        // reported switch point 4.0 and never crosses it, so the telephoto is never
        // eligible and the composite stays on the wide. Same at 2.0, which is why 2x is
        // also short of the next lens rather than sitting on a boundary.
        //
        // ## What crossing the point was *not* enough to fix
        //
        // Overshooting to 4.080 was tried while the device was held at
        // `setPrimaryConstituentDeviceSwitchingBehavior(.restricted, …)` and the telephoto still
        // did not arrive — three requests in a row, all reported `settled: lens=Wide`. The
        // restriction was switching the hand-over off; the overshoot only decides whether the
        // hand-over is *eligible*. Both are kept, but only because crossing is genuinely part
        // of Apple's condition, not because it was ever shown to be the fault.
        // See `CaptureSessionController.configureConstituentSwitching`.
        //
        // This also explains the 1x reading: the composite's 1.0 is the **ultra wide's**
        // native field of view, not the wide's, so `activePrimaryConstituent` reporting
        // `BuiltInUltraWideCamera` at zoom 1.000x is the device's own answer and is
        // correct. It was previously read as the app being stuck on the ultra wide.
        //
        // The margin is a small percentage of the factor rather than a fixed epsilon, so it
        // stays proportionally tiny on a device with many switch points, and it is applied
        // only to an actual reported switch-over point — 1.0 is not one, so tapping 1x still
        // lands on exactly 1.0.
        let honoured = Self.factorToAsk(for: clamped, switchOver: switchOver, upper: upper)
        if honoured != clamped {
            AppLog.note(AppLog.camera,
                        "zoom \(clamped)x sits on a reported switch-over point; asking "
                        + "\(String(format: "%.3f", honoured))x so the lens is actually crossed")
        }

        // **The device must be locked before the ramp.** Observed on an iPhone 11 Pro:
        //
        //   zoom to 2.0x raised NSGenericException: -[AVCaptureDevice
        //   _rampToVideoZoomFactor:withRate:duration:rampType:rampTuning:] May not be
        //   called without first successfully gaining exclusive ownership of the device
        //   using -lockForConfiguration:
        //
        // `ramp(toVideoZoomFactor:withRate:)` takes **exclusive ownership**, so it raises
        // where an ordinary property write would merely be ignored. Every other device write
        // in this file is already inside a lock, which is why this one was the only thing
        // that failed.
        do {
            try device.lockForConfiguration()
        } catch {
            AppLog.warn(AppLog.camera, "zoom: lock failed \(error.localizedDescription)")
            present("This camera would not change zoom", isError: true)
            return
        }
        defer { device.unlockForConfiguration() }

        // `ramp` rather than an assignment: the assignment jumps, and a lens change that
        // snaps is one the user cannot follow. The rate is roughly how fast a real lens
        // ring moves.
        let failure = LumaFrameSafety.perform {
            device.ramp(toVideoZoomFactor: honoured, withRate: 4)
        }
        if let failure {
            AppLog.warn(AppLog.camera, "zoom to \(honoured)x raised \(failure)")
            present("This camera would not change zoom", isError: true)
            return
        }
        Haptics.selection()
        AppLog.note(AppLog.camera,
                    "zoom -> \(String(format: "%.3f", honoured))x asked "
                    + "\(String(format: "%.1f", destination))x, switch points "
                    + "\(capabilities.plan.bound?.switchOverZoomFactors ?? [])")
        reportSettledLens(afterAsking: honoured, for: destination, device: device)
        refreshReadout()
    }

    /// The factor to actually ask for, which is the clamped destination unless it sits
    /// exactly on a reported switch-over point. See `switchOverMargin`.
    ///
    /// `nonisolated` for the same reason as `band(containing:switchOver:)`: pure arithmetic on
    /// its arguments, and the unit tests assert it from a nonisolated context.
    nonisolated static func factorToAsk(for clamped: Double,
                                        switchOver: [Double],
                                        upper: Double) -> Double {
        guard switchOver.contains(where: { abs($0 - clamped) < 0.005 }) else { return clamped }
        return min(clamped * switchOverMargin, upper)
    }

    /// The three factors the lens pills offer: 0.5x, 1x and 2x.
    ///
    /// These are the three *physical* lenses — ultra wide, wide and telephoto — rather than
    /// the switch-over factors the device reports, which on this class of hardware are 2 and
    /// 4. A 4x stop is not a fourth lens: it is the 2x telephoto cropped again, so offering it
    /// beside the others put a digital crop next to two optical lenses and made the pill row
    /// claim something untrue about the hardware.
    nonisolated static func lensStops() -> [ZoomStop] {
        [ZoomStop(factor: 0.5), ZoomStop(factor: 1), ZoomStop(factor: 2)]
    }

    /// The constituent kind behind a lens pill, for Pro-mode binding.
    ///
    /// Pills are physical lenses (0.5 ultra wide, 1 wide, 2 telephoto), and in Pro mode
    /// a pill binds that lens's constituent device rather than zooming the composite —
    /// which is exactly what "lens selection is device selection" means. `nil` for
    /// anything off the three pills, so a stray value can never bind a wrong lens.
    ///
    /// `nonisolated` like its neighbours: pure arithmetic on its argument, asserted
    /// from a nonisolated test context.
    nonisolated static func kindForLensPill(_ lens: Double) -> BackCameraCapabilities.Kind? {
        if abs(lens - 0.5) < 0.01 { return .ultraWide }
        if abs(lens - 1.0) < 0.01 { return .wide }
        if abs(lens - 2.0) < 0.01 { return .telephoto }
        return nil
    }

    /// The factor to actually ask the device for when a lens pill is tapped.
    ///
    /// ## Why the pills and the device do not agree
    ///
    /// The active format reports `minAvailableVideoZoomFactor == 1`, so this camera cannot
    /// express a 0.5x *zoom factor* at all — below 1x is a lens, not a factor, on this
    /// hardware. What the device calls 1x is the ultra wide, 2x is the wide and 4x is the
    /// telephoto, which is exactly why it reports its switch points as 2 and 4.
    ///
    /// So the pill row shows the true lens factors the user recognises — 0.5, 1, 2 — and
    /// this translates them to the device's own scale on the way out. One function, so the
    /// mapping is stated once and can be asserted once, rather than being spread across the
    /// taps that need it.
    ///
    /// The shift is derived from the device's floor rather than hardcoded, so a phone that
    /// *can* express 0.5x directly needs no translation at all.
    nonisolated static func requestedFactor(forLens lens: Double,
                                            minimumAvailableFactor: Double) -> Double {
        // The lens row starts at 0.5 and the device's range starts at its floor, so the
        // two scales differ by exactly that ratio. With a floor of 1 the device's scale is
        // twice the lens scale, which is the 0.5->1, 1->2, 2->4 mapping above.
        let lowestLens: Double = 0.5
        guard minimumAvailableFactor > lowestLens else { return lens }
        return lens * (minimumAvailableFactor / lowestLens)
    }

    /// The zoom factors the slider can reach.
    ///
    /// The device's own maximum is not the top of it. An iPhone 11 Pro reports 189x, and a
    /// slider that runs from 1 to 189 packs 1x, 2x and 4x into the first twentieth of the
    /// track and makes the optical stops unusable.
    ///
    /// The long digital tail is worth having, so the ceiling is well past the last lens.
    /// What keeps that from costing the lens stops is `zoomPosition(forFactor:in:)`: the
    /// track is curved, not linear, so the range up to the last real lens occupies most of
    /// the width and the crop-of-a-crop tail is squeezed into the end, where reaching it is
    /// a deliberate act rather than something you fall into on the way to 2x.
    ///
    /// Never below the device's minimum, so the slider cannot offer a factor the active format
    /// would raise on — setting `videoZoomFactor` above `videoMaxZoomFactor` always raises.
    var zoomSliderRange: ClosedRange<Double> {
        guard let device = sessionController.configuration?.device else { return 1...1 }
        let lower = max(1, device.minAvailableVideoZoomFactor)
        let deviceUpper = max(lower, device.maxAvailableVideoZoomFactor)
        // Never degenerate. A `1...1` range while the session is being torn down would be a
        // zero-width track, and `Slider` divides by the span.
        return lower...max(lower, min(deviceUpper, Self.zoomSliderCeiling))
    }

    /// The top of the zoom slider. See `zoomSliderRange`.
    nonisolated static let zoomSliderCeiling: Double = 25

    /// How hard the track bends. Above 1, which pushes the low factors out toward the left
    /// and compresses everything above them. At 2, with a 25x ceiling, 2x lands about a fifth
    /// of the way along and 4x about a third — which is where the lens stops want to be.
    nonisolated static let zoomTrackExponent: Double = 2

    /// Where a zoom factor sits on the 0...1 slider track.
    ///
    /// The inverse of `zoomFactor(forPosition:in:)`, and monotonic in both directions, so a
    /// drag and the reported factor can never disagree about which way is up.
    nonisolated static func zoomPosition(forFactor factor: Double,
                                         in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        // A zero-width range while the session is torn down: everything is at the bottom.
        guard span > 0 else { return 0 }
        let unit = min(max((factor - range.lowerBound) / span, 0), 1)
        return pow(unit, 1 / zoomTrackExponent)
    }

    /// The zoom factor a track position stands for.
    nonisolated static func zoomFactor(forPosition position: Double,
                                       in range: ClosedRange<Double>) -> Double {
        let unit = min(max(position, 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound)
            * pow(unit, zoomTrackExponent)
    }

    /// Zooms to a **factor**, not to a stop, because the slider is continuous: the user drags
    /// to somewhere between 1x and 2x as often as not, and a control that can only land on the
    /// stops it already had would be a step backwards.
    ///
    /// A drag is a stream of deltas, so this assigns `videoZoomFactor` directly rather than
    /// calling `ramp`. `ramp` takes exclusive ownership of the device, which is the right trade
    /// for one destination and the wrong one for sixty of them a second. The value a drag ends
    /// on is ramped to, so the frame settles instead of stopping dead, and that is also the
    /// only point where the settled lens is reported — one line per drag, not one per pixel.
    ///
    /// The 2% switch-over overshoot applies here exactly as it does for a stop tap: a drag that
    /// stops on a reported switch-over point has not crossed it.
    func setZoom(to factor: CGFloat, isFinal: Bool = false) {
        guard let device = sessionController.configuration?.device else { return }
        let range = zoomSliderRange
        let clamped = min(max(Double(factor), range.lowerBound), range.upperBound)
        let switchOver = capabilities.plan.bound?.switchOverZoomFactors ?? []
        let honoured = Self.factorToAsk(for: clamped,
                                         switchOver: switchOver,
                                         upper: range.upperBound)
        guard abs(Double(device.videoZoomFactor) - honoured) > 0.005 else { return }

        do {
            try device.lockForConfiguration()
        } catch {
            AppLog.warn(AppLog.camera, "zoom: lock failed \(error.localizedDescription)")
            return
        }
        defer { device.unlockForConfiguration() }

        let failure = LumaFrameSafety.perform {
            if isFinal {
                device.ramp(toVideoZoomFactor: honoured, withRate: 4)
            } else {
                device.videoZoomFactor = honoured
            }
        }
        if let failure {
            AppLog.warn(AppLog.camera, "zoom to \(honoured)x raised \(failure)")
            return
        }
        if isFinal {
            Haptics.selection()
            AppLog.note(AppLog.camera,
                        "zoom -> \(String(format: "%.3f", honoured))x dragged, switch points "
                        + "\(switchOver)")
            reportSettledLens(afterAsking: CGFloat(honoured), for: CGFloat(honoured), device: device)
        }
        refreshReadout()
    }

    /// Reports which physical lens the device **settled on**, once the ramp is over.
    ///
    /// ## Why this had to be added
    ///
    /// Every lens line in the log came from the KVO on `activePrimaryConstituent`, which
    /// reports *transitions*. Apple documents that constituent as `nil` for the duration of a
    /// switch, so the log's own hand-over lines read:
    ///
    ///     zoom -> 4.080x asked 4.0x, switch points [2.0, 4.0]
    ///     sensor hand-over: now single (bound …TripleCamera, zoom 4.080x)
    ///
    /// `now single` there means "constituent is mid-transition", not "stuck on the wide".
    /// Nothing in the log ever said what the device came to rest on, so "4x reached the
    /// telephoto" and "4x stayed wide" produced near-identical logs and every attempt to
    /// read them back was guesswork.
    ///
    /// The settled value is read after the ramp plus a settling delay, and it reports the
    /// factor the device is *actually* at rather than the one that was requested — because
    /// those differing is itself the answer.
    ///
    /// The delay is a heuristic: nothing notifies "the ramp finished". It is long enough for
    /// the slowest observed hand-over in the device log (~0.6 s after the request) and short
    /// enough not to overlap the next tap. If a run ever reports a stale factor, this delay
    /// is the first thing to raise, not the ramp.
    private func reportSettledLens(afterAsking asked: CGFloat,
                                   for destination: CGFloat,
                                   device: AVCaptureDevice) {
        let settled = Self.settleDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(settled))
            guard let self else { return }
            let lens = device.activePrimaryConstituent?.lensName ?? "single"
            let actual = device.videoZoomFactor
            // The requested factor is what the user asked for; `actual` is what the hardware
            // did. They differ when a ramp is clamped or refused, which is exactly when a
            // chip reads as selected but the frame does not change.
            let agrees = abs(actual - asked) < 0.01
            AppLog.note(AppLog.camera,
                        "settled: lens=\(lens) "
                        + "zoom=\(String(format: "%.3f", actual))x "
                        + "asked=\(String(format: "%.3f", asked))x "
                        + "target=\(String(format: "%.1f", destination))x "
                        + "\(agrees ? "landed" : "DID NOT LAND on request")")
        }
    }

    /// How long after a zoom request the settled lens is reported.
    ///
    /// `nonisolated` because this type is `@MainActor` and the value is a constant with no
    /// actor state, matching `switchOverMargin`.
    nonisolated static let settleDelay: Double = 0.9

    /// How far past a reported switch-over point to ask for.
    ///
    /// Apple makes a lens eligible only when the zoom factor "increases and **crosses**" its
    /// switch-over factor, so a destination that lands exactly on the point never crosses it
    /// and the lens is never chosen. See `selectZoom`.
    ///
    /// Small on purpose. 2% of a switch point is far below the smallest visual difference
    /// between one lens and the next, so the chip still reads as the factor it is labelled
    /// with, while being unambiguously past the boundary.
    ///
    /// `nonisolated` because this type is `@MainActor` and the value is a constant with no
    /// actor state. Without it the unit tests cannot read it from their nonisolated context.
    nonisolated static let switchOverMargin = 1.02

    /// The switch-over factor whose band a zoom factor falls in.
    ///
    /// The reported factors are the **lower** edges of the bands, so the answer is the
    /// largest reported factor that is `<=` the zoom, and 1.0 when the zoom is below them
    /// all. A zoom of 4.08 — just past a reported 4.0 — is therefore still "the 4x stop",
    /// which is what keeps a second tap on the same chip returning to 1x.
    ///
    /// `nonisolated` for the same reason as `switchOverMargin`: pure arithmetic on its
    /// arguments, and the unit tests assert it from a nonisolated context.
    nonisolated static func band(containing zoom: Double, switchOver: [Double]) -> Double {
        let crossed = switchOver.filter { $0 <= zoom + 0.0005 }
        return crossed.max() ?? 1.0
    }

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
        // The recipe, at the moment of the shutter press.
        //
        // The recipe does travel inside the file, and `updateSettings` logs it — but those
        // are two separate lines, and a log where a grade is set at 02:46:11 and a
        // photo stored at 02:46:19 cannot say which grade the photo has. `identity` here
        // is the tell that nothing was applied.
        AppLog.note(AppLog.camera, "shutter: recipe=\(settings.summarise())")
        logCameraSource()
        photo.capture(metadata: metadata, request: request)
    }

    /// What is *known* about the camera source at the moment of the shutter.
    ///
    /// The user asked the log to say which sensor a photo came from, which is the right
    /// question — and the answer is a single property:
    ///
    /// ```swift
    /// var activePrimaryConstituent: AVCaptureDevice? { get }   // iOS 15+
    /// ```
    ///
    /// "A virtual device's active primary constituent device… may change when zoom,
    /// exposure, or focus changes. The value is `nil` for nonvirtual devices." So the
    /// sensor is **reported**, not inferred.
    ///
    /// Three previous attempts to infer it were all wrong — from `relativeScale` (one
    /// constant for every lens), from an index into the switch-over points (off by one,
    /// since 1.0 is not among them), and from a band inference (which the user of an
    /// iPhone 11 Pro observed naming the wrong lens outright). The lesson was taken as
    /// "never claim the sensor", when the correct reading was "look the API up" — the same
    /// mistake as the `isLockingWhiteBalanceWithCustomDeviceGainsSupported` claim in
    /// `docs/HANDOFF.md`. This property was there the whole time.
    ///
    /// What is logged:
    /// - `lens=` — `activePrimaryConstituent?.deviceType`, the physical lens, or `single` on
    ///   a nonvirtual device where `nil` is the documented answer.
    /// - the bound device, the zoom factor and the switch points, for context.
    private func logCameraSource() {
        guard let device = sessionController.configuration?.device else {
            AppLog.warn(AppLog.camera, "camera source: no bound device at the shutter press")
            return
        }
        let points = device.virtualDeviceSwitchOverVideoZoomFactors
            .map { String(format: "%.2g", $0.doubleValue) }
            .joined(separator: "/")
        // `nil` for a nonvirtual device is the documented, correct value — not an absence
        // of information — so it is reported as `single` rather than as unknown.
        let lens = device.activePrimaryConstituent?.deviceType.rawValue ?? "single"
        // Why this lens, and not a longer one. Apple documents that the composite chooses
        // the primary constituent itself: "primarily using a camera's focal length…
        // Secondary conditions are focus and exposure", and a camera that cannot focus or
        // expose well becomes a *fallback* primary constituent instead.
        //
        // The user reported 1x on the ultra wide, 2x on the wide, and the telephoto never
        // reached even at 4x. The most likely reason is the documented fallback: this device
        // reports a telephoto minimum focus distance of 400 — Apple's own worked example is
        // 40 cm — so a close subject keeps iOS on the wide. That is a hypothesis, and these
        // three values are what confirm or kill it rather than a comment asserting it.
        let fallback = device.fallbackPrimaryConstituentDevices
            .map { BackCameraCapabilities.kind(of: $0.deviceType).rawValue }
            .joined(separator: "/")
        let minimumFocus = device.constituentDevices
            .map { BackCameraCapabilities.kind(of: $0.deviceType).rawValue
                 + ":" + String(format: "%.0f", Double($0.minimumFocusDistance)) }
            .joined(separator: " ")
        AppLog.note(AppLog.camera,
                    "camera source: lens=\(lens) "
                    + "bound=\(device.deviceType.rawValue) "
                    + "virtual=\(device.isVirtualDevice) "
                    + "format=\(CaptureFormatChooser.describe(device.activeFormat)) "
                    + "zoom=\(String(format: "%.3f", device.videoZoomFactor))x "
                    + "range=\(String(format: "%.2g", device.minAvailableVideoZoomFactor))"
                    + "…\(String(format: "%.2g", device.maxAvailableVideoZoomFactor)) "
                    + "switchOver=\(points.isEmpty ? "none" : points) "
                    + "switching=\(device.activePrimaryConstituentDeviceSwitchingBehavior.rawValue) "
                    + "fallback=\(fallback.isEmpty ? "none" : fallback) "
                    + "minFocus(\(minimumFocus.isEmpty ? "none" : minimumFocus))")
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
        // The other half of the prioritisation decision. Without this the request is
        // `.balanced` on any format that supports photo quality, and the system may
        // override the ISO and shutter the user just dialled in.
        request.manualExposureActive = manual.isExposureManual
        return request
    }

    private func makeMetadata() -> CaptureMetadata {
        var metadata = CaptureMetadata(mode: mode.rawValue)
        metadata.iso = readout.iso > 0 ? readout.iso : nil
        metadata.shutterSeconds = readout.shutterSeconds > 0 ? readout.shutterSeconds : nil
        metadata.exposureTargetOffset = Double(readout.exposureTargetOffset)
        metadata.lensRelativeScale = readout.relativeScale
        // The physical lens that took it, **read** from `activePrimaryConstituent` (iOS 15+)
        // rather than inferred. This field has been wrong three times over: once from
        // `relativeScale`, which returns one constant for every lens on a modern iPhone;
        // once from an index into the switch-over points, which is off by one because 1.0
        // is not among them; and once from a band inference, which the user of an iPhone 11
        // Pro observed naming the wrong lens. The lesson drawn was "never claim the
        // sensor", which was wrong — the sensor is reported.
        //
        // `single` rather than a blank, because a file that cannot say is better than one
        // that guesses. On a nonvirtual device `activePrimaryConstituent` is documented as
        // `nil`, and the only lens is the bound device's own type.
        if let bound = sessionController.configuration?.device {
            // `nil` from `activePrimaryConstituent` is documented for a nonvirtual device,
            // and there the bound device's own type *is* the lens — one lens, no composite.
            metadata.lensKind = bound.activePrimaryConstituent?.deviceType.rawValue
                ?? bound.deviceType.rawValue
        } else {
            metadata.lensKind = "unknown"
        }
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
            // The original bytes are always written untouched, and the recipe travels in
            // the metadata beside them. A processed version is written as a *separate*
            // file rather than replacing the original, so any photo can be re-rendered
            // later from the untouched capture — which is the whole reason the original is
            // kept. See `docs/ARCHITECTURE.md` step 9.
            do {
                var metadata = capture.metadata
                metadata.processing = settings
                // The preview's latest subject observation rides into the file's
                // recipe, so the saved render blends by the same numbers the
                // viewfinder did. Stale by the delivery delay, like the rest of
                // the live recipe — and cleared by the preview itself whenever
                // nothing usable is in frame.
                metadata.processing?.subject = processedPreview.latestSubjectStats
                let saved = try PhotoStore.write(capture.data,
                                                 container: capture.container,
                                                 metadata: metadata)
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

                if !settings.isIdentity {
                    writeProcessedVersion(of: capture, beside: saved)
                }
            } catch {
                present(error.localizedDescription, isError: true)
            }
        case .failure(let error):
            present(error.localizedDescription, isError: true)
        }
    }

    /// Renders and writes the processed version of a capture.
    ///
    /// This calls the same `ProcessingPipeline` the preview calls, with the same
    /// `ProcessingSettings` value, which is the guarantee that the photo matches what was
    /// on screen. A failure writes nothing and says so: a missing processed file is
    /// recoverable, a wrong one is not.
    private func writeProcessedVersion(of capture: PhotoCaptureController.Capture,
                                       beside original: SavedPhoto) {
        // RAW and ProRAW are not re-rendered here. A RAW file is the sensor's own data and
        // processing it into a JPEG would destroy the reason the user asked for RAW, so the
        // recipe is recorded in the metadata and the RAW is left alone. That is a decision
        // to revisit in Step 9, not something to guess at now.
        guard !capture.isRawPhoto else {
            AppLog.note(AppLog.processing, "RAW capture kept unprocessed; recipe stored in metadata")
            return
        }
        let recipe = settings
        let source = capture.data
        let segmentationAllowed = runtimeCapabilities.personSegmentationAvailable

        Task.detached(priority: .userInitiated) {
            let pipeline = ProcessingPipeline()
            guard let ciImage = CIImage(data: source) else {
                AppLog.fail(AppLog.processing, "processed version: capture data was not an image")
                return
            }
            let outputSpace: ColorSpace = capture.metadata.container == PhotoContainer.heic.rawValue
                ? .displayP3
                : .sRGB
            // The mask pixels are recomputed from the original bytes: the recipe
            // carries the shutter-time statistics and the preview frame's pixels
            // are a different image. Same numbers, same program — which is what
            // makes the file match the viewfinder.
            var blend: SubjectBlendInput?
            var recipeWithSubject = recipe
            if segmentationAllowed,
               let stats = recipe.subject, stats.isUsable,
               recipe.lut?.intensity ?? 0 > 0 {
                let context = CIContext(options: [.workingColorSpace: ColorSpace.linearSRGB.cgColorSpace])
                blend = PersonSegmentation.exportBlendInput(for: ciImage,
                                                             stats: stats,
                                                             context: context)
                if blend == nil {
                    // The recompute found nothing to blend around: drop the
                    // statistics so the derived file describes the global grade
                    // it actually contains. The original keeps the observation.
                    recipeWithSubject.subject = nil
                    AppLog.note(AppLog.processing,
                                 "processed version: no subject in the original; graded globally")
                }
            }
            let rendered = pipeline.renderOrOriginal(ciImage,
                                                     settings: recipeWithSubject,
                                                     inputSpace: .sRGB,
                                                     outputSpace: outputSpace,
                                                     subject: blend)
            guard let data = ProcessingPipeline.encodeJPEG(rendered,
                                                           space: outputSpace,
                                                           quality: 0.95) else {
                AppLog.fail(AppLog.processing, "processed version: could not encode")
                return
            }
            do {
                var metadata = capture.metadata
                metadata.processing = recipeWithSubject
                metadata.derivedFrom = original.id
                let saved = try PhotoStore.write(data,
                                                 container: .jpeg,
                                                 metadata: metadata)
                AppLog.note(AppLog.processing, "processed version written: \(saved.describeForLog)")
            } catch {
                AppLog.fail(AppLog.processing, "processed version not written: \(error.localizedDescription)")
            }
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
        sessionController.configure(facing: next, photoOutput: photo.output, extraOutputs: [meter.output]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let configuration): self.finishConfiguration(configuration)
            case .failure(let error): self.present(error.localizedDescription, isError: true)
            }
        }
    }

    /// Tap to focus. Auto mode tracks continuously at the tap point; Pro locks
    /// there, because the lock is the control in Pro and the panel shows it.
    /// Both run on the session queue — the lock plus mode writes never touch the
    /// frame-rate-sensitive path — and out-of-frame taps clamp to the edge.
    func focus(atDevicePoint point: CGPoint) {
        guard let device = sessionController.configuration?.device else { return }
        if mode == .pro {
            sessionController.lockFocus(at: point, on: device)
        } else {
            sessionController.focusContinuously(at: point, on: device)
        }
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
