import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case bracket
    case manual
    case cinematic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .bracket: return "Bracket"
        case .manual: return "Manual"
        case .cinematic: return "Cine"
        }
    }

    var shortTitle: String {
        switch self {
        case .auto: return "PHOTO"
        case .bracket: return "NIGHT"
        case .manual: return "PRO"
        case .cinematic: return "CINE"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "sparkles"
        case .bracket: return "rectangle.stack"
        case .manual: return "slider.horizontal.3"
        case .cinematic: return "film"
        }
    }
}

struct GradeSettings: Codable, Equatable, Hashable, Sendable {
    var exposure = 0.0
    var contrast = 1.0
    var highlights = 0.5
    var shadows = 0.5
    var whites = 0.5
    var blacks = 0.5
    var temperature = 0.0
    var tint = 0.0
    var saturation = 1.0
    var vibrance = 0.0
    var hue = 0.0
    var sharpen = 0.12
    var grain = 0.0
    var halation = 0.0
    var vignette = 0.0

    static let neutral = GradeSettings()

    func apply(to source: CIImage) -> CIImage {
        var image = source
        image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
        image = image.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: contrast,
            kCIInputSaturationKey: saturation,
            kCIInputBrightnessKey: (whites - blacks) * 0.08
        ])
        image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputHighlightAmount": highlights,
            "inputShadowAmount": shadows
        ])
        image = image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: 6500 + temperature * 2800, y: tint * 100)
        ])
        image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": vibrance])
        if hue != 0 {
            image = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: hue * .pi])
        }
        if sharpen > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: sharpen,
                kCIInputRadiusKey: 1.2
            ])
        }
        if halation > 0 {
            image = image.applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: 8.0,
                kCIInputIntensityKey: halation * 0.35
            ])
        }
        if vignette > 0 {
            image = image.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: vignette,
                kCIInputRadiusKey: 1.4
            ])
        }
        return image
    }
}

struct ColorGradePreset: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var version: Int
    var grade: GradeSettings
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, version: Int = 1, grade: GradeSettings, isBuiltIn: Bool = false) {
        if isBuiltIn, let stableID = Self.stableIDs[name] {
            self.id = stableID
        } else {
            self.id = id
        }
        self.name = name
        self.version = version
        self.grade = grade
        self.isBuiltIn = isBuiltIn
    }

    private static let stableIDs: [String: UUID] = [
        "Natural": UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        "Cinematic": UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        "Portrait": UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        "Vivid": UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        "Noir": UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        "Warm Film": UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
        "Cool Night": UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
        "Urban Contrast": UUID(uuidString: "00000000-0000-0000-0000-000000000008")!,
        "Soft Pastel": UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
        "Black and White": UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    ]

    static let builtIns: [ColorGradePreset] = [
        ColorGradePreset(name: "Natural", grade: GradeSettings(), isBuiltIn: true),
        ColorGradePreset(name: "Cinematic", grade: GradeSettings(contrast: 1.08, highlights: 0.62, shadows: 0.58, whites: 0.56, blacks: 0.44, temperature: -0.08, saturation: 0.94, vibrance: 0.08, halation: 0.15, vignette: 0.12), isBuiltIn: true),
        ColorGradePreset(name: "Portrait", grade: GradeSettings(contrast: 0.98, highlights: 0.56, shadows: 0.62, whites: 0.54, blacks: 0.47, temperature: 0.04, saturation: 0.92, vibrance: 0.15, sharpen: 0.22), isBuiltIn: true),
        ColorGradePreset(name: "Vivid", grade: GradeSettings(contrast: 1.12, highlights: 0.58, shadows: 0.54, whites: 0.58, blacks: 0.43, saturation: 1.18, vibrance: 0.22), isBuiltIn: true),
        ColorGradePreset(name: "Noir", grade: GradeSettings(contrast: 1.2, highlights: 0.65, shadows: 0.36, whites: 0.6, blacks: 0.25, saturation: 0, vibrance: 0), isBuiltIn: true),
        ColorGradePreset(name: "Warm Film", grade: GradeSettings(contrast: 1.06, highlights: 0.58, shadows: 0.55, whites: 0.54, blacks: 0.42, temperature: 0.18, tint: 0.05, saturation: 0.9, vibrance: 0.06, grain: 0.08, vignette: 0.16), isBuiltIn: true),
        ColorGradePreset(name: "Cool Night", grade: GradeSettings(contrast: 1.04, highlights: 0.62, shadows: 0.66, whites: 0.52, blacks: 0.4, temperature: -0.2, saturation: 0.82, vibrance: 0.14, sharpen: 0.24), isBuiltIn: true),
        ColorGradePreset(name: "Urban Contrast", grade: GradeSettings(contrast: 1.16, highlights: 0.66, shadows: 0.48, whites: 0.6, blacks: 0.35, saturation: 0.9, vibrance: 0.12, sharpen: 0.5, vignette: 0.22), isBuiltIn: true),
        ColorGradePreset(name: "Soft Pastel", grade: GradeSettings(contrast: 0.92, highlights: 0.48, shadows: 0.62, whites: 0.52, blacks: 0.5, temperature: 0.08, saturation: 0.9, vibrance: 0.1), isBuiltIn: true),
        ColorGradePreset(name: "Black and White", grade: GradeSettings(contrast: 1.1, highlights: 0.6, shadows: 0.5, whites: 0.56, blacks: 0.38, saturation: 0, sharpen: 0.42, grain: 0.05), isBuiltIn: true)
    ]
}
