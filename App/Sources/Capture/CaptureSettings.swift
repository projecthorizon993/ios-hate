import Foundation

enum CaptureAspectRatio: String, CaseIterable, Identifiable, Sendable {
    case original
    case fourThree
    case square
    case sixteenNine
    case cinema

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "ORIG"
        case .fourThree: return "4:3"
        case .square: return "1:1"
        case .sixteenNine: return "16:9"
        case .cinema: return "2.39"
        }
    }

    var value: CGFloat? {
        switch self {
        case .original: return nil
        case .fourThree: return 4 / 3
        case .square: return 1
        case .sixteenNine: return 16 / 9
        case .cinema: return 2.39
        }
    }
}

struct CaptureSettings: Sendable {
    var mode: CaptureMode
    var iso: Float
    var shutterDuration: Double
    var exposureCompensation: Float
    var kelvin: Float
    var tint: Float
    var focusLocked: Bool
    var zoomFactor: CGFloat
}
