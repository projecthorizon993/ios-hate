import CoreImage
import Foundation

struct LowLightEnhancer {
    static func enhance(_ image: CIImage) -> CIImage {
        let denoised = image.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": 0.03,
            "inputSharpness": 0.22
        ])
        return denoised.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputHighlightAmount": 0.5,
            "inputShadowAmount": 0.68
        ])
    }
}
