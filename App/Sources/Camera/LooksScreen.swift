import SwiftUI

/// Step 3's screen: pick a look, set its strength, adjust the tone curve.
///
/// Every control here writes to the one `ProcessingSettings` the view model owns, so
/// nothing on this screen can affect the preview differently from the saved photo — there
/// is only one recipe and the screen is an editor for it.
///
/// Controls the device cannot honour are **absent**, not disabled. `docs/ARCHITECTURE.md`
/// section 5: hide what does not exist, disable what exists but is not available now, and
/// never simulate. So a device with no ProRAW support has no RAW switch to look at, and a
/// format with no locked exposure has no shutter slider.
struct LooksScreen: View {

    @ObservedObject var model: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                toneSection
                lookSection
                finishSection
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.ColorToken.surfaceBase)
        .navigationTitle("Looks")
    }

    // MARK: - Tone

    private var toneSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Tone")
                .font(.system(size: Theme.TypeSize.label))
                .foregroundStyle(Theme.ColorToken.textSecondary)

            // A dialled-in correction is the case where the native pipeline's own white
            // balance is no longer trusted, so the UI says so rather than leaving the user
            // to wonder why the colours shifted after they stopped touching anything.
            Text("Adjustments apply only to what you change. The camera's own white balance is left alone otherwise.")
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)

            LabelledSlider(title: "Exposure",
                           value: Binding(get: { model.settings.tone?.exposure ?? 0 },
                                          set: { model.setTone(currentTone(exposure: $0)) }),
                           range: 0...1)
            LabelledSlider(title: "Contrast",
                           value: Binding(get: { model.settings.tone?.contrast ?? 0 },
                                          set: { model.setTone(currentTone(contrast: $0)) }),
                           range: -1...1)
            LabelledSlider(title: "Saturation",
                           value: Binding(get: { model.settings.tone?.saturation ?? 0 },
                                          set: { model.setTone(currentTone(saturation: $0)) }),
                           range: -1...1)
            LabelledSlider(title: "Lift",
                           value: Binding(get: { model.settings.tone?.lift ?? 0 },
                                          set: { model.setTone(currentTone(lift: $0)) }),
                           range: -1...1)
            LabelledSlider(title: "Warmth",
                           value: Binding(get: { model.settings.tone?.temperatureOffset ?? 0 },
                                          set: { model.setTone(currentTone(temperature: $0)) }),
                           range: -1500...1500)
            LabelledSlider(title: "Tint",
                           value: Binding(get: { model.settings.tone?.tintOffset ?? 0 },
                                          set: { model.setTone(currentTone(tint: $0)) }),
                           range: -60...60)

            if model.settings.tone != nil {
                Button("Reset tone") { model.setTone(.neutral) }
                    .font(.system(size: Theme.TypeSize.label))
                    .foregroundStyle(Theme.ColorToken.accentActive)
            }
        }
    }

    // MARK: - Looks

    private var lookSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Look")
                .font(.system(size: Theme.TypeSize.label))
                .foregroundStyle(Theme.ColorToken.textSecondary)

            // Original is `nil`, not a Look value. It is the one tile that must return the
            // photo to exactly what was captured, so it cannot be a table applied at some
            // intensity.
            Button {
                model.select(look: nil)
            } label: {
                LookTile(title: "Original",
                         blurb: "Exactly as captured",
                         isSelected: model.settings.look == nil,
                         onRemove: nil)
            }
            .buttonStyle(.plain)

            ForEach(model.looks) { look in
                Button {
                    model.select(look: look)
                } label: {
                    LookTile(title: look.name,
                             blurb: blurb(for: look),
                             isSelected: model.settings.look?.id == look.id,
                             onRemove: look.isImported
                                ? { model.removeImportedLook(look) }
                                : nil)
                }
                .buttonStyle(.plain)
            }

            if model.settings.look != nil {
                LabelledSlider(title: "Strength",
                               value: Binding(get: { model.settings.lookIntensity },
                                              set: { model.setLookIntensity($0) }),
                               range: 0...1)
            }

            Text("A look at zero strength is the same as no look, and skips processing entirely.")
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)

            LabelledSlider(title: "Grain",
                           value: Binding(get: { model.settings.grain },
                                          set: { model.setGrain($0) }),
                           range: 0...1)
            LabelledSlider(title: "Sharpen",
                           value: Binding(get: { model.settings.sharpen },
                                          set: { model.setSharpen($0) }),
                           range: 0...1)
        }
    }

    private var finishSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Live preview is \(model.isProcessingActive ? "on" : "off")")
                .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.textDisabled)
            Text(model.isProcessingActive
                 ? "Changes apply to the viewfinder and to the saved photo."
                 : "The viewfinder is showing the unprocessed image, which is also what will be saved.")
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)
        }
    }

    // MARK: - Helpers

    /// Reads the current curve, changes one field, and hands it back. Written as a chain
    /// so adding a control is one line rather than a new binding per field.
    private func currentTone(exposure: Float? = nil,
                             contrast: Float? = nil,
                             saturation: Float? = nil,
                             lift: Float? = nil,
                             temperature: Float? = nil,
                             tint: Float? = nil) -> ToneCurve {
        var tone = model.settings.tone ?? .neutral
        if let exposure { tone.exposure = exposure }
        if let contrast { tone.contrast = contrast }
        if let saturation { tone.saturation = saturation }
        if let lift { tone.lift = lift }
        if let temperature { tone.temperatureOffset = temperature }
        if let tint { tone.tintOffset = tint }
        return tone
    }

    private func blurb(for look: Look) -> String {
        if case .generated(let which) = look.source { return which.blurb }
        return "Imported .cube"
    }
}

// MARK: - Pieces

private struct LabelledSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack {
                Text(title)
                    .font(.system(size: Theme.TypeSize.label))
                    .foregroundStyle(Theme.ColorToken.textPrimary)
                Spacer()
                Text(ReportFormat.number(Double(value), decimals: 2))
                    .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.textSecondary)
            }
            Slider(value: $value, in: range)
                .tint(Theme.ColorToken.accentActive)
                .accessibilityLabel(title)
        }
    }
}

private struct LookTile: View {
    let title: String
    let blurb: String
    let isSelected: Bool
    /// Present only for the user's own tables. A built-in cannot be removed, so it has
    /// no button at all rather than a disabled one.
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title)
                    .font(.system(size: Theme.TypeSize.value))
                    .foregroundStyle(isSelected
                                     ? Theme.ColorToken.accentActive
                                     : Theme.ColorToken.textPrimary)
                Text(blurb)
                    .font(.system(size: Theme.TypeSize.caption))
                    .foregroundStyle(Theme.ColorToken.textDisabled)
            }
            Spacer()
            if let onRemove {
                Button(action: onRemove) {
                    Text("Remove")
                        .font(.system(size: Theme.TypeSize.caption))
                        .foregroundStyle(Theme.ColorToken.stateError)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(title)")
            }
        }
        .padding(Theme.Space.s)
        .background(Theme.ColorToken.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: Theme.Space.s)
            .stroke(isSelected ? Theme.ColorToken.accentActive : Theme.ColorToken.strokeSubtle,
                    lineWidth: isSelected ? Theme.TypeSize.value : 1))
        .cornerRadius(Theme.Space.s)
    }
}
