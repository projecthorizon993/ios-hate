import SwiftUI

/// Step 4's screen: the manual controls this device and format can actually honour.
///
/// The whole screen is built from `ProCapabilities` rather than from a fixed layout. A
/// control that is absent because the hardware cannot do it is the honest result;
/// `docs/ARCHITECTURE.md` section 5 requires hiding what does not exist rather than
/// showing a disabled control that invites the user to keep trying.
struct ProScreen: View {

    @ObservedObject var model: CameraViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if model.proCapabilities.isEmpty {
                    emptyState
                } else {
                    captureControls
                    locks
                    formatControls
                }
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.ColorToken.surfaceBase)
        .navigationTitle("Pro")
    }

    /// The real case on an iPhone SE: no RAW, no ProRAW, no lockable exposure, no lockable
    /// focus. Saying that plainly beats rendering a panel of switches that all refuse.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("No manual controls here")
                .font(.system(size: Theme.TypeSize.value))
                .foregroundStyle(Theme.ColorToken.textPrimary)
            Text(model.proCapabilities.availabilitySummary)
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)
            Text("Switching to Pro changes nothing on this device and format, so the mode is here for the chrome and not for the controls.")
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)
        }
    }

    @ViewBuilder
    private var captureControls: some View {
        if let iso = model.proCapabilities.isoRange {
            ProSlider(title: "ISO",
                      value: Binding(
                        get: { model.manual.iso.map { Float($0) } ?? iso.lowerBound },
                        set: { model.setManual(iso: $0) }),
                      range: iso.lowerBound...iso.upperBound,
                      isAutomatic: model.manual.iso == nil,
                      setAutomatic: { model.setManualISO(automatic: $0) })
        }
        if let shutter = model.proCapabilities.shutterRange {
            // A linear slider over an exposure range spanning 1/8000 s to 30 s is useless —
            // everything interesting is bunched at the fast end. The position is
            // logarithmic and the label spells out the actual time, which is the only part
            // the user can act on.
            ProSlider(title: "Shutter",
                      value: Binding(
                        get: { logPosition(model.manual.shutterSeconds, in: shutter) },
                        set: { model.setManual(shutterSeconds: positionFor($0, in: shutter)) }),
                      range: 0...1,
                      readout: model.manual.shutterSeconds.map { ReportFormat.shutter($0) } ?? "Auto",
                      isAutomatic: model.manual.shutterSeconds == nil,
                      setAutomatic: { model.setManualShutter(automatic: $0) })
        }
        if let ev = model.proCapabilities.exposureCompensationRange {
            ProSlider(title: "Exposure",
                      value: Binding(
                        get: { model.manual.exposureTargetOffset },
                        set: { model.setManual(exposureTargetOffset: $0) }),
                      range: ev.lowerBound...ev.upperBound,
                      readout: String(format: "%+.2f EV", model.manual.exposureTargetOffset),
                      isAutomatic: model.manual.exposureTargetOffset == 0,
                      setAutomatic: { model.setManualEV(automatic: $0) })
        }
    }

    @ViewBuilder
    private var locks: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if model.proCapabilities.canLockExposure {
                Toggle(isOn: Binding(get: { model.manual.lockExposure },
                                     set: { model.setManual(lockExposure: $0) })) {
                    Text("Lock exposure")
                        .font(.system(size: Theme.TypeSize.label))
                        .foregroundStyle(Theme.ColorToken.textPrimary)
                }
                .tint(Theme.ColorToken.accentActive)
            }
            if model.proCapabilities.canLockFocus {
                Toggle(isOn: Binding(get: { model.manual.lockFocus },
                                     set: { model.setManual(lockFocus: $0) })) {
                    Text("Lock focus")
                        .font(.system(size: Theme.TypeSize.label))
                        .foregroundStyle(Theme.ColorToken.textPrimary)
                }
                .tint(Theme.ColorToken.accentActive)
            }
            if model.proCapabilities.canLockWhiteBalance {
                Toggle(isOn: Binding(get: { model.manual.lockWhiteBalance },
                                     set: { model.setManual(lockWhiteBalance: $0) })) {
                    Text("Lock white balance")
                        .font(.system(size: Theme.TypeSize.label))
                        .foregroundStyle(Theme.ColorToken.textPrimary)
                }
                .tint(Theme.ColorToken.accentActive)
            }
        }
    }

    @ViewBuilder
    private var formatControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if model.proCapabilities.rawSupported {
                Toggle(isOn: Binding(get: { model.manual.raw },
                                     set: { model.setManual(raw: $0) })) {
                    Text("RAW")
                        .font(.system(size: Theme.TypeSize.label))
                        .foregroundStyle(Theme.ColorToken.textPrimary)
                }
                .tint(Theme.ColorToken.accentActive)
            }
            // ProRAW is only offered where RAW is, because it is a RAW variant. A ProRAW
            // switch on a device with no RAW output would be a control that cannot work.
            if model.proCapabilities.rawSupported, model.proCapabilities.proRawSupported {
                Toggle(isOn: Binding(get: { model.manual.proRaw },
                                     set: { model.setManual(proRaw: $0) })) {
                    Text("Apple ProRAW")
                        .font(.system(size: Theme.TypeSize.label))
                        .foregroundStyle(Theme.ColorToken.textPrimary)
                }
                .tint(Theme.ColorToken.accentActive)
                .disabled(!model.manual.raw)
            }
            if !model.proCapabilities.maxPhotoDimensions.isEmpty {
                Text("Max still \(model.proCapabilities.maxPhotoDimensions)")
                    .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.textDisabled)
            }
        }
    }

    // MARK: - Log shutter mapping

    /// Slider position for an exposure time, logarithmic.
    ///
    /// `1/8000 … 30` is roughly 28 stops. Linearly, three quarters of the slider is spent
    /// on shutter speeds no handheld photo uses.
    private func logPosition(_ seconds: Double?, in range: ClosedRange<Double>) -> Float {
        guard let seconds, seconds > 0 else { return 0 }
        let low = log10(range.lowerBound)
        let high = log10(range.upperBound)
        guard high > low else { return 0 }
        let position = (log10(seconds) - low) / (high - low)
        return Float(min(max(position, 0), 1))
    }

    private func positionFor(_ position: Float, in range: ClosedRange<Double>) -> Double {
        guard position > 0 else { return 0 }
        let low = log10(range.lowerBound)
        let high = log10(range.upperBound)
        return pow(10, low + Double(position) * (high - low))
    }
}

