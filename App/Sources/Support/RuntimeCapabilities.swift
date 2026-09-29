import AVFoundation
import CoreMedia
import Foundation
import Metal
import Vision

/// What this device can actually do, discovered at run time and cached.
///
/// This replaces the capability report. The report **crashed the app on device, repeatedly,
/// and the cause was never established** — three plausible fixes were made on the strength
/// of reasoning and a filename, and none of them stopped it. That is the whole argument for
/// throwing it away rather than fixing it a fourth time.
///
/// The important difference is what this does *not* do:
///
/// - **No second `AVCaptureSession`.** The report opened one to read output-level RAW and
///   ProRAW, which is the contention the original hang was attributed to.
/// - **No GPU work.** The report rendered 2560×1440 frames twenty times through a
///   Metal-backed `CIContext`, tens of megabytes of live texture per pass.
/// - **No large allocation.** Everything here is read from state the running session
///   already holds.
/// - **No asynchronous gap.** Every value is available the moment the session is
///   configured, so there is nothing to wait for and nothing that can be half-done.
///
/// The cost is real and is stated rather than hidden: the output-level properties
/// (`availableRawPhotoPixelFormatTypes`, `isAppleProRAWSupported`) are only meaningful
/// once the photo output is attached to a session **with a video source and running**,
/// which is exactly when `CameraViewModel.finishConfiguration` runs. So they are read
/// there and are still real, not cached at launch when they would be empty and wrong.
///
/// What this cannot be is a **portable record**: it describes the device it runs on, at the
/// moment it runs, and nothing else. There is no cross-device comparison any more, and no
/// tiering calibration, because both were built on the report and the report is gone.
struct RuntimeCapabilities: Equatable, Sendable {

    /// Everything UIKit-derived, sampled on the main actor by the caller.
    ///
    /// It is a parameter rather than something read inside, because `UIDevice`, `UIScreen`
    /// and `UIApplication` are all main-thread-affine and this type is read from wherever
    /// the session happens to be configured.
    struct DisplayFacts: Equatable, Sendable {
        var model = "unknown"
        var systemName = "unknown"
        var systemVersion = "unknown"
        var displayGamut = "unknown"
        var maximumFramesPerSecond = 0
        /// Whether the display can show Display P3, which is a different question from
        /// whether the space object exists and is the one that decides output tagging.
        var wideGamut = false
    }

    /// Samples UIKit on the main actor. Nothing else in this file may read UIKit.
    @MainActor
    static func displayFacts() -> DisplayFacts {
        var facts = DisplayFacts()
        let device = UIDevice.current
        facts.model = device.model
        facts.systemName = device.systemName
        facts.systemVersion = device.systemVersion
        facts.displayGamut = String(describing: UIScreen.main.traitCollection.displayGamut)
        facts.maximumFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        facts.wideGamut = UIScreen.main.traitCollection.displayGamut == .displayP3
        return facts
    }

    // MARK: Device

    var model: String = "unknown"
    var systemVersion: String = "unknown"
    /// `hw.machine`, the only stable device key iOS exposes. The SoC is not publicly
    /// queryable at all.
    var machine: String = "unknown"
    var processorCount: Int = 0
    var physicalMemoryBytes: UInt64 = 0
    var isLowPowerMode: Bool = false
    var thermalState: String = "unknown"
    var displayGamut: String = "unknown"
    var maximumFramesPerSecond: Int = 0
    var wideGamut: Bool = false

    // MARK: Camera

    var backCameraCount: Int = 0
    var frontCameraCount: Int = 0
    var flashAvailable: Bool = false
    var authorisation: String = "unknown"
    var backCameras: [BackCameraCapabilities] = []

    /// The active format's fourCC, which is the honest answer to "what format is this".
    var activeFormat: String = "unknown"
    var isoRange: ClosedRange<Float>?
    var shutterRange: ClosedRange<Double>?
    var exposureBiasRange: ClosedRange<Float>?
    var canLockExposure: Bool = false
    var canLockFocus: Bool = false
    var canLockWhiteBalance: Bool = false
    var videoHDRSupported: Bool = false
    var highPhotoQualitySupported: Bool = false
    var zoomMin: CGFloat = 1
    var zoomMax: CGFloat = 1

    // MARK: Output

    /// Read from the photo output **after** it is attached to a running session. Empty
    /// before that, which is why this is not populated at construction.
    var photoCodecs: [String] = []
    var rawPixelTypes: [String] = []
    var proRawSupported: Bool = false
    var maxPhotoDimensions: String = ""

    // MARK: Graphics

    var metalDeviceName: String = "none"
    var lowPowerGPU: Bool = false
    var neuralEngineFamily9: Bool = false

    // MARK: Vision

