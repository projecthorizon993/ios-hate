import CoreImage
import Foundation
import UIKit

enum NativeColorPreset: String, CaseIterable, Identifiable {
    case natural
    case cinematic
    case vivid
    case warm
    case cool
    case mono

    var id: String { rawValue }
}

struct NativeColorSettings: Equatable {
    var preset: NativeColorPreset = .natural
    var intensity: CGFloat = 1
    var exposure: CGFloat = 0
    var contrast: CGFloat = 1
    var saturation: CGFloat = 1
    var temperature: CGFloat = 0
    var tint: CGFloat = 0
    var vignette: CGFloat = 0
    var grain: CGFloat = 0

    static let natural = NativeColorSettings()
}

enum NativeColorEngine {
    private static let context = CIContext()

    static func processedJPEGData(from data: Data, settings: NativeColorSettings) -> Data? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let output = apply(image, settings: settings)
        guard let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.96)
    }

    static func apply(_ image: CIImage, settings: NativeColorSettings) -> CIImage {
        let intensity = min(max(settings.intensity, 0), 1)
        var output = image

        if settings.preset == .mono,
           let filter = CIFilter(name: "CIPhotoEffectMono") {
            filter.setValue(output, forKey: kCIInputImageKey)
            output = filter.outputImage ?? output
        }

        let controls = CIFilter(name: "CIColorControls")
        let presetContrast: CGFloat
        let presetSaturation: CGFloat
        switch settings.preset {
        case .cinematic:
            presetContrast = 1.10
            presetSaturation = 0.90
        case .vivid:
            presetContrast = 1.08
            presetSaturation = 1.25
        default:
            presetContrast = 1
            presetSaturation = 1
        }
        controls?.setValue(output, forKey: kCIInputImageKey)
        controls?.setValue(1 + (settings.exposure * 0.35), forKey: kCIInputEVKey)
        controls?.setValue(1 + ((settings.contrast - 1) * intensity) + ((presetContrast - 1) * intensity), forKey: kCIInputContrastKey)
        controls?.setValue(1 + ((settings.saturation - 1) * intensity) + ((presetSaturation - 1) * intensity), forKey: kCIInputSaturationKey)
        output = controls?.outputImage ?? output

        let presetTemperature: CGFloat
        switch settings.preset {
        case .warm: presetTemperature = -900
        case .cool: presetTemperature = 900
        default: presetTemperature = 0
        }
        let temperature = settings.temperature + presetTemperature
        if abs(temperature) > 0.001 || abs(settings.tint) > 0.001 {
            let filter = CIFilter(name: "CITemperatureAndTint")
            filter?.setValue(output, forKey: kCIInputImageKey)
            filter?.setValue(
                CIVector(
                    x: 6500 + Double(temperature * 1800 * intensity),
                    y: Double(settings.tint * 120 * intensity)
                ),
                forKey: "inputNeutral"
            )
            filter?.setValue(
                CIVector(
                    x: 6500 - Double(temperature * 900 * intensity),
                    y: Double(-settings.tint * 120 * intensity)
                ),
                forKey: "inputTargetNeutral"
            )
            output = filter?.outputImage ?? output
        }

        if abs(settings.vignette) > 0.001 {
            let filter = CIFilter(name: "CIVignette")
            filter?.setValue(output, forKey: kCIInputImageKey)
            filter?.setValue(2.0, forKey: kCIInputRadiusKey)
            filter?.setValue(Double(settings.vignette * intensity), forKey: kCIInputIntensityKey)
            output = filter?.outputImage ?? output
        }

        if abs(settings.grain) > 0.001 {
            let filter = CIFilter(name: "CINoiseReduction")
            filter?.setValue(output, forKey: kCIInputImageKey)
            filter?.setValue(Double(settings.grain * intensity * 0.04), forKey: "inputNoiseLevel")
            filter?.setValue(0.4, forKey: "inputSharpness")
            output = filter?.outputImage ?? output
        }

        return output
    }
}