// MARK: - Pieces

private struct ProSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    /// Replaces the numeric readout where the number alone is not actionable, as a slider
    /// position is for a shutter speed.
    var readout: String?
    /// `false` means "let the camera decide". A slider has nowhere to put "auto" — its
    /// positions are all values — so the choice is a separate control rather than a
    /// position on the track, and the slider is disabled while automatic.
    let isAutomatic: Bool
    let setAutomatic: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack {
                Text(title)
                    .font(.system(size: Theme.TypeSize.label))
                    .foregroundStyle(Theme.ColorToken.textPrimary)
                Spacer()
                Text(readout ?? ReportFormat.number(Double(value), decimals: 2))
                    .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                    .foregroundStyle(isAutomatic
                                     ? Theme.ColorToken.textDisabled
                                     : Theme.ColorToken.textSecondary)
            }
            HStack(spacing: Theme.Space.s) {
                Button { setAutomatic(!isAutomatic) } label: {
                    Text(isAutomatic ? "Auto on" : "Auto")
                        .font(.system(size: Theme.TypeSize.caption))
                        .foregroundStyle(isAutomatic
                                         ? Theme.ColorToken.accentActive
                                         : Theme.ColorToken.textSecondary)
                }
                .accessibilityLabel("\(title) automatic")
                Slider(value: $value, in: range)
                    .tint(Theme.ColorToken.accentActive)
                    .disabled(isAutomatic)
                    .accessibilityLabel(title)
            }
        }
    }
}
