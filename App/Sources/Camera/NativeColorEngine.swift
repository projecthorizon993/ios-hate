import CoreImage
import Foundation
import UIKit

enum NativeColorEngine {
    static func processedJPEGData(from image: UIImage, settings: NativeColorSettings) -> Data? {
        guard let input = CIImage(image: image) else { return nil }
        let controls = CIFilter(name: "CIColorControls")
        let intensity = min(max(settings.intensity, 0), 1)
        let contrast = 1 + ((settings.contrast - 1) * intensity)
        let saturation = 1 + ((settings.saturation - 1) * intensity)
        let exposure = 1 + (settings.exposure * 0.35)
        controls?.setValue(input, forKey: kCIInputImageKey)
        controls?.setValue(NSNumber(value: Double(exposure)), forKey: kCIInputEVKey)
        controls?.setValue(NSNumber(value: Double(contrast)), forKey: kCIInputContrastKey)
        controls?.setValue(NSNumber(value: Double(saturation)), forKey: kCIInputSaturationKey)

        guard let output = controls?.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }

        let renderedImage = UIImage(
            cgImage: cgImage,
            scale: image.scale,
            orientation: image.imageOrientation
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = renderedImage.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: renderedImage.size, format: format)
        let gradedImage = renderer.image { rendererContext in
            renderedImage.draw(in: CGRect(origin: .zero, size: renderedImage.size))
            let temperature = min(max(settings.temperature, -1), 1)
            let tint = min(max(settings.tint, -1), 1)
            let temperatureAmount = abs(temperature) * 0.20
            if temperatureAmount > 0.001 {
                let color: UIColor
                if temperature >= 0 {
                    color = UIColor(red: 1, green: 0.88, blue: 0.68, alpha: temperatureAmount)
                } else {
                    color = UIColor(red: 0.68, green: 0.88, blue: 1, alpha: temperatureAmount)
                }
                color.setFill()
                rendererContext.fill(CGRect(origin: .zero, size: renderedImage.size))
            }
            let tintAmount = abs(tint) * 0.10
            if tintAmount > 0.001 {
                let color: UIColor
                if tint >= 0 {
                    color = UIColor(red: 0.86, green: 0.72, blue: 1, alpha: tintAmount)
                } else {
                    color = UIColor(red: 0.72, green: 1, blue: 0.86, alpha: tintAmount)
                }
                color.setFill()
                rendererContext.fill(CGRect(origin: .zero, size: renderedImage.size))
            }
        }
        return gradedImage.jpegData(compressionQuality: 0.96)
    }
}
