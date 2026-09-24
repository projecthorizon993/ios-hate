import AVFoundation
import Foundation


struct LensDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: AVCaptureDevice.DeviceType
    let position: AVCaptureDevice.Position
}

struct DeviceCapabilities: Sendable {
    let lenses: [LensDescriptor]
    let minimumZoomFactor: CGFloat
    let maximumZoomFactor: CGFloat
    let minimumISO: Float
    let maximumISO: Float
    let minimumExposureDuration: Double
    let maximumExposureDuration: Double
    let supportsRAW: Bool

    static let fallback = DeviceCapabilities(
        lenses: [LensDescriptor(id: "wide", name: "Wide", type: .builtInWideAngleCamera, position: .back)],
        minimumZoomFactor: 1,
        maximumZoomFactor: 1,
        minimumISO: 32,
        maximumISO: 3200,
        minimumExposureDuration: 1.0 / 4000.0,
        maximumExposureDuration: 1.0 / 30.0,
        supportsRAW: false
    )

    static func discover() -> DeviceCapabilities {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInUltraWideCamera,
                .builtInWideAngleCamera,
                .builtInTelephotoCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera
            ],
            mediaType: .video,
            position: .back
        )
        let devices = discovery.devices
        let seen = Set(devices.map { $0.deviceType.rawValue })
        let lenses = devices
            .filter { device in device.position == .back && seen.contains(device.deviceType.rawValue) }
            .enumerated()
            .map { index, device in
                LensDescriptor(
                    id: device.deviceType.rawValue + String(index),
                    name: displayName(for: device.deviceType),
                    type: device.deviceType,
                    position: device.position
                )
            }
        let device = devices.first
        let format = device?.activeFormat
        let minZoom = device?.minAvailableVideoZoomFactor ?? 1
        let maxZoom = device?.maxAvailableVideoZoomFactor ?? 1
        let supportsRAW = !AVCapturePhotoOutput().supportedRawPhotoPixelFormatTypes(for: .dng).isEmpty
        return DeviceCapabilities(
            lenses: lenses.isEmpty ? fallback.lenses : lenses,
            minimumZoomFactor: minZoom,
            maximumZoomFactor: max(maxZoom, minZoom),
            minimumISO: max(format?.minISO ?? fallback.minimumISO, 1),
            maximumISO: min(max(format?.maxISO ?? fallback.maximumISO, fallback.minimumISO), 12800),
            minimumExposureDuration: max(format?.minExposureDuration.seconds ?? fallback.minimumExposureDuration, 1.0 / 4000.0),
            maximumExposureDuration: max(format?.maxExposureDuration.seconds ?? fallback.maximumExposureDuration, fallback.minimumExposureDuration),
            supportsRAW: supportsRAW
        )
    }

    private static func displayName(for type: AVCaptureDevice.DeviceType) -> String {
        switch type {
        case .builtInUltraWideCamera:
            return "0.5× Ultra Wide"
        case .builtInTelephotoCamera:
            return "3× Telephoto"
        default:
            return "1× Wide"
        }
    }
}
