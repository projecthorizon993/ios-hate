import AVFoundation
import CoreImage
import Foundation
import OSLog
import Photos
import SwiftUI
import UIKit

enum NativeCameraOutputType: CaseIterable {
    case photo
    case video
}

enum NativeCameraPosition {
    case back
    case front
}

enum NativeCameraFlashMode: CaseIterable {
    case off
    case on
    case auto
}

enum NativeCameraTorchMode {
    case off
    case on
}

enum NativeCameraHDRMode: CaseIterable {
    case off
    case on
    case auto
}

enum NativeCaptureFormat: Equatable {
    case processed
    case raw
}

enum NativeCameraLens: String, CaseIterable, Identifiable {
    case ultraWide
    case wide
    case telephoto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ultraWide: "0.5×"
        case .wide: "1×"
        case .telephoto: "3×"
        }
    }

    var baseFocalLength: Int {
        switch self {
        case .ultraWide: 13
        case .wide: 24
        case .telephoto: 77
        }
    }
}

enum NativeCameraError: Error {
    case inputUnavailable
    case outputUnavailable
    case recordingFailed
}

final class NativeCameraManager: NSObject, ObservableObject {
    @Published private(set) var outputType: NativeCameraOutputType = .photo
    @Published private(set) var captureFormat: NativeCaptureFormat = .processed
    @Published private(set) var isRawAvailable = false
    @Published private(set) var cameraPosition: NativeCameraPosition = .back
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var flashMode: NativeCameraFlashMode = .off
    @Published private(set) var torchMode: NativeCameraTorchMode = .off
    @Published private(set) var showGrid = true
    @Published private(set) var mirrorOutput = false
    @Published var iso: Float = 400
    @Published var exposureDuration = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 1_000_000_000)
    @Published var exposureTargetBias: Float = 0
    @Published private(set) var hasFlash = false
    @Published private(set) var hasTorch = false
    @Published private(set) var activeLens: NativeCameraLens = .wide
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var focusPosition: Float = 0.5
    @Published private(set) var frameRate: Int32 = 30
    @Published private(set) var resolution: AVCaptureSession.Preset = .photo
    @Published private(set) var isReconfiguring = false
    @Published private(set) var lastCapture: UIImage?
    @Published var colorSettings = NativeColorSettings.natural

    let session = AVCaptureSession()
    let availableLenses: [NativeCameraLens] = [
        .ultraWide, .wide, .telephoto
    ].filter { lens in
        switch lens {
        case .ultraWide:
            AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil
        case .wide:
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
        case .telephoto:
            AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil
        }
    }

    private let sessionQueue = DispatchQueue(label: "com.lumaframe.camera.session", qos: .userInitiated)
    private let photoProcessingQueue = DispatchQueue(label: "com.lumaframe.camera.photo-processing", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var rawPixelFormatType: OSType?
    private let logger = Logger(subsystem: "LumaFrame", category: "NativeCamera")
    private var currentInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var currentDevice: AVCaptureDevice?
    private var currentPosition: NativeCameraPosition = .back
    private var currentLens: NativeCameraLens = .wide
    private var pendingZoomAfterLensChange: CGFloat?
    private var wantsRunning = false
    private var currentRecordingURL: URL?
    private var cameraFilters: [CIFilter] = []
    private var lastAppliedISO: Float = -1
    private var lastAppliedDuration = CMTime.invalid

    override init() {
        super.init()
        if let firstLens = availableLenses.first(where: { $0 == .wide }) ?? availableLenses.first {
            currentLens = firstLens
        }
    }

    var professionalEquivalentFocalLength: Int {
        Int((CGFloat(activeLens.baseFocalLength) * max(1, zoomFactor)).rounded())
    }

    func start() {
        wantsRunning = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureAndStart()
                    }
                }
            }
        case .denied, .restricted:
            logger.error("Camera permission denied")
        @unknown default:
            logger.error("Camera permission state unavailable")
        }
    }

    func stop() {
        wantsRunning = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.isRecording = false
                self.recordingStartedAt = nil
            }
        }
    }

    func changeOutputType(_ newOutputType: NativeCameraOutputType) throws {
        guard newOutputType != outputType else { return }
        logger.notice("Output mode changed to \(String(describing: newOutputType), privacy: .public)")
        outputType = newOutputType
    }

    func setCaptureFormat(_ format: NativeCaptureFormat) {
        if format == .raw && !isRawAvailable { return }
        captureFormat = format
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let rawTypes = self.photoOutput.availableRawPhotoPixelFormatTypes
            let wantsRaw = format == .raw && !rawTypes.isEmpty
            self.photoOutput.isRawImageEnabled = wantsRaw
            if !wantsRaw {
                self.logger.notice("RAW capture disabled: no supported pixel format")
                DispatchQueue.main.async {
                    self.captureFormat = .processed
                    self.isRawAvailable = false
                }
            }
        }
    }

    func setColorPreset(_ preset: NativeColorPreset) {
        colorSettings.preset = preset
    }

    func updateColorSettings(_ settings: NativeColorSettings) {
        colorSettings = settings
    }

    func changeCamera(_ newPosition: NativeCameraPosition) throws {
        guard newPosition != cameraPosition, !isReconfiguring else { return }
        let oldPosition = cameraPosition
        let oldLens = activeLens
        let oldZoom = zoomFactor
        guard let device = Self.device(for: newPosition, lens: .wide) else {
            logger.error("Camera position unavailable: \(String(describing: newPosition), privacy: .public)")
            return
        }
        isReconfiguring = true
        cameraPosition = newPosition
        currentPosition = newPosition
        sessionQueue.async { [weak self] in
            self?.replaceInput(
                with: device,
                position: newPosition,
                lens: .wide,
                oldPosition: oldPosition,
                oldLens: oldLens,
                oldZoom: oldZoom
            )
        }
    }

    func setLens(_ lens: NativeCameraLens) {
        guard cameraPosition == .back, availableLenses.contains(lens), activeLens != lens, !isReconfiguring else { return }
        guard let device = Self.device(for: .back, lens: lens) else {
            logger.error("Lens unavailable: \(lens.rawValue, privacy: .public)")
            return
        }
        let oldPosition = cameraPosition
        let oldLens = activeLens
        let oldZoom = zoomFactor
        isReconfiguring = true
        sessionQueue.async { [weak self] in
            self?.replaceInput(
                with: device,
                position: .back,
                lens: lens,
                oldPosition: oldPosition,
                oldLens: oldLens,
                oldZoom: oldZoom
            )
        }
    }

    func setProfessionalZoom(_ value: CGFloat) {
        setZoom(value)
    }

    func setZoom(_ value: CGFloat) {
        let displayValue = min(max(value, 0.5), 3)
        let lens = cameraPosition == .back ? preferredLens(for: displayValue) : activeLens
        if lens != activeLens, availableLenses.contains(lens) {
            pendingZoomAfterLensChange = displayValue
            if !isReconfiguring {
                setLens(lens)
            }
        } else {
            applyDeviceZoom(displayValue: displayValue, lens: lens)
        }
    }

    private func preferredLens(for displayValue: CGFloat) -> NativeCameraLens {
        guard cameraPosition == .back else { return .wide }
        if displayValue < 0.8, availableLenses.contains(.ultraWide) {
            return .ultraWide
        }
        if displayValue > 1.6, availableLenses.contains(.telephoto) {
            return .telephoto
        }
        return availableLenses.contains(.wide) ? .wide : activeLens
    }

    private func applyDeviceZoom(displayValue: CGFloat, lens: NativeCameraLens) {
        let requestedZoom: CGFloat
        switch lens {
        case .ultraWide, .telephoto:
            requestedZoom = 1
        case .wide:
            requestedZoom = min(max(displayValue, 1), 3)
        }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            let maximum = min(3, device.maxAvailableVideoZoomFactor)
            let zoom = min(max(requestedZoom, device.minAvailableVideoZoomFactor), maximum)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = zoom
                device.unlockForConfiguration()
                DispatchQueue.main.async { [weak self] in
                    self?.zoomFactor = displayValue
                }
            } catch {
                self.logger.error("Zoom configuration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func changeZoomFactor(_ value: CGFloat) throws {
        setZoom(value)
    }

    func changeFlashMode(_ mode: NativeCameraFlashMode) throws {
        guard hasFlash else { return }
        flashMode = mode
    }

    func changeTorchMode(_ mode: NativeCameraTorchMode) throws {
        guard hasTorch else { return }
        torchMode = mode
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = mode == .on ? .on : .off
                device.unlockForConfiguration()
            } catch {
                self.logger.error("Torch configuration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func changeGridVisibility(_ shouldShowGrid: Bool) throws {
        showGrid = shouldShowGrid
    }

    func changeMirrorOutputMode(_ shouldMirror: Bool) {
        guard mirrorOutput != shouldMirror else { return }
        mirrorOutput = shouldMirror
        sessionQueue.async { [weak self] in
            self?.configureConnections()
        }
    }

    func changeExposureMode(_ mode: AVCaptureDevice.ExposureMode) throws {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice, device.isExposureModeSupported(mode) else { return }
            do {
                try device.lockForConfiguration()
                device.exposureMode = mode
                device.unlockForConfiguration()
            } catch {
                self.logger.error("Exposure mode configuration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func changeISO(_ value: Float) throws {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice, device.isExposureModeSupported(.custom) else { return }
            let format = device.activeFormat
            guard let iso = Self.nearestSupportedISO(value, in: format) else {
                self.logger.error("ISO change skipped: device reported no supported ISO values")
                return
            }
            guard iso != self.lastAppliedISO else { return }
            let duration = Self.nearestSupportedDuration(device.exposureDuration, in: format)
                ?? device.exposureDuration
            self.lastAppliedISO = iso
            device.setExposureModeCustom(duration: duration, iso: iso) { _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.iso = iso
                }
            }
        }
    }

    func changeExposureDuration(_ value: CMTime) throws {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice, device.isExposureModeSupported(.custom) else { return }
            let format = device.activeFormat
            guard let duration = Self.nearestSupportedDuration(value, in: format) else {
                self.logger.error("Shutter change skipped: device reported no supported exposure durations")
                return
            }
            guard duration != self.lastAppliedDuration else { return }
            let iso = Self.nearestSupportedISO(device.iso, in: format) ?? device.iso
            self.lastAppliedDuration = duration
            self.lastAppliedISO = iso
            device.setExposureModeCustom(duration: duration, iso: iso) { _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.exposureDuration = duration
                    self.iso = iso
                }
            }
        }
    }

    private static func nearestSupportedISO(_ value: Float, in format: AVCaptureDevice.Format) -> Float? {
        let supported = format.supportedISOs
        guard !supported.isEmpty else { return nil }
        return supported.min { abs($0 - value) < abs($1 - value) }
    }

    private static func nearestSupportedDuration(
        _ value: CMTime,
        in format: AVCaptureDevice.Format
    ) -> CMTime? {
        let supported = format.supportedExposureDurations
        guard !supported.isEmpty else { return nil }
        let target = CMTimeGetSeconds(value)
        return supported.min { abs(CMTimeGetSeconds($0) - target) < abs(CMTimeGetSeconds($1) - target) }
    }

    func changeExposureTargetBias(_ value: Float) throws {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            let clamped = min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clamped)
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.exposureTargetBias = clamped
                }
            } catch {
                self.logger.error("Exposure bias configuration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func changeFocusPosition(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) {
                    device.setFocusModeLocked(lensPosition: clamped)
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { [weak self] in
                    self?.focusPosition = clamped
                }
            } catch {
                self.logger.error("Focus configuration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func changeCameraFilters(_ filters: [CIFilter]) throws {
        cameraFilters = filters
    }

    func changeResolution(_ preset: AVCaptureSession.Preset) throws {
        sessionQueue.async { [weak self] in
            guard let self, self.session.canSetSessionPreset(preset) else { return }
            self.session.sessionPreset = preset
            DispatchQueue.main.async { [weak self] in
                self?.resolution = preset
            }
        }
    }

    func changeFrameRate(_ frameRate: Int32) throws {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            do {
                try device.lockForConfiguration()
                let isSupported = device.activeFormat.videoSupportedFrameRateRanges.contains { range in
                    duration >= range.minFrameDuration && duration <= range.maxFrameDuration
                }
                if isSupported {
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                    DispatchQueue.main.async { [weak self] in
                        self?.frameRate = frameRate
                    }
                } else {
                    self.logger.error("Frame rate \(frameRate) unsupported by active format")
                }
                device.unlockForConfiguration()
            } catch {
                self.logger.error("Frame rate configuration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func changeHDRMode(_ mode: NativeCameraHDRMode) throws {
        logger.debug("HDR mode requested: \(String(describing: mode), privacy: .public)")
    }

    func captureOutput() {
        switch outputType {
        case .photo:
            capturePhoto()
        case .video:
            toggleVideoRecording()
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.currentInput == nil {
                self.configureSession()
            }
            guard self.currentInput != nil else {
                DispatchQueue.main.async {
                    self.isRunning = false
                }
                return
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = self.session.isRunning
                self.publishDeviceState()
            }
        }
    }

    private func refreshRawAvailability() {
        let available = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        rawPixelFormatType = photoOutput.availableRawPhotoPixelFormatTypes.first
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRawAvailable = available
            if !available, self.captureFormat == .raw {
                self.captureFormat = .processed
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canSetSessionPreset(.photo) else {
            logger.error("Photo session preset unavailable")
            return
        }
        session.sessionPreset = .photo
        guard let device = Self.device(for: .back, lens: currentLens) ?? AVCaptureDevice.default(for: .video) else {
            logger.error("Camera device unavailable")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                logger.error("Camera input rejected")
                return
            }
            session.addInput(input)
            currentInput = input
            currentDevice = device
            photoOutput.maxPhotoQualityPrioritization = .quality
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            } else {
                logger.error("Photo output rejected")
            }
            if session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
            } else {
                logger.error("Movie output rejected")
            }
            configureConnections()
            refreshRawAvailability()
        } catch {
            logger.error("Camera session setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func replaceInput(
        with device: AVCaptureDevice,
        position: NativeCameraPosition,
        lens: NativeCameraLens,
        oldPosition: NativeCameraPosition,
        oldLens: NativeCameraLens,
        oldZoom: CGFloat
    ) {
        let wasRunning = session.isRunning
        if wasRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        let oldInput = currentInput
        if let oldInput {
            session.removeInput(oldInput)
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw NativeCameraError.inputUnavailable
            }
            session.addInput(input)
            currentInput = input
            currentDevice = device
            currentPosition = position
            currentLens = lens
            configureConnections()
            session.commitConfiguration()
            refreshRawAvailability()
            if wasRunning || wantsRunning {
                session.startRunning()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let pendingZoom = self.pendingZoomAfterLensChange
                self.pendingZoomAfterLensChange = nil
                self.activeLens = lens
                self.cameraPosition = position
                self.zoomFactor = pendingZoom ?? 1
                self.isRunning = self.session.isRunning
                self.isReconfiguring = false
                self.publishDeviceState()
                if let pendingZoom {
                    self.setZoom(pendingZoom)
                }
            }
        } catch {
            if let oldInput, session.canAddInput(oldInput) {
                session.addInput(oldInput)
            }
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingZoomAfterLensChange = nil
                self.cameraPosition = oldPosition
                self.activeLens = oldLens
                self.zoomFactor = oldZoom
                self.isRunning = self.session.isRunning
                self.isReconfiguring = false
                self.publishDeviceState()
            }
            logger.error("Camera input replacement failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func configureConnections() {
        for output in [photoOutput, movieOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = mirrorOutput ? currentPosition != .front : currentPosition == .front
            }
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }

    private func publishDeviceState() {
        guard let device = currentInput?.device else { return }
        let newISO = device.iso
        let newExposureDuration = device.exposureDuration
        let newExposureTargetBias = device.exposureTargetBias
        let newFocusPosition = device.lensPosition
        let newHasFlash = device.hasFlash
        let newHasTorch = device.hasTorch
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.iso = newISO
            self.exposureDuration = newExposureDuration
            self.exposureTargetBias = newExposureTargetBias
            self.focusPosition = newFocusPosition
            self.hasFlash = newHasFlash
            self.hasTorch = newHasTorch
        }
    }

    private func capturePhoto() {
        let requestedFlash = flashMode
        let flashAvailable = hasFlash
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let wantsRaw = self.captureFormat == .raw
            let rawTypes = wantsRaw ? self.photoOutput.availableRawPhotoPixelFormatTypes : []
            let settings: AVCapturePhotoSettings
            if let rawType = rawTypes.first {
                let codec: AVVideoCodecType = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
                    ? .hevc
                    : .jpeg
                settings = AVCapturePhotoSettings(
                    rawPixelFormatType: rawType,
                    processedFormat: [AVVideoCodecKey: codec]
                )
                self.photoOutput.isRawImageEnabled = true
                self.logger.notice("RAW capture using pixel format \(rawType)")
            } else {
                if wantsRaw {
                    self.logger.error("RAW pixel format unavailable at capture time; using processed")
                    DispatchQueue.main.async {
                        self.captureFormat = .processed
                        self.isRawAvailable = false
                    }
                }
                self.photoOutput.isRawImageEnabled = false
                settings = AVCapturePhotoSettings()
            }
            settings.photoQualityPrioritization = .quality
            if flashAvailable {
                settings.flashMode = switch requestedFlash {
                case .off: .off
                case .on: .on
                case .auto: .auto
                }
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func toggleVideoRecording() {
        if movieOutput.isRecording {
            sessionQueue.async { [weak self] in
                self?.movieOutput.stopRecording()
            }
            isRecording = false
            recordingStartedAt = nil
        } else {
            requestAudioPermissionAndRecord()
        }
    }

    private func requestAudioPermissionAndRecord() {
        let begin: @Sendable (Bool) -> Void = { [weak self] _ in
            self?.beginRecording()
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: begin)
        case .denied, .restricted:
            begin(false)
        @unknown default:
            begin(false)
        }
    }

    private func beginRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.audioInput == nil,
               let microphone = AVCaptureDevice.default(for: .audio) {
                do {
                    let input = try AVCaptureDeviceInput(device: microphone)
                    self.session.beginConfiguration()
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.audioInput = input
                    }
                    self.session.commitConfiguration()
                } catch {
                    self.logger.error("Audio input setup failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("LumaFrame-Video-\(UUID().uuidString).mov")
            self.currentRecordingURL = url
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async {
                self.isRecording = self.movieOutput.isRecording
                self.recordingStartedAt = self.movieOutput.isRecording ? Date() : nil
            }
        }
    }

    private func saveRawPhotoData(_ data: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaFrame-RAW-\(UUID().uuidString).dng")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("RAW file creation failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: url)
                self.logger.error("RAW save skipped: authorization denied")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                options.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: url, options: options)
            }, completionHandler: { [weak self] success, error in
                try? FileManager.default.removeItem(at: url)
                if success {
                    self?.logger.notice("RAW saved to library")
                } else if let error {
                    self?.logger.error("RAW library save failed: \(error.localizedDescription, privacy: .public)")
                }
            })
        }
    }

    private func savePhotoData(_ data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                self.logger.error("Photo library save skipped: authorization denied")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { [weak self] success, error in
                if success {
                    self?.logger.notice("Photo saved to library")
                } else if let error {
                    self?.logger.error("Photo library save failed: \(error.localizedDescription, privacy: .public)")
                }
            })
        }
    }

    private func saveVideo(at url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: url, options: options)
            }, completionHandler: { [weak self] success, error in
                try? FileManager.default.removeItem(at: url)
                if success {
                    self?.logger.notice("Video saved to library")
                } else if let error {
                    self?.logger.error("Video library save failed: \(error.localizedDescription, privacy: .public)")
                }
            })
        }
    }

    private static func device(for position: NativeCameraPosition, lens: NativeCameraLens) -> AVCaptureDevice? {
        if position == .front {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        let type: AVCaptureDevice.DeviceType
        switch lens {
        case .ultraWide:
            type = .builtInUltraWideCamera
        case .wide:
            type = .builtInWideAngleCamera
        case .telephoto:
            type = .builtInTelephotoCamera
        }
        return AVCaptureDevice.default(type, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
    }
}

extension NativeCameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Swift.Error)?) {
        if let error {
            logger.error("Photo capture failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            logger.error("Photo capture returned no data")
            return
        }
        let isRaw = photo.isRawPhoto
        let settings = colorSettings
        photoProcessingQueue.async { [weak self] in
            guard let self else { return }
            if isRaw {
                self.saveRawPhotoData(data)
                self.logger.notice("RAW photo capture completed")
                return
            }
            let processedData: Data
            if settings == .natural {
                processedData = data
            } else if let sourceImage = UIImage(data: data) {
                processedData = NativeColorEngine.processedJPEGData(from: sourceImage, settings: settings) ?? data
            } else {
                processedData = data
            }
            let image = UIImage(data: processedData)
            DispatchQueue.main.async { [weak self] in
                self?.lastCapture = image
            }
            self.savePhotoData(processedData)
            self.logger.notice("Photo capture completed")
        }
    }
}

extension NativeCameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: (any Swift.Error)?) {
        if let error {
            logger.error("Video capture failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: outputFileURL)
        } else {
            saveVideo(at: outputFileURL)
        }
        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
            self?.recordingStartedAt = nil
        }
    }
}

struct NativeCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> NativeCameraPreviewView {
        let view = NativeCameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: NativeCameraPreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.previewLayer.videoGravity = .resizeAspectFill
    }

    static func dismantleUIView(_ uiView: NativeCameraPreviewView, coordinator: ()) {
        uiView.previewLayer.session = nil
    }
}

final class NativeCameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
