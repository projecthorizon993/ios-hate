import Foundation

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
