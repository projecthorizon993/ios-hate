import AVFoundation
import CoreImage
import Foundation
import UIKit

final class CameraCoordinator: NSObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.lumaframe.camera.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.lumaframe.camera.video", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let imageContext = CIContext(options: [.cacheIntermediates: true])
    private let frameScheduler = FrameScheduler()
    private var cameraDevice: AVCaptureDevice?
    private var configured = false

    var onFrame: ((CGImage) -> Void)?
    var onPhoto: ((Data) -> Void)?
    var onConfigured: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    func configure() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.configured else {
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
                self.session.addOutput(self.photoOutput)
                self.session.addOutput(self.videoOutput)
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                self.photoOutput.maxPhotoQualityPrioritization = .quality
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
                    device.exposureTargetBias = settings.exposureCompensation
                }
                if device.isZoomFactorSupported(settings.zoomFactor) {
                    device.videoZoomFactor = settings.zoomFactor
                }
                device.unlockForConfiguration()
            } catch {
                self.notifyError("Camera settings could not be applied.")
            }
        }
    }

    func setZoomFactor(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.cameraDevice else { return }
            do {
                try device.lockForConfiguration()
                let factor = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                if device.isZoomFactorSupported(factor) {
                    device.videoZoomFactor = factor
                }
                device.unlockForConfiguration()
            } catch {
                self.notifyError("Zoom could not be changed.")
            }
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self, self.configured else { return }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.flashMode = .off
            settings.photoQualityPrioritization = .quality
            if self.photoOutput.supportedFlashModes.contains(.off) {
                settings.flashMode = .off
            }
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
        guard settings.mode == .manual || settings.mode == .cinematic else {
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            return
        }

        guard device.isWhiteBalanceModeSupported(.locked) else { return }
        let temperature = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: settings.kelvin, tint: settings.tint)
        let clampedTemperature = min(max(temperature.temperature, device.minWhiteBalanceTemperature), device.maxWhiteBalanceTemperature)
        let clampedTint = min(max(temperature.tint, device.minWhiteBalanceTint), device.maxWhiteBalanceTint)
        device.setWhiteBalanceModeLocked(with: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: clampedTemperature, tint: clampedTint), completionHandler: nil)
    }

    private func notifyConfigured(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onConfigured?(value)
        }
    }

    private func notifyError(_ message: String) {
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
            self?.onPhoto?(data)
        }
    }
}

extension CameraCoordinator: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameScheduler.submit { [weak self] in
            guard let self, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let extent = image.extent
            let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            return self.imageContext.createCGImage(normalized, from: normalized.extent)
        } completion: { [weak self] image in
            guard let image else { return }
            DispatchQueue.main.async {
                self?.onFrame?(image)
            }
        }
    }
}