    var personSegmentationAvailable: Bool = false
    var attentionSaliencyAvailable: Bool = false

    /// `false` only when the GPU cannot be used for the processed preview at all, which
    /// has never been observed but is checked rather than assumed.
    var canProcessPreview: Bool = false

    // MARK: Summary

    /// What the developer support panel shows first.
    var headline: String {
        "back \(backCameraCount)x"
            + " | RAW \(rawPixelTypes.isEmpty ? "no" : "yes")"
            + " | ProRAW \(proRawSupported ? "yes" : "no")"
            + " | \(backCameras.count) lens"
            + " | \(metalDeviceName)"
    }

    /// Everything, one line per row, for the log and the panel.
    ///
    /// Ordered from "most likely to explain a problem" to least, because a developer
    /// reading a log reads the first lines.
    var lines: [(String, String)] {
        [
            ("device", "\(model) · \(machine) · iOS \(systemVersion)"),
            ("gpu", metalDeviceName + (canProcessPreview ? " (preview ready)" : " (preview unavailable)")),
            ("camera", "\(backCameraCount) back, \(frontCameraCount) front, flash \(flashAvailable)"),
            ("authorisation", authorisation),
            ("format", activeFormat),
            ("iso", isoRange.map { "\(ReportFormat.range(Double($0.lowerBound), Double($0.upperBound)))" } ?? "n/a"),
            ("shutter", shutterRange.map { "\(ReportFormat.shutter($0.lowerBound))…\(ReportFormat.shutter($0.upperBound))" } ?? "n/a"),
            ("zoom", "\(ReportFormat.number(Double(zoomMin)))…\(ReportFormat.number(Double(zoomMax)))"),
            ("locks", "exposure \(canLockExposure), focus \(canLockFocus), WB \(canLockWhiteBalance)"),
            ("quality", "videoHDR \(videoHDRSupported), highPhotoQuality \(highPhotoQualitySupported)"),
            ("codecs", ReportFormat.list(photoCodecs)),
            ("raw types", ReportFormat.list(rawPixelTypes, empty: "none")),
            ("proRAW", proRawSupported ? "yes (max \(maxPhotoDimensions))" : "no"),
            ("back lenses", ReportFormat.list(backCameras.map { "\($0.kind.rawValue)@\($0.relativeScale)" })),
            ("vision", "person segmentation \(personSegmentationAvailable), saliency \(attentionSaliencyAvailable)"),
            ("system", "\(processorCount) cores, \(ReportFormat.number(Double(physicalMemoryBytes) / 1_073_741_824, decimals: 1)) GB, low power \(isLowPowerMode), thermal \(thermalState)"),
            ("display", "P3 \(wideGamut), max \(maximumFramesPerSecond) fps, gamut \(displayGamut)")
        ]
    }

    /// Writes the whole thing to the log, which is the portable artefact now that the
    /// report is gone. One tap in the support panel, and the answer is in
    /// `Documents/LumaFrame-log.txt`.
    func logEverything() {
        AppLog.note(AppLog.diagnostics, "capabilities: \(headline)")
        for (label, value) in lines {
            AppLog.note(AppLog.diagnostics, "  \(label): \(value)")
        }
    }
}

// MARK: - Discovery

extension RuntimeCapabilities {

    /// Reads everything available without touching the camera hardware.
    ///
    /// Called at launch. The output-level properties are filled in later, by
    /// `attachingOutput(_:)`, because they are empty until the photo output is on a
    /// running session — reading them here would report "no RAW" on a phone that has RAW.
    static func discover(display: DisplayFacts,
                         cameraIsOwned: Bool) -> RuntimeCapabilities {
        var capabilities = RuntimeCapabilities()

        capabilities.model = display.model
        capabilities.systemVersion = display.systemVersion
        capabilities.machine = machineIdentifier()
        capabilities.processorCount = ProcessInfo.processInfo.activeProcessorCount
        capabilities.physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        capabilities.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        capabilities.thermalState = thermalName(ProcessInfo.processInfo.thermalState)
        capabilities.displayGamut = display.displayGamut
        capabilities.maximumFramesPerSecond = display.maximumFramesPerSecond
        capabilities.wideGamut = display.wideGamut

        capabilities.discoverCameras()
        capabilities.discoverGraphics()
        capabilities.discoverVision()

        // The output-level values need a live session, so they are marked as not yet
        // known rather than guessed at.
        if !cameraIsOwned {
            capabilities.photoCodecs = []
        }
        return capabilities
    }

