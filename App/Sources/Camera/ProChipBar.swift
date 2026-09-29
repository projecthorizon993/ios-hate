import SwiftUI

/// The Pro mode's contextual controls: a row of chips showing the current value, which
/// expand in place into their dial.
///
/// This is a bottom-stack control, not a screen. The user is adjusting a parameter *while
/// looking at the viewfinder*, and the point of a pro control is watching the value change
/// as you turn it — which a full-screen sheet prevents, because the sheet covers the
/// preview. So the panel that opens covers only the lower part of the viewfinder and the
/// camera keeps running behind it.
///
/// A chip shows the value, not the parameter name. A row of "ISO / Shutter / EV" tells the
/// user what exists; a row of "100 / 1/120 / +0.3" tells them what the camera is doing. The
/// name is the accessibility label and the hint, not the pixels.
struct ProChipBar: View {

    @ObservedObject var model: CameraViewModel
    @Binding var expanded: Bool

    /// Which parameter's dial is docked. Nil means collapsed.
    ///
    /// Published upward rather than kept private, because the panel itself is drawn by
    /// `CameraScreen.dockedPanel` over the viewfinder. This type is only the chips; it
    /// must not also draw the dial, or the same control appears twice.
    @Binding var open: ProParameter?

    private var supported: [ProParameter] {
        ProParameter.supported(by: model.proCapabilities)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(supported, id: \.self) { parameter in
                    chip(for: parameter)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: Theme.Space.xl + Theme.Space.s)
    }

    private func chip(for parameter: ProParameter) -> some View {
        let value = parameter.readout(model.manual)
        let isOpen = open == parameter
        let isAutomatic = parameter.isAutomatic(model.manual)

        return Button {
            Haptics.selection()
            // Tapping the open chip closes it. A chip that only opens is a trap when the
            // panel covers the thing you were aiming at.
            if isOpen {
                open = nil
                expanded = false
            } else {
                open = parameter
                expanded = true
            }
        } label: {
            VStack(spacing: 0) {
                Text(parameter.title)
                    .font(.system(size: Theme.TypeSize.caption))
                    .foregroundStyle(isOpen
                                     ? Theme.ColorToken.surfaceBase
                                     : Theme.ColorToken.textDisabled)
                Text(value)
                    .font(.system(size: Theme.TypeSize.label, design: .monospaced))
                    .foregroundStyle(isOpen
                                     ? Theme.ColorToken.surfaceBase
                                     : (isAutomatic
                                        ? Theme.ColorToken.textSecondary
                                        : Theme.ColorToken.textPrimary))
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: Theme.Space.xl + Theme.Space.s)
            .background(isOpen ? Theme.ColorToken.accentActive : Theme.ColorToken.surfaceRaised)
            .clipShape(Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parameter.title)
        .accessibilityValue(value)
        .accessibilityHint(isOpen ? "Collapses the control" : "Expands the control in place")
        .accessibilityAddTraits(isOpen ? [.isSelected, .isButton] : .isButton)
    }
}

/// Lets the docked dial show the parameter whose chip opened it, instead of the one it
/// last remembered.
///
/// A docked dial has no room for a parameter picker, and a picker it cannot fit is worse
/// than no picker. So the chip decides, and the dial reads it from here.
private struct ProParameterOverrideKey: EnvironmentKey {
    // `EnvironmentKey` requires a computed `defaultValue`, not a stored constant, and
    // `nil` is the right one: nothing has said which parameter to show, so the dial uses
    // its own picker.
    static var defaultValue: ProParameter? { nil }
}

extension EnvironmentValues {
    var proParameterOverride: ProParameter? {
        get { self[ProParameterOverrideKey.self] }
        set { self[ProParameterOverrideKey.self] = newValue }
    }
}
