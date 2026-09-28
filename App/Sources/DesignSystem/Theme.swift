import SwiftUI
import UIKit

/// Design tokens. Every value here comes from `docs/DESIGN_SPEC.md` — that file is
/// the contract shared with the Android implementation. If a value is not in the
/// spec, it does not belong in this file.
enum Theme {

    // MARK: - Color

    enum ColorToken {
        static let surfaceBase = SwiftUI.Color(hex: 0x0B0B0C)
        static let surfaceRaised = SwiftUI.Color(hex: 0x17181A)
        static let strokeSubtle = SwiftUI.Color(hex: 0x2A2C30)
        static let strokeStrong = SwiftUI.Color(hex: 0x4A4D53)
        static let textPrimary = SwiftUI.Color(hex: 0xF2F3F5)
        static let textSecondary = SwiftUI.Color(hex: 0x9BA0A8)
        static let textDisabled = SwiftUI.Color(hex: 0x5C6068)
        static let accentActive = SwiftUI.Color(hex: 0xF2C14E)
        static let accentCompare = SwiftUI.Color(hex: 0x6FA8FF)
        static let stateWarn = SwiftUI.Color(hex: 0xE8804A)
        static let stateError = SwiftUI.Color(hex: 0xE2564C)
        static let stateLock = SwiftUI.Color(hex: 0x8F7BD8)
    }

    // MARK: - Spacing

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let huge: CGFloat = 48

        /// Minimum interactive size on both platforms (44pt / 48dp).
        static let minTouch: CGFloat = 44
    }

    // MARK: - Radius

    enum Radius {
        static let control: CGFloat = 10
        static let panel: CGFloat = 16
        static let pill: CGFloat = 999
    }

    // MARK: - Typography

    enum TypeSize {
        static let value: CGFloat = 17
        static let title: CGFloat = 17
        static let label: CGFloat = 13
        static let caption: CGFloat = 11
        static let mono: CGFloat = 13
    }

    // MARK: - Motion

    enum Motion {
        static let tap: Double = 0.12
        static let control: Double = 0.18
        static let mode: Double = 0.24
        static let overlay: Double = 0.09

        /// Collapses every duration when the user has asked for reduced motion.
        static func duration(_ base: Double) -> Double {
            UIAccessibility.isReduceMotionEnabled ? 0 : base
        }
    }
}

extension SwiftUI.Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
