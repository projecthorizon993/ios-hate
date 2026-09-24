import AVFoundation
import CoreImage
import Foundation
import OSLog
import UIKit

final class CameraCoordinator: NSObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.lumaframe.camera.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.lumaframe.camera.video", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let imageContext = CIContext(options: [.cacheIntermediates: true])
    private let logger = Logger(subsystem: "com.lumaframe", category: "camera")
    private let frameScheduler = FrameScheduler()
    private var cameraDevice: AVCaptureDevice?
    private var primaryDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false
    private var videoRotationConfigured = false

    var onFrame: ((CGImage) -> Void)?
    var onPhoto: ((Data, Bool) -> Void)?
    var onConfigured: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onFrameTiming: ((FrameTiming) -> Void)?

    override init() {
        super.init()
        frameScheduler.onTiming = { [weak self] timing in
            DispatchQueue.main.async {
                self?.onFrameTiming?(timing)
            }
        }
    }

    func configure() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.configured {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.notifyConfigured(true)
                return
            }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            let deviceType: AVCaptureDevice.DeviceType
            if AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) != nil {
                deviceType = .builtInTripleCamera
            } else if AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) != nil {
                deviceType = .builtInDualWideCamera
            } else {
                deviceType = .builtInWideAngleCamera
            }
            guard let device = AVCaptureDevice.default(deviceType, for: .video, position: .back) else {
                self.session.commitConfiguration()
                self.notifyError("A back camera is not available on this device.")
                self.notifyConfigured(false)
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input), self.session.canAddOutput(self.photoOutput), self.session.canAddOutput(self.videoOutput) else {
                    self.session.commitConfiguration()
                    self.notifyError("The camera could not be configured for capture.")
                    self.notifyConfigured(false)
                    return
                }

                self.session.addInput(input)
                self.videoInput = input
                self.primaryDevice = device
                self.session.addOutput(self.photoOutput)
                self.session.addOutput(self.videoOutput)
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                if let connection = self.videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                self.cameraDevice = device
                self.configured = true
                self.session.commitConfiguration()
                self.session.startRunning()
                self.notifyConfigured(true)
            } catch {
                self.session.commitConfiguration()
                self.notifyError(error.localizedDescription)
                self.notifyConfigured(false)
            }
        }
    }

    func apply(settings: CaptureSettings) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.cameraDevice else { return }
            do {
                try device.lockForConfiguration()
                self.applyExposure(to: device, settings: settings)
                self.applyWhiteBalance(to: device, settings: settings)
                if settings.focusLocked {
                    if device.isFocusModeSupported(.locked) {
                        device.focusMode = .locked
                    }
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.custom) {
                    device.setExposureTargetBias(settings.exposureCompensation, completionHandler: nil)
                }
                let zoomFactor: CGFloat
                if device.deviceType == .builtInUltraWideCamera || device.deviceType == .builtInTelephotoCamera {
                    zoomFactor = 1
                } else {
                    zoomFactor = min(max(settings.zoomFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                }
                device.videoZoomFactor = zoomFactor
                device.unlockForConfiguration()
            } catch {
                self.notifyError("Camera settings could not be applied.")
            }
        }
    }

    func setZoomFactor(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, self.configured else { return }
            let requestedFactor = max(0.5, factor)
            if requestedFactor < 0.8,
               let ultraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back),
               self.cameraDevice?.deviceType != .builtInUltraWideCamera {
                self.switchInput(to: ultraWide)
            } else if requestedFactor >= 1.8,
                      let telephoto = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back),
                      self.cameraDevice?.deviceType != .builtInTelephotoCamera {
                self.switchInput(to: telephoto)
            } else if requestedFactor >= 0.8,
                      self.cameraDevice?.deviceType == .builtInUltraWideCamera,
                      let primary = self.primaryDevice {
                self.switchInput(to: primary)
            } else if requestedFactor < 1.8,
                      self.cameraDevice?.deviceType == .builtInTelephotoCamera,
                      let primary = self.primaryDevice {
                self.switchInput(to: primary)
            }

            guard let device = self.cameraDevice else { return }
            do {
                try device.lockForConfiguration()
                let deviceFactor = device.deviceType == .builtInUltraWideCamera || device.deviceType == .builtInTelephotoCamera
                    ? 1
                    : min(max(requestedFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                device.videoZoomFactor = deviceFactor
                device.unlockForConfiguration()
            } catch {
                self.notifyError("Zoom could not be changed.")
            }
        }
    }

    func capturePhoto(rawEnabled: Bool = false) {
        sessionQueue.async { [weak self] in
            guard let self, self.configured else { return }
            let processedFormat: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.jpeg]
            let settings: AVCapturePhotoSettings
            if rawEnabled,
               let rawPixelFormat = self.photoOutput.supportedRawPhotoPixelFormatTypes(for: .dng).first {
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawPixelFormat, processedFormat: processedFormat)
            } else {
                settings = AVCapturePhotoSettings(format: processedFormat)
            }
            settings.flashMode = .off
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func switchInput(to device: AVCaptureDevice) {
        guard let replacement = try? AVCaptureDeviceInput(device: device) else {
            notifyError("The selected lens could not be activated.")
            return
        }

        session.beginConfiguration()
        if let videoInput {
            session.removeInput(videoInput)
        }
        if session.canAddInput(replacement) {
            session.addInput(replacement)
            videoInput = replacement
            cameraDevice = device
        } else if let videoInput {
            session.addInput(videoInput)
            notifyError("The selected lens is not available.")
        }
        session.commitConfiguration()
    }

    private func applyExposure(to device: AVCaptureDevice, settings: CaptureSettings) {
        switch settings.mode {
        case .manual, .cinematic:
            let format = device.activeFormat
            let minimumDuration = max(format.minExposureDuration.seconds, 1.0 / 4000.0)
            let maximumDuration = min(format.maxExposureDuration.seconds, 1.0 / 30.0)
            let duration = min(max(settings.shutterDuration, minimumDuration), maximumDuration)
            let iso = min(max(settings.iso, format.minISO), format.maxISO)
            if device.isExposureModeSupported(.custom) {
                device.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000_000), iso: iso)
            }
        case .auto, .bracket:
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    private func applyWhiteBalance(to device: AVCaptureDevice, settings: CaptureSettings) {
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    private func notifyConfigured(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onConfigured?(value)
        }
    }

    private func notifyError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }
}

extension CameraCoordinator: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            if let error {
                notifyError(error.localizedDescription)
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onPhoto?(data, photo.isRawPhoto)
        }
    }
}

extension CameraCoordinator: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if !videoRotationConfigured, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
            videoRotationConfigured = true
        }
        frameScheduler.submit { [weak self] in
            guard let self, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let extent = image.extent
            let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            let scale = min(1, 1280 / max(normalized.extent.width, normalized.extent.height))
            let preview = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return self.imageContext.createCGImage(preview, from: preview.extent)
        } completion: { [weak self] image in
            guard let image else { return }
            DispatchQueue.main.async {
                self?.onFrame?(image)
            }
        }
    }
}
