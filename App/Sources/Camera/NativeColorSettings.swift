import Foundation

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

    static let natural = NativeColorSettings()
}
