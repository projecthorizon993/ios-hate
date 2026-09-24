import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

struct ImagePipeline {
    private let context = CIContext(options: [.cacheIntermediates: true])

    func process(data: Data, grade: GradeSettings) -> Data? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let enhanced = LowLightEnhancer.enhance(image)
        guard let output = render(grade.apply(to: enhanced)) else { return nil }
        return UIImage(cgImage: output).jpegData(compressionQuality: 0.94)
    }

    func process(cgImage: CGImage, grade: GradeSettings) -> CGImage? {
        render(grade.apply(to: LowLightEnhancer.enhance(CIImage(cgImage: cgImage))))
    }

    func merge(data: [Data], grade: GradeSettings) -> Data? {
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
        guard let output = render(grade.apply(to: enhanced)) else { return nil }
        return UIImage(cgImage: output).jpegData(compressionQuality: 0.94)
    }

    private func render(_ image: CIImage) -> CGImage? {
        guard !image.extent.isNull && !image.extent.isInfinite else { return nil }
        return context.createCGImage(image, from: image.extent)
    }
}
