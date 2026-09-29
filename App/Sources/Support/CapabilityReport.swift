// What this device can actually do, read from the running session.
//
// RuntimeCapabilities is the snapshot, ReportFormat renders it, MemoryProbe is the one measurement it reads, DeveloperPanel presents it, and CameraRelease is a capability datum that belongs with the rest.
//
// Merged mechanically by scripts/consolidate.mjs. Declarations were moved whole and
// nothing was edited; see the commit message for the reasoning.
import Foundation
import AVFoundation
import CoreMedia
import Metal
import Vision
import Darwin
import SwiftUI

// MARK: - release (was App/Sources/Camera/CameraRelease.swift)


/// One-bit handover between the camera screen and the capability report.
///
/// The report needs the physical camera to itself: it opens a second
/// `AVCaptureSession` to read the output-level RAW and ProRAW capabilities, and two
/// sessions contending for one device inside one process is what stalled the main
/// runloop on the first on-device attempt. The camera screen therefore tears its
/// session down before presenting the report and rebuilds it afterwards, and it says
/// so here so the probe can trust the answer.
///
/// Deliberately not a stored property on the view model: the report screen has no
/// reference to the camera screen, and a global that only carries a boolean is far
/// smaller than coupling the two to each other.
@MainActor
final class CameraRelease {

    static let shared = CameraRelease()

    /// `true` once the camera screen has released the device, `false` while it holds a
    /// running session. The probe skips its live session when this is `false`, and says
    /// so in the report rather than opening a second session anyway.
    private(set) var isCameraReleased = false

    private init() {}

    /// The session was fully torn down: inputs and outputs removed, not just stopped.
    func markReleased() {
        isCameraReleased = true
        AppLog.note(AppLog.camera, "camera released for the capability report")
    }

    /// The session is back. The camera is no longer available to the report.
    func markRetaken() {
        isCameraReleased = false
        AppLog.note(AppLog.camera, "camera re-acquired after the capability report")
    }
}

// MARK: - capabilities (was App/Sources/Support/RuntimeCapabilities.swift)






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
        // `UIDisplayGamut` spelled out on both sides. `traitCollection.displayGamut` is a
        // `UIDisplayGamut`, but a bare `.displayP3` resolves against `SwiftUI.Color`'
        // `RGBColorSpace`, which is a different enum with a case of the same name — so the
        // comparison silently fails to compile rather than failing to compile usefully.
        let gamut: UIDisplayGamut = UIScreen.main.traitCollection.displayGamut
        facts.displayGamut = String(describing: gamut)
        facts.maximumFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        facts.wideGamut = gamut == UIDisplayGamut.displayP3
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
        authorisation = Self.authorisationName(AVCaptureDevice.authorizationStatus(for: .video))

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
            // No GPU-power row, and the `MTLDevice.isLowPower` read that used to be here
            // is gone because it is a **macOS-only** property. On iOS it does not compile,
            // and there is no iOS equivalent that answers the same question — Low Power
            // Mode is a device-wide setting reported by `ProcessInfo.isLowPowerModeEnabled`
            // and recorded above, which is a different fact from whether the GPU itself is
            // the low-power part. The field was also never read by anything, so removing it
            // loses no report line.
            //
            // No Neural Engine row, either. A GPU family query is not an answer
            // about the ANE, and there is no public API that reports which compute unit
            // actually ran — so a field named for the ANE and answered from the GPU would
            // be a capability claim the platform cannot support. The one that was here
            // was written, never read, and misleadingly named; see docs/IOS_PLAN.md 10.2
            // for how backend selection is done instead.
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

// MARK: - format (was App/Sources/Support/ReportFormat.swift)



/// Formatting shared by the camera UI, the capture metadata and the developer panel.
///
/// Extracted from the deleted capability report, which is the only thing that needed most
/// of it. ISO and shutter read the same in a control label, a metadata value and a log
/// line, and three spellings of "1/120" would be three things to keep in step.
enum ReportFormat {

