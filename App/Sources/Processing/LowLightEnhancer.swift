import CoreImage
import Foundation

struct LowLightEnhancer {
    static func enhance(_ image: CIImage) -> CIImage {
        let denoised = image.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": 0.018,
            "inputSharpness": 0.45
        ])
        return denoised.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputHighlightAmount": 0.5,
            "inputShadowAmount": 0.68
        ])
    }
}