    /// Fills in the output-level properties, from a photo output that is attached to a
    /// running session with a video source.
    ///
    /// Every read is inside the exception trap. `AVCapturePhotoOutput` raises for values
    /// it does not have in its current configuration, and a crash here would be the
    /// sixteenth thing this area has cost.
    mutating func attachingOutput(_ output: AVCapturePhotoOutput) {
        let failure = LumaFrameSafety.perform {
            self.photoCodecs = output.availablePhotoCodecTypes.map { "\($0.rawValue)" }
            self.rawPixelTypes = output.availableRawPhotoPixelFormatTypes
                .map { ReportFormat.fourCC($0) }
            self.proRawSupported = output.isAppleProRAWSupported
            self.maxPhotoDimensions = "\(output.maxPhotoDimensions.width)"
                + "x\(output.maxPhotoDimensions.height)"
        }
        if let failure {
            // An empty codec list is what makes a capture report "this camera offers no
            // codec", so it is logged loudly rather than left to be discovered by a user.
            AppLog.fail(AppLog.camera, "photo output capabilities raised: \(failure)")
        }
        if photoCodecs.isEmpty {
            AppLog.fail(AppLog.camera,
                        "photo output reports no codecs; capture will be refused")
        }
    }

    private mutating func discoverCameras() {
        authorisation = authorisationName(AVCaptureDevice.authorizationStatus(for: .video))

        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
            .builtInTelephotoCamera, .builtInWideAngleCamera, .builtInUltraWideCamera
        ]
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                       mediaType: .video,
                                                       position: .unspecified)
        var seen = Set<String>()
        let devices = session.devices.filter { seen.insert($0.uniqueID).inserted }

        backCameraCount = devices.filter { $0.position == .back }.count
        frontCameraCount = devices.filter { $0.position == .front }.count
        flashAvailable = devices.contains { $0.position == .back && $0.isFlashAvailable }
        backCameras = devices.filter { $0.position == .back }.map { BackCameraCapabilities.describe($0) }
    }

    private mutating func discoverGraphics() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            metalDeviceName = "none"
            canProcessPreview = false
            return
        }
        metalDeviceName = device.name
        lowPowerGPU = device.isLowPower
        // `supportsFamily(.apple9)` rather than a model lookup: a family query is what the
        // hardware answers, and a chip-name table is a guess about hardware.
        neuralEngineFamily9 = device.supportsFamily(.apple9)
        canProcessPreview = true
    }

    private mutating func discoverVision() {
        // Constructing the request is the documented way to ask whether a built-in model
        // exists, and it costs nothing — it allocates no weights and touches no camera.
        // Running one is a different question and belongs in the pipeline, not in a
        // startup check. The answer is `true` on every device this app supports; it is
        // still asked rather than assumed, because "subject segmentation is free" is the
        // claim Step 5 rests on and it should be checked rather than believed.
        personSegmentationAvailable = VNGeneratePersonSegmentationRequest() != nil
        attentionSaliencyAvailable = VNGenerateAttentionBasedSaliencyImageRequest() != nil
    }

    // MARK: Format

    /// Reads the active format's properties. Must be called with the format the session is
    /// actually using, since a capability like a lockable exposure belongs to the format
    /// and not to the camera.
    mutating func applying(format: AVCaptureDevice.Format, device: AVCaptureDevice) {
        activeFormat = AVCaptureProbeFormat.describe(format)

        if format.minISO <= format.maxISO {
            isoRange = format.minISO...format.maxISO
        }
        let minShutter = CMTimeGetSeconds(format.minExposureDuration)
        let maxShutter = CMTimeGetSeconds(format.maxExposureDuration)
        if minShutter > 0, maxShutter >= minShutter {
            shutterRange = minShutter...maxShutter
        }

        if device.isExposureModeSupported(.custom) {
            let bias = device.minExposureTargetBias
            let scale = device.maxExposureTargetBias
            if bias <= scale { exposureBiasRange = bias...scale }
        }
        canLockExposure = device.isExposureModeSupported(.locked)
        canLockFocus = device.isFocusModeSupported(.locked)
        canLockWhiteBalance = device.isWhiteBalanceModeSupported(.locked)
        videoHDRSupported = format.isVideoHDRSupported
        highPhotoQualitySupported = format.isHighPhotoQualitySupported

        zoomMin = max(1, device.minAvailableVideoZoomFactor)
        zoomMax = max(zoomMin, device.maxAvailableVideoZoomFactor)
    }

    // MARK: Identity

    /// `uname` rather than `sysctlbyname("hw.machine")`, because the sysctl name is not
    /// part of the public iOS API.
    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private static func authorisationName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// `AVCaptureDevice.Format` has no public description, and the four of them that matter
/// are the two dimensions and the media subtype.
enum AVCaptureProbeFormat {
    static func describe(_ format: AVCaptureDevice.Format) -> String {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let fourCC = ReportFormat.fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        return "\(size.width)x\(size.height) \(fourCC)"
    }
}
