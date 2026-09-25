import Foundation

public enum CameraLens: String, CaseIterable, Identifiable {
    case ultraWide
    case wide
    case telephoto

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ultraWide: "0.5×"
        case .wide: "1×"
        case .telephoto: "3×"
        }
    }

    public var baseFocalLength: Int {
        switch self {
        case .ultraWide: 13
        case .wide: 24
        case .telephoto: 77
        }
    }
}
