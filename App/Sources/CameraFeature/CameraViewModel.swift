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
    @Published private(set) var isConfigured = false

    let coordinator: CameraCoordinator
    let library: MediaLibrary
    let presetStore: PresetStore
    let diagnostics: DiagnosticsLog
    let performanceMonitor: PerformanceMonitor

    private let pipeline = ImagePipeline()
    private let previewPipeline = ImagePipeline()
    private let previewQueue = DispatchQueue(label: "com.lumaframe.preview.processing", qos: .userInitiated)
    private var bracketFrames: [Data] = []
    private var isPreviewProcessing = false

    init() {
        coordinator = CameraCoordinator()
        library = MediaLibrary()
        presetStore = PresetStore()
        diagnostics = DiagnosticsLog()
        performanceMonitor = PerformanceMonitor()
        performanceMonitor.start()
        coordinator.onFrame = { [weak self] image in
            guard let self, !self.isPreviewProcessing else { return }
            self.isPreviewProcessing = true
            let grade = self.grade
            self.previewQueue.async { [weak self] in
                guard let self else { return }
                let processed = self.previewPipeline.process(cgImage: image, grade: grade) ?? image
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isPreviewProcessing = false
                    self.performanceMonitor.recordFrame()
                    self.processedFrame = UIImage(cgImage: processed)
                }
            }
        }
        coordinator.onPhoto = { [weak self] data in
            self?.receivePhoto(data)
        }
        coordinator.onConfigured = { [weak self] success in
            guard let self else { return }
            self.isConfigured = success
            if success {
                self.capabilities = DeviceCapabilities.discover()
                self.zoomFactor = max(self.capabilities.minimumZoomFactor, min(1, self.capabilities.maximumZoomFactor))
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

    var activeLensName: String {
        let hasUltraWide = capabilities.lenses.contains { $0.name.contains("Ultra") }
        let hasTelephoto = capabilities.lenses.contains { $0.name.contains("Telephoto") }
        if hasUltraWide && zoomFactor < 0.8 { return "0.5× Ultra Wide" }
        if hasTelephoto && zoomFactor > 1.8 { return "3× Telephoto" }
        return "1× Wide"
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
            selectedPreset = ColorGradePreset.builtIns[1]
            grade = selectedPreset.grade
        } else if newMode == .manual {
            shutterDuration = 1.0 / 60.0
        }
        if isConfigured {
            applySettings()
        }
    }

    func setZoom(_ value: CGFloat) {
        guard isConfigured else { return }
        zoomFactor = min(max(value, capabilities.minimumZoomFactor), capabilities.maximumZoomFactor)
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
        if mode == .bracket {
            captureBracket()
        } else {
            coordinator.capturePhoto()
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
                self.coordinator.capturePhoto()
            }
        }
    }

    private func receivePhoto(_ data: Data) {
        isProcessing = true
        if mode == .bracket {
            bracketFrames.append(data)
            bracketFrameCount = bracketFrames.count
            if bracketFrames.count == 3 {
                if let enhanced = pipeline.merge(data: bracketFrames, grade: grade) {
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
        if let enhanced = pipeline.process(data: data, grade: grade) {
            library.savePhoto(data: data, enhancedData: enhanced, grade: grade, metadata: metadata())
        }
        isCapturing = false
        isProcessing = false
    }

    private func metadata() -> [String: String] {
        [
            "mode": mode.rawValue,
            "iso": String(format: "%.0f", iso),
            "shutter": String(format: "%.5f", shutterDuration),
            "kelvin": String(format: "%.0f", kelvin),
            "tint": String(format: "%.1f", tint),
            "lens": activeLensName,
            "zoom": String(format: "%.2f", zoomFactor)
        ]
    }
}
