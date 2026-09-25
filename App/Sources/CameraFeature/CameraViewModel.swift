import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class CameraViewModel: ObservableObject {
    @Published var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var capabilities = DeviceCapabilities.fallback
    @Published var mode: CaptureMode = .auto
    @Published var iso: Float = 400
    @Published var shutterDuration = 1.0 / 60.0
    @Published var exposureCompensation: Float = 0
    @Published var kelvin: Float = 5200
    @Published var tint: Float = 0
    @Published var zoomFactor: CGFloat = 1
    @Published var focusLocked = false
    @Published var processedFrame: UIImage?
    @Published var isProcessing = false
    @Published var isCapturing = false
    @Published var isBracketCapturing = false
    @Published var bracketFrameCount = 0
    @Published var errorMessage: String?
    @Published var selectedPreset = ColorGradePreset.builtIns.first!
    @Published var grade = GradeSettings.neutral
    @Published var showManualControls = false
    @Published var showPerformanceOverlay = false
    @Published var showLiveEnhancement = false
    @Published var aspectRatio: CaptureAspectRatio = .original
    @Published var rawEnabled = false
    @Published private(set) var isConfigured = false

    let coordinator: CameraCoordinator
    let library: MediaLibrary
    let presetStore: PresetStore
    let diagnostics: DiagnosticsLog
    let performanceMonitor: PerformanceMonitor

    private let pipeline = ImagePipeline()
    private let previewPipeline = ImagePipeline(preview: true)
    private let previewQueue = DispatchQueue(label: "com.lumaframe.preview.processing", qos: .userInitiated)
    private var bracketFrames: [Data] = []
    private var pendingRawData: Data?
    private var pendingProcessedData: Data?
    private var captureRawEnabled = false
    private var isPreviewProcessing = false

    init() {
        coordinator = CameraCoordinator()
        library = MediaLibrary()
        presetStore = PresetStore()
        diagnostics = DiagnosticsLog()
        performanceMonitor = PerformanceMonitor()
        performanceMonitor.start()
        coordinator.setPreviewProcessingEnabled(false)
        coordinator.onFrameTiming = { [weak self] timing in
            self?.performanceMonitor.recordFrameTiming(timing)
        }
        coordinator.onFrame = { [weak self] image in
            guard let self, self.showLiveEnhancement, !self.isPreviewProcessing else { return }
            self.isPreviewProcessing = true
            let grade = previewGrade(self.grade)
            let enhanceLowLight = self.mode == .bracket || self.mode == .cinematic
            let previewDimension = self.performanceMonitor.recommendedPreviewDimension
            let queuedAt = DispatchTime.now().uptimeNanoseconds
            self.previewQueue.async { [weak self] in
                guard let self else { return }
                let queueWait = Double(DispatchTime.now().uptimeNanoseconds - queuedAt) / 1_000_000
                let processed = self.previewPipeline.processPreview(cgImage: image, grade: grade, enhanceLowLight: enhanceLowLight, maxDimension: previewDimension) ?? image
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isPreviewProcessing = false
                    self.performanceMonitor.recordQueueWait(queueWait)
                    self.performanceMonitor.recordFrame()
                    self.processedFrame = UIImage(cgImage: processed)
                }
            }
        }
        coordinator.onPhoto = { [weak self] data, isRaw in
            self?.receivePhoto(data, isRaw: isRaw)
        }
        coordinator.onConfigured = { [weak self] success in
            guard let self else { return }
            self.isConfigured = success
            if success {
                self.capabilities = DeviceCapabilities.discover()
                self.zoomFactor = max(self.minimumZoomFactor, min(CGFloat(1), self.capabilities.maximumZoomFactor))
                self.diagnostics.record("Camera configured", level: "info")
            } else {
                self.errorMessage = "Camera setup was not completed."
                self.diagnostics.record("Camera setup failed")
            }
        }
        coordinator.onError = { [weak self] message in
            self?.errorMessage = message
            self?.diagnostics.record(message)
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized
    }

    var minimumZoomFactor: CGFloat {
        capabilities.lenses.contains { $0.name.contains("Ultra") } ? 0.5 : capabilities.minimumZoomFactor
    }

    var activeLensName: String {
        let hasUltraWide = capabilities.lenses.contains { $0.name.contains("Ultra") }
        let hasTelephoto = capabilities.lenses.contains { $0.name.contains("Telephoto") }
        if hasUltraWide && zoomFactor < 0.8 { return "0.5× Ultra Wide" }
        if hasTelephoto && zoomFactor > 1.8 { return "3× Telephoto" }
        return "1× Wide"
    }

    func setLiveEnhancement(_ enabled: Bool) {
        showLiveEnhancement = enabled
        coordinator.setPreviewProcessingEnabled(enabled)
        if !enabled {
            processedFrame = nil
        }
    }

    func start() {
        performanceMonitor.start()
        switch authorizationStatus {
        case .authorized:
            coordinator.configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.authorizationStatus = granted ? .authorized : .denied
                    if granted { self.coordinator.configure() }
                }
            }
        default:
            break
        }
    }

    func stop() {
        performanceMonitor.stop()
        coordinator.stop()
    }

    func selectMode(_ newMode: CaptureMode) {
        mode = newMode
        diagnostics.record("Mode changed to \(newMode.rawValue)", level: "info")
        if newMode == .cinematic {
            shutterDuration = 1.0 / 48.0
            aspectRatio = .cinema
            selectedPreset = ColorGradePreset.builtIns[1]
            grade = selectedPreset.grade
        } else {
            aspectRatio = .original
            if newMode == .manual {
                shutterDuration = 1.0 / 60.0
            }
        }
        if isConfigured {
            applySettings()
        }
    }

    func setZoom(_ value: CGFloat) {
        guard isConfigured else { return }
        zoomFactor = min(max(value, minimumZoomFactor), capabilities.maximumZoomFactor)
        coordinator.setZoomFactor(zoomFactor)
        applySettings()
    }

    func toggleFocusLock() {
        guard isConfigured else { return }
        focusLocked.toggle()
        applySettings()
    }

    func applySettings() {
        guard isConfigured else { return }
        let settings = CaptureSettings(
            mode: mode,
            iso: min(max(iso, capabilities.minimumISO), capabilities.maximumISO),
            shutterDuration: min(max(shutterDuration, capabilities.minimumExposureDuration), capabilities.maximumExposureDuration),
            exposureCompensation: exposureCompensation,
            kelvin: kelvin,
            tint: tint,
            focusLocked: focusLocked,
            zoomFactor: zoomFactor
        )
        coordinator.apply(settings: settings)
    }

    func capture() {
        guard isConfigured else {
            errorMessage = "The camera is still starting."
            return
        }
        guard !isCapturing else { return }
        isCapturing = true
        isProcessing = true
        captureRawEnabled = rawEnabled && capabilities.supportsRAW && mode != .bracket
        pendingRawData = nil
        pendingProcessedData = nil
        if mode == .bracket {
            captureBracket()
        } else {
            coordinator.capturePhoto(rawEnabled: captureRawEnabled)
        }
    }

    func applyPreset(_ preset: ColorGradePreset) {
        selectedPreset = preset
        grade = preset.grade
    }

    func savePreset() {
        presetStore.saveCustom(name: "My Grade \(library.items.count + 1)", grade: grade)
    }

    private func captureBracket() {
        isBracketCapturing = true
        bracketFrames = []
        bracketFrameCount = 0
        let baseISO = iso
        for index in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.35) { [weak self] in
                guard let self else { return }
                self.iso = min(max(baseISO * Float(index + 1), self.capabilities.minimumISO), self.capabilities.maximumISO)
                self.applySettings()
                self.coordinator.capturePhoto(rawEnabled: false)
            }
        }
    }

    private func receivePhoto(_ data: Data, isRaw: Bool) {
        isProcessing = true
        if isRaw {
            pendingRawData = data
            finishRawCaptureIfReady()
            return
        }

        if captureRawEnabled {
            pendingProcessedData = data
            finishRawCaptureIfReady()
            return
        }

        if mode == .bracket {
            bracketFrames.append(data)
            bracketFrameCount = bracketFrames.count
            if bracketFrames.count == 3 {
                if let enhanced = pipeline.merge(data: bracketFrames, grade: grade, aspectRatio: aspectRatio) {
                    library.saveBracket(originals: bracketFrames, enhancedData: enhanced, grade: grade, metadata: metadata())
                } else {
                    errorMessage = "The bracket could not be merged."
                }
                bracketFrames = []
                bracketFrameCount = 3
                isBracketCapturing = false
                isCapturing = false
                isProcessing = false
            }
            return
        }
        if let enhanced = pipeline.process(data: data, grade: grade, aspectRatio: aspectRatio, enhanceLowLight: mode == .bracket || mode == .cinematic) {
            library.savePhoto(data: data, enhancedData: enhanced, grade: grade, metadata: metadata())
        }
        isCapturing = false
        isProcessing = false
    }

    private func finishRawCaptureIfReady() {
        guard captureRawEnabled,
              let rawData = pendingRawData,
              let processedData = pendingProcessedData else { return }
        if let enhanced = pipeline.process(data: processedData, grade: grade, aspectRatio: aspectRatio, enhanceLowLight: mode == .bracket || mode == .cinematic) {
            library.savePhoto(data: rawData, enhancedData: enhanced, grade: grade, metadata: metadata(), originalExtension: "dng")
        }
        pendingRawData = nil
        pendingProcessedData = nil
        isCapturing = false
        isProcessing = false
    }

    private func previewGrade(_ grade: GradeSettings) -> GradeSettings {
        var preview = grade
        preview.sharpen = min(grade.sharpen * 0.2, 0.08)
        preview.grain = 0
        return preview
    }

    private func metadata() -> [String: String] {
        [
            "mode": mode.rawValue,
            "iso": String(format: "%.0f", iso),
            "shutter": String(format: "%.5f", shutterDuration),
            "kelvin": String(format: "%.0f", kelvin),
            "tint": String(format: "%.1f", tint),
            "lens": activeLensName,
            "zoom": String(format: "%.2f", zoomFactor),
            "aspect_ratio": aspectRatio.title
        ]
    }
}
