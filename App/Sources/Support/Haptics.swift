import CoreHaptics
import Foundation
import UIKit

/// Thin wrapper over the feedback generators.
///
/// `docs/DESIGN_SPEC.md` fixes which interaction gets which haptic, and the system
/// haptic setting has to win over all of them. Generators are created per call and
/// `prepare()`d immediately: a prepared generator fires with lower latency, and the
/// camera screen is not a place worth caching one across sessions.
enum Haptics {

    /// `nil` on hardware with no Taptic Engine, and whenever the user has switched
    /// haptics off system-wide. Callers treat `nil` as "do nothing", not as an error.
    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Dial detents and mode changes.
    static func selection() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    /// Shutter.
    static func shutter() {
        impact(.light)
    }

    /// Focus lock confirmation.
    static func focusLocked() {
        impact(.rigid)
    }
}
