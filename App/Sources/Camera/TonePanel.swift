import SwiftUI

/// The tone controls, docked in the bottom stack behind a small "Tune" chip.
///
/// Separate from the looks carousel on purpose. A look is chosen by looking and by tapping
/// — a fast, glanceable decision. Tone is exposure, contrast, saturation, lift and warmth:
/// a slower adjustment that is dialled in and then left alone. Putting five sliders in the
/// same strip as the carousel would make the fast thing slow, which is the same mistake as
/// making the whole panel full screen.
struct TonePanel: View {

    @ObservedObject var model: CameraViewModel
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            header
            Text("Adjustments apply only to what you change, so the camera's own white "
                 + "balance keeps working when you leave these alone.")
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ToneField.allCases, id: \.self) { field in
                slider(field)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.ColorToken.surfaceBase.opacity(0.96))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var header: some View {
        HStack {
            Text("Tone")
                .font(.system(size: Theme.TypeSize.label))
                .foregroundStyle(Theme.ColorToken.textSecondary)
            Spacer()
            if model.settings.tone != nil {
                Button("Reset") { model.setTone(.neutral) }
                    .font(.system(size: Theme.TypeSize.caption))
                    .foregroundStyle(Theme.ColorToken.accentActive)
                    .accessibilityLabel("Reset tone adjustments")
            }
        }
    }

    private func slider(_ field: ToneField) -> some View {
        let value = field.value(in: model.settings.tone ?? .neutral)
        let decimals = field.range.upperBound > 100 ? 0 : 2
        return HStack(spacing: Theme.Space.s) {
            Text(field.rawValue)
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)
                .frame(width: 74, alignment: .leading)

            Slider(value: Binding(
                get: { field.value(in: model.settings.tone ?? .neutral) },
                set: { model.setTone(field.apply($0, to: model.settings.tone ?? .neutral)) }),
                in: field.range)
                .tint(Theme.ColorToken.accentActive)
                .accessibilityLabel(field.rawValue)
                .accessibilityValue(ReportFormat.number(Double(value), decimals: decimals))

            Text(ReportFormat.number(Double(value), decimals: decimals))
                .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.textSecondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    /// One of the tone controls, so reading and writing a field is a switch on a type
    /// rather than a switch on a display string.
    ///
    /// The string version of this existed first and it was wrong: the label a user sees and
    /// the field the code writes were two separate switches that had to agree, and renaming
    /// a label would have silently zeroed the control.
    private enum ToneField: String, CaseIterable {
        case exposure = "Exposure"
        case contrast = "Contrast"
        case saturation = "Saturation"
        case lift = "Lifted shadows"
        case temperature = "Warmth"

        var range: ClosedRange<Float> {
            switch self {
            case .exposure, .lift: return 0...1
            case .contrast, .saturation: return -1...1
            case .temperature: return -1500...1500
            }
        }

        func value(in tone: ToneCurve) -> Float {
            switch self {
            case .exposure: return tone.exposure
            case .contrast: return tone.contrast
            case .saturation: return tone.saturation
            case .lift: return tone.lift
            case .temperature: return tone.temperatureOffset
            }
        }

        func apply(_ value: Float, to tone: ToneCurve) -> ToneCurve {
            var copy = tone
            switch self {
            case .exposure: copy.exposure = value
            case .contrast: copy.contrast = value
            case .saturation: copy.saturation = value
            case .lift: copy.lift = value
            case .temperature: copy.temperatureOffset = value
            }
            return copy
        }
    }
}
