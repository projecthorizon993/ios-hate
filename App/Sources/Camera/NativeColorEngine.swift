import CoreImage
import Foundation
import UIKit

enum NativeColorEngine {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func processedJPEGData(from image: UIImage, settings: NativeColorSettings) -> Data? {
        let resolved = settings.resolved()
        guard !resolved.isIdentity else { return nil }

        guard let input = CIImage(image: image) else { return nil }

        var output = input

        if abs(resolved.exposure) > 0.001
            || abs(resolved.contrast - 1) > 0.001
            || abs(resolved.saturation - 1) > 0.001,
           let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(output, forKey: kCIInputImageKey)
            controls.setValue(resolved.exposure, forKey: kCIInputEVKey)
            controls.setValue(resolved.contrast, forKey: kCIInputContrastKey)
            controls.setValue(resolved.saturation, forKey: kCIInputSaturationKey)
            if let filtered = controls.outputImage {
                output = filtered
            }
        }

        if abs(resolved.temperature) > 0.001 || abs(resolved.tint) > 0.001,
           let whiteBalance = CIFilter(name: "CITemperatureAndTint") {
            whiteBalance.setValue(output, forKey: kCIInputImageKey)
            whiteBalance.setValue(6500 + (Double(resolved.temperature) * 3200), forKey: "inputNeutral")
            whiteBalance.setValue(6500, forKey: "inputTargetNeutral")
            whiteBalance.setValue(Double(resolved.tint) * 120, forKey: "inputNeutralT")
            whiteBalance.setValue(0, forKey: "inputTargetNeutralT")
            if let filtered = whiteBalance.outputImage {
                output = filtered
            }
        }

        guard let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }

        let rendered = UIImage(
            cgImage: cgImage,
            scale: image.scale,
            orientation: image.imageOrientation
        )
        return rendered.jpegData(compressionQuality: 0.95)
    }
}
