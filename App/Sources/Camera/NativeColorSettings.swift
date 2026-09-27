import CoreGraphics
import Foundation

enum NativeColorPreset: String, CaseIterable, Identifiable {
    case natural
    case cinematic
    case vivid
    case warm
    case cool
    case mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .natural: "Natural"
        case .cinematic: "Cinematic"
        case .vivid: "Vivid"
        case .warm: "Warm"
        case .cool: "Cool"
        case .mono: "Mono"
        }
    }

    var saturation: CGFloat {
        switch self {
        case .natural: 1
        case .cinematic: 0.88
        case .vivid: 1.35
        case .warm: 1.08
        case .cool: 1
        case .mono: 0
        }
    }

    var contrast: CGFloat {
        switch self {
        case .natural: 1
        case .cinematic: 1.15
        case .vivid: 1.08
        case .warm: 1.02
        case .cool: 1.04
        case .mono: 1.18
        }
    }

    var exposure: CGFloat {
        switch self {
        case .natural: 0
        case .cinematic: -0.10
        case .vivid: 0.04
        case .warm: 0.05
        case .cool: -0.02
        case .mono: 0
        }
    }

    var temperature: CGFloat {
        switch self {
        case .natural: 0
        case .cinematic: -0.10
        case .vivid: 0
        case .warm: 0.40
        case .cool: -0.40
        case .mono: 0
        }
    }
}

struct NativeColorSettings: Equatable {
    var preset: NativeColorPreset = .natural
    var intensity: CGFloat = 1
    var exposure: CGFloat = 0
    var contrast: CGFloat = 1
    var saturation: CGFloat = 1
    var temperature: CGFloat = 0
    var tint: CGFloat = 0

    static let natural = NativeColorSettings()

    static func preset(_ preset: NativeColorPreset) -> NativeColorSettings {
        NativeColorSettings(preset: preset)
    }

    var isNeutral: Bool {
        self == .natural
    }

    func resolved(intensity scale: CGFloat? = nil) -> ResolvedColor {
        let amount = min(max(scale ?? intensity, 0), 1)
        let presetSaturation = preset.saturation
        let presetContrast = preset.contrast
        let presetExposure = preset.exposure
        let presetTemperature = preset.temperature
        let saturation = presetSaturation + ((self.saturation - 1) * amount)
        let contrast = presetContrast + ((self.contrast - 1) * amount)
        let exposure = presetExposure + (self.exposure * amount)
        let temperature = presetTemperature + (self.temperature * amount)
        return ResolvedColor(
            saturation: min(max(saturation, 0), 2),
            contrast: min(max(contrast, 0.5), 2),
            exposure: min(max(exposure, -2), 2),
            temperature: min(max(temperature, -1), 1),
            tint: min(max(self.tint * amount, -1), 1)
        )
    }

    struct ResolvedColor: Equatable {
        var saturation: CGFloat
        var contrast: CGFloat
        var exposure: CGFloat
        var temperature: CGFloat
        var tint: CGFloat

        var isIdentity: Bool {
            abs(saturation - 1) < 0.001
                && abs(contrast - 1) < 0.001
                && abs(exposure) < 0.001
                && abs(temperature) < 0.001
                && abs(tint) < 0.001
        }
    }
}
