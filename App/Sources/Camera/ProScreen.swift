import SwiftUI

/// Step 4's host screen. The controls themselves are `ProDial`.
///
/// The panel is built from `ProCapabilities` rather than a fixed layout, so a control the
/// hardware cannot honour is absent rather than present and disabled. A row of dead
/// switches is an inventory of what the device is not, which is not something anyone
/// composing a photo wants.
struct ProScreen: View {

    @ObservedObject var model: CameraViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if model.proCapabilities.isEmpty {
                    emptyState
                } else {
                    ProDial(model: model)
                    rawSection
                }
            }
            .padding(.vertical, Theme.Space.l)
        }
        .background(Theme.ColorToken.surfaceBase)
        .navigationTitle("Pro")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The real case on an iPhone SE: no RAW, no ProRAW, no lockable exposure, no lockable
    /// focus. Saying that plainly beats rendering a panel of controls that all refuse.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("No manual controls here")
                .font(.system(size: Theme.TypeSize.value))
                .foregroundStyle(Theme.ColorToken.textPrimary)
            Text(model.proCapabilities.availabilitySummary)
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)
            Text("The mode is still here so the chrome does not move, but there is nothing for it to do on this device and format.")
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Space.l)
    }

    /// RAW lives outside the dial because it is a switch, not a dial. ProRAW is only
    /// offered where RAW is, because it is a RAW variant. A ProRAW control on a device
    /// with no RAW output would be a control that cannot work.
    @ViewBuilder
    private var rawSection: some View {
        if model.proCapabilities.rawSupported {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Format")
                    .font(.system(size: Theme.TypeSize.label))
                    .foregroundStyle(Theme.ColorToken.textSecondary)

                Toggle(isOn: Binding(get: { model.manual.raw },
                                     set: { model.setManual(raw: $0) })) {
                    Text("RAW")
                        .font(.system(size: Theme.TypeSize.label))
                        .foregroundStyle(Theme.ColorToken.textPrimary)
                }
                .tint(Theme.ColorToken.accentActive)

                if model.proCapabilities.proRawSupported {
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
            .padding(.horizontal, Theme.Space.l)
        }
    }
}