    /// `1/120` rather than `0.00833s`, because a camera UI shows shutter speed as a
    /// fraction and the fraction is what gets compared against a stock camera.
    static func shutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "n/a" }
        if seconds >= 1.0 {
            return String(format: "%.1fs", seconds)
        }
        let denominator = (1.0 / seconds).rounded()
        guard denominator >= 1, denominator < 10000 else {
            return String(format: "%.5fs", seconds)
        }
        return "1/\(Int(denominator))"
    }

    /// ISO and EV are floats; drop trailing zeroes so the report stays compact.
    static func number(_ value: Double, decimals: Int = 2) -> String {
        if value == value.rounded(), abs(value) < 1e9 {
            return String(Int(value))
        }
        return String(format: "%.\(decimals)f", value)
    }

    static func range(_ lower: Double, _ upper: Double) -> String {
        "\(number(lower)) ... \(number(upper))"
    }

    static func list(_ values: [String], empty: String = "none") -> String {
        values.isEmpty ? empty : values.joined(separator: ", ")
    }

    /// FourCC code from a `CMFormatDescription`, or `?` when it cannot be read.
    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let scalars = bytes.map { byte -> String in
            let scalar = UnicodeScalar(byte)
            if scalar.value >= 0x20 && scalar.value < 0x7F {
                return String(Character(scalar))
            }
            return String(format: "\\x%02X", byte)
        }
        return scalars.joined()
    }
}

// MARK: - probe (was App/Sources/Support/MemoryProbe.swift)



/// Resident footprint of this process, for the debug overlay.
///
/// `physicalMemory` is the device total, which is useless for spotting a leak, and
/// `ProcessInfo` exposes no used-memory value. `task_info` with `TASK_VM_INFO` is the
/// supported way to read it; `phys_footprint` is the number the jetsam limit is
/// measured against, so it is the number worth watching.
///
/// Returns `nil` rather than a guess when the query fails, so the overlay shows `—`
/// instead of a fabricated figure.
enum MemoryProbe {

    /// Megabytes, one decimal place, or `nil` when unavailable.
    static func usedMegabytes() -> Double? {
        guard let bytes = usedBytes() else { return nil }
        return Double(bytes) / (1024 * 1024)
    }

    static func usedBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
            / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}

// MARK: - panel (was App/Sources/Support/DeveloperPanel.swift)


/// The developer panel: what this device can do, read from values already discovered.
///
/// This is the replacement for the capability report, and the difference is that **it
/// probes nothing.** Every row is rendered from a `RuntimeCapabilities` that was filled in
/// when the session was configured. There is no second capture session, no GPU benchmark,
/// no large allocation and no asynchronous gap — which is the list of things the report
/// did, and the list of things it crashed on.
///
/// So this panel cannot fail in the way the report did, and it is safe to leave reachable.
///
/// The log is the portable artefact. "Log capabilities" writes the same table to
/// `Documents/LumaFrame-log.txt`, which is the thing to send with a bug report now that
/// there is no shareable report file.
struct DeveloperPanel: View {

    @ObservedObject var model: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var logged = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                headline
                rows
                actions
                howToRead
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.ColorToken.surfaceBase)
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headline: some View {
        Text(model.runtimeCapabilities.headline)
            .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
            .foregroundStyle(Theme.ColorToken.accentActive)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(model.runtimeCapabilities.lines, id: \.0) { label, value in
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Text(label)
                        .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.textDisabled)
                        .frame(width: 92, alignment: .leading)
                    Text(value)
                        .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            Button {
                model.runtimeCapabilities.logEverything()
                logged = true
            } label: {
                Text("Log capabilities")
                    .font(.system(size: Theme.TypeSize.caption))
                    .foregroundStyle(Theme.ColorToken.surfaceBase)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(minHeight: Theme.Space.minTouch)
                    .background(Theme.ColorToken.accentActive)
                    .clipShape(Capsule())
            }
            .accessibilityHint("Writes every capability to the log file, which is what to send with a bug report")
        }
    }

    /// Says where the log is, because a developer looking for the file will not guess that
    /// Documents is exposed through Files.app by two Info.plist keys.
    private var howToRead: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(logged ? "Written. On My iPhone › LumaFrame › \(LumaFrameLogFile.fileName)"
                        : "Log file: On My iPhone › LumaFrame › \(LumaFrameLogFile.fileName)")
                .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                .foregroundStyle(logged ? Theme.ColorToken.accentActive : Theme.ColorToken.textDisabled)
                .fixedSize(horizontal: false, vertical: true)

            Text("These are read at run time on this device. There is no cross-device record "
                 + "any more: capabilities are not a measurement you gather once, they are "
                 + "what the hardware reports while it is running.")
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
