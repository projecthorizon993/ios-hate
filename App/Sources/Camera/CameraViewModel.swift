import AVFoundation
import CoreImage
import Foundation
import UIKit

    /// The mode switcher. Step 1 shipped Auto only; Step 3 added Looks and Step 4 added
    /// Pro. All three are implemented, and each still reports what it cannot do on the
    /// current device rather than presenting a control that would do nothing.
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

        var isImplemented: Bool { true }
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
    @Published private(set) var mode: CameraMode = .auto
    @Published private(set) var facing: CameraFacing = .back
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var latestPhoto: SavedPhoto?
    @Published private(set) var storedBytes: Int64?
    @Published private(set) var canFlip = false
    @Published var showDebugOverlay = false

    // MARK: - Processing (Steps 2, 3, 4, 5)

    /// The recipe. **One value, read by the preview and by the save path**, which is the
    /// only way a look can be guaranteed to look the same in the photo as it did on
    /// screen. Neither caller may hold its own copy.
    @Published private(set) var settings = ProcessingSettings.none

    /// The looks the user can pick, built-ins first then their own imports.
    @Published private(set) var looks: [Look] = []

    /// The live processed preview. Created once and reused; `ProcessedPreview` owns a
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
    private let lookLibrary = LookLibrary.shared

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
        AppLog.note(AppLog.camera, "camera screen start, facing=\(facing.rawValue)")
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
        looks = lookLibrary.all
        pushSettingsToPreview()
        startReadout()
        storedBytes = PhotoStore.totalBytes()

        AppLog.note(AppLog.camera,
                    "camera ready: facing=\(configuration.facing.rawValue) "
                    + "lenses=\(probed.physicalLenses.count) "
                    + "flash=\(probed.flash.isAvailable) "
                    + "hdr=\(self.hdr.label)")
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
                                outputSpace: .sRGB)
        previewRedrawToken += 1
        AppLog.note(AppLog.processing, "recipe: \(recipe.summarise())")
    }

    /// Picks a look. `nil` means Original, which is the identity recipe and therefore gets
    /// the cheap direct preview path back.
    func select(look: Look?) {
        updateSettings { $0.look = look }
        if let look {
            AppLog.note(AppLog.processing, "look selected: \(look.name)")
        }
    }

    func setLookIntensity(_ value: Float) {
        updateSettings { $0.lookIntensity = value }
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

    /// Imports a `.cube` the user picked, and selects it if it parses.
    func importLook(cube data: Data, filename: String) -> Bool {
        guard let look = lookLibrary.addImported(cube: data, filename: filename) else {
            present("That lookup table could not be used", isError: true)
            return false
        }
        looks = lookLibrary.all
        select(look: look)
        return true
    }

    func removeImportedLook(_ look: Look) {
        lookLibrary.removeImported(look)
        looks = lookLibrary.all
        if settings.look?.id == look.id {
            select(look: nil)
        }
    }

    /// `true` while the user is holding to compare against the original.
    ///
    /// A hold, not a toggle. `DESIGN_SPEC.md` is explicit, and it is also just better: the
    /// question "what is this look actually doing" needs the answer available continuously
    /// while you are looking, not as a state you have to enter and remember to leave.
    @Published private(set) var isComparing = false

    /// Shows the unprocessed frame for as long as the press lasts. Both halves are needed
    /// — a begin with no matching end would leave the preview stuck on the original.
    func beginCompare() {
        guard !isComparing else { return }
        isComparing = true
        processedPreview.setComparing(true)
        Haptics.selection()
    }

    func endCompare() {
        guard isComparing else { return }
        isComparing = false
        processedPreview.setComparing(false)
    }

    /// Pushes a recipe to the preview **without** changing what a capture will use.
    ///
    /// This is what a hold-to-preview needs. Tapping a look in the carousel selects it, but
    /// touching and holding a look you have not chosen must not change the photo you are
    /// about to take — so the temporary recipe goes to the preview only, and the real one
    /// is restored on release. Conflating the two would mean every "let me just look at
    /// this" quietly altered the user's settings.
    func previewOnly(_ temporary: ProcessingSettings) {
        processedPreview.update(settings: temporary, inputSpace: .sRGB, outputSpace: .sRGB)
        previewRedrawToken += 1
    }

    /// `true` when the recipe does nothing, which is when the app uses the direct preview
    /// layer instead of the processed one.
    var isProcessingActive: Bool { !settings.isIdentity && processedPreview.isAvailable }

    func setMode(_ mode: CameraMode) {
        self.mode = mode
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
        // The lens is chosen from the **zoom factor**, not from the device's relative
        // scale. The device's scale is a property of the hardware and never changes, so
        // matching on it made the label constant: on a triple-camera phone the active
        // device is always the composite and the readout was stuck on whatever the
        // composite reported, whatever the user had zoomed to. `videoZoomFactor` is 1.0 at
        // the wide lens, 0.5 at ultra wide and 3.0 at telephoto, which is the number that
        // actually tracks the reach.
        let active = activeCamera(zoomFactor: value.zoomFactor)
        value.lensLabel = active.flatMap { capabilities.zoomLabel(for: $0) }
        readout = value
    }

    /// The lens whose reach is closest to the current zoom factor.
    ///
    /// A match, not an identity: mid-way between 1x and 3x there is no lens being used,
    /// and the label should show the nearest one rather than snapping to the wrong one.
    private func activeCamera(zoomFactor: CGFloat) -> BackCameraCapabilities? {
        let lenses = capabilities.physicalLenses
        guard !lenses.isEmpty else { return nil }
        // `zoomLabel` reports each lens relative to the wide one, so the factor to match
        // is the same number: 1.0 is wide, 0.5 is ultra wide, 3.0 is telephoto.
        return lenses.min { lhs, rhs in
            abs(zoomLabelFactor(for: lhs) - zoomFactor)
                < abs(zoomLabelFactor(for: rhs) - zoomFactor)
        }
    }

    /// One lens's zoom factor, from the same arithmetic the label uses.
    private func zoomLabelFactor(for camera: BackCameraCapabilities) -> CGFloat {
        guard let reference = capabilities.referenceCamera,
              reference.relativeScale > 0 else { return 1 }
        return CGFloat(camera.relativeScale / reference.relativeScale)
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
    /// Tapping the current lens returns to 1x, which is the standard behaviour and the
    /// reason a single set of lens buttons is enough.
    func selectLens(_ camera: BackCameraCapabilities) {
        guard let device = sessionController.configuration?.device else { return }
        let target = zoomLabelFactor(for: camera)
        let isCurrent = abs(target - readout.zoomFactor) < 0.01
        let destination: CGFloat = isCurrent ? 1 : target

        // `minAvailableVideoZoomFactor` and `maxAvailableVideoZoomFactor` are the range
        // the *current configuration* allows. Apple documents that setting
        // `videoZoomFactor` above the active format's `videoMaxZoomFactor` **always
        // raises**, and that a value between `maxAvailableVideoZoomFactor` and the
        // format's maximum silently clamps. So the clamp is against the available range,
        // and it happens here rather than being left to raise.
        //
        // These are `CGFloat` and there is no list of valid factors: an earlier version
        // used an `availableVideoZoomFactors` array that does not exist.
        let lower = max(1, device.minAvailableVideoZoomFactor)
        let upper = max(lower, device.maxAvailableVideoZoomFactor)
        let clamped = min(max(destination, lower), upper)

        // A clamp that changes the destination means the requested lens is not reachable
        // from the active format, and that used to be logged as a success: the line said
        // `lens -> 1.0x (ultraWide)` with no indication that 1.0x is not the ultra wide.
        // The user sees a chip that does nothing and the log says it worked.
        //
        // `docs/device-record-01.md` finding 2. What this needs to become is a different
        // *format*, not a different zoom factor — `CaptureFormatChooser` ranks on still
        // quality and never on zoom range, and the 4032x3024 it picks has a minimum
        // available zoom factor of 1.0, so every lens below 1x is unreachable. Which
        // formats do carry a usable range is not knowable without a device, so rather
        // than guess at the ranking this says what happened and what was asked for.
        if abs(clamped - destination) > 0.001 {
            AppLog.warn(AppLog.camera,
                        "lens \(camera.kind.rawValue) needs \(destination)x but the active "
                        + "format only allows \(lower)x...\(upper)x; requested lens is "
                        + "unreachable from this format")
        }

        // `ramp` rather than an assignment: the assignment jumps, and a lens change that
        // snaps is a lens change the user cannot follow. The rate is roughly how fast a
        // real lens ring moves.
        let failure = LumaFrameSafety.perform {
            device.ramp(toVideoZoomFactor: clamped, withRate: 4)
        }
        if let failure {
            AppLog.warn(AppLog.camera, "lens switch to \(clamped)x raised \(failure)")
            present("This camera would not change lens", isError: true)
            return
        }
        Haptics.selection()
        AppLog.note(AppLog.camera,
                    "lens -> \(clamped)x (\(camera.kind.rawValue)) asked \(destination)x")
        // Read the readout straight back rather than waiting for the next poll, so the
        // label updates as soon as the ramp starts.
        refreshReadout()
    }

    /// The lenses the user can pick, in reach order.
    var selectableLenses: [BackCameraCapabilities] {
        capabilities.physicalLenses.sorted { $0.relativeScale < $1.relativeScale }
    }

    /// A lens button's title: the reach relative to the wide lens, so 0.5x, 1x, 3x.
    ///
    /// The wide lens is written `1x` and not `1.0x` because that is how every phone writes
    /// it, and the ultra wide keeps its decimal because that is the only way to
    /// distinguish it from the wide one.
    func lensTitle(for camera: BackCameraCapabilities,
                   reference lenses: [BackCameraCapabilities]) -> String {
        let wide = lenses.first { $0.relativeScale >= 1 } ?? lenses.first
        guard let wide, wide.relativeScale > 0, camera.relativeScale > 0 else {
            return "1x"
        }
        let ratio = camera.relativeScale / wide.relativeScale
        if abs(ratio - 1) < 0.01 { return "1x" }
        if ratio < 1 { return String(format: "%.1fx", ratio) }
        return String(format: "%.1fx", ratio)
    }

    /// `true` when this lens is the one the camera is actually at.
    func isCurrentLens(_ camera: BackCameraCapabilities,
                       lenses: [BackCameraCapabilities]) -> Bool {
        guard let wide = lenses.first(where: { $0.relativeScale >= 1 }) ?? lenses.first,
              wide.relativeScale > 0
        else { return false }
        let target = CGFloat(camera.relativeScale / wide.relativeScale)
        return abs(target - readout.zoomFactor) < 0.06
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
        metadata.lensKind = activeCamera(zoomFactor: readout.zoomFactor)?.kind.rawValue
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

        Task.detached(priority: .userInitiated) {
            let pipeline = ProcessingPipeline()
            guard let ciImage = CIImage(data: source) else {
                AppLog.fail(AppLog.processing, "processed version: capture data was not an image")
                return
            }
            let outputSpace: ColorSpace = capture.metadata.container == PhotoContainer.heic.rawValue
                ? .displayP3
                : .sRGB
            let rendered = pipeline.renderOrOriginal(ciImage,
                                                    settings: recipe,
                                                    inputSpace: .sRGB,
                                                    outputSpace: outputSpace)
            guard let data = ProcessingPipeline.encodeJPEG(rendered,
                                                           space: outputSpace,
                                                           quality: 0.95) else {
                AppLog.fail(AppLog.processing, "processed version: could not encode")
                return
            }
            do {
                var metadata = capture.metadata
                metadata.processing = recipe
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
