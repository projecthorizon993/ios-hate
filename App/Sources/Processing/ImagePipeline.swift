import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import os.log
import UIKit

struct ImagePipeline {
    private let context = CIContext(options: [.cacheIntermediates: true])
    private let signpostLog = OSLog(subsystem: "com.lumaframe", category: .pointsOfInterest)

    func process(data: Data, grade: GradeSettings, aspectRatio: CaptureAspectRatio = .original, enhanceLowLight: Bool = true) -> Data? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let enhanced = enhanceLowLight ? LowLightEnhancer.enhance(image) : image
        let cropped = crop(enhanced, to: aspectRatio)
        guard let output = render(grade.apply(to: cropped)) else { return nil }
        return UIImage(cgImage: output).jpegData(compressionQuality: 0.98)
    }

    func processPreview(cgImage: CGImage, grade: GradeSettings, enhanceLowLight: Bool = false, maxDimension: CGFloat = 1280) -> CGImage? {
        os_signpost(.begin, log: signpostLog, name: "Preview grade processing")
        defer { os_signpost(.end, log: signpostLog, name: "Preview grade processing") }
        let source = CIImage(cgImage: cgImage)
        let scale = min(1, maxDimension / max(source.extent.width, source.extent.height))
        let resized = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var image = resized
        if enhanceLowLight {
            image = image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.035,
                "inputSharpness": 0.12
            ])
        }
        image = image.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: grade.contrast,
            kCIInputSaturationKey: grade.saturation,
            kCIInputBrightnessKey: 0
        ])
        if grade.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: grade.exposure])
        }
        return render(image)
    }

    func process(cgImage: CGImage, grade: GradeSettings) -> CGImage? {
        render(grade.apply(to: LowLightEnhancer.enhance(CIImage(cgImage: cgImage))))
    }

    func merge(data: [Data], grade: GradeSettings, aspectRatio: CaptureAspectRatio = .original) -> Data? {
        guard !data.isEmpty else { return nil }
        let images = data.compactMap { CIImage(data: $0, options: [.applyOrientationProperty: true]) }
        guard let first = images.first else { return nil }
        let extent = first.extent
        let normalized = images.map { image in
            image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        }
        var stack = normalized.first!
        for image in normalized.dropFirst() {
            stack = stack.applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: image
            ])
        }
        let average = stack.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 / CGFloat(images.count), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 / CGFloat(images.count), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 / CGFloat(images.count), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 / CGFloat(images.count))
        ])
        let adjusted = average.cropped(to: extent)
        let enhanced = LowLightEnhancer.enhance(adjusted)
        let cropped = crop(enhanced, to: aspectRatio)
        guard let output = render(grade.apply(to: cropped)) else { return nil }
        return UIImage(cgImage: output).jpegData(compressionQuality: 0.98)
    }

    private func crop(_ image: CIImage, to aspectRatio: CaptureAspectRatio) -> CIImage {
        guard let target = aspectRatio.value else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let current = extent.width / extent.height
        var cropRect = extent
        if current > target {
            let width = extent.height * target
            cropRect.origin.x += (extent.width - width) / 2
            cropRect.size.width = width
        } else {
            let height = extent.width / target
            cropRect.origin.y += (extent.height - height) / 2
            cropRect.size.height = height
        }
        return image.cropped(to: cropRect)
    }

    private func render(_ image: CIImage) -> CGImage? {
        guard !image.extent.isNull && !image.extent.isInfinite else { return nil }
        return context.createCGImage(image, from: image.extent)
    }
}
