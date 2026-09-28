import SwiftUI

/// Step 0 debug screen. Present this on all three test devices, copy the text, and
/// paste it back — every later step is gated on what it says.
struct ReportScreen: View {

    @StateObject private var model = ReportViewModel()
    @State private var isSharing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    header
                    if case .failed(let message) = model.state {
                        failureBanner(message)
                    }
                    ForEach(model.sections) { section in
                        ReportSectionView(section: section)
                    }
                    logToggle
                    savedNote
                    logFileNote
                }
                .padding(Theme.Space.l)
            }
            .background(Theme.ColorToken.surfaceBase)
            .navigationTitle("Capability Report")
            .toolbar { toolbarContent }
            .task { await model.run() }
            .sheet(isPresented: $isSharing) {
                ShareSheet(items: [model.text])
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(model.summary)
                .font(.system(size: Theme.TypeSize.label, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.textPrimary)
                .textSelection(.enabled)

            Button {
                Task { await model.run() }
            } label: {
                Label(model.canRun ? "Run report" : "Running…", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: Theme.Space.minTouch)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.ColorToken.accentActive)
            .foregroundStyle(Theme.ColorToken.surfaceBase)
            .disabled(!model.canRun)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ColorToken.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
    }

    private var logToggle: some View {
        Toggle(isOn: $model.includeLog) {
            Text("Include recent log")
                .font(.system(size: Theme.TypeSize.label))
                .foregroundStyle(Theme.ColorToken.textSecondary)
        }
        .tint(Theme.ColorToken.accentActive)
        .frame(minHeight: Theme.Space.minTouch)
        .disabled(model.logLines.isEmpty)
        .accessibilityHint("Appends the last log lines to the copied and shared text")
    }

    @ViewBuilder
    private var savedNote: some View {
        if let location = model.savedLocation {
            Text("Saved to Documents/Reports/\(location)")
                .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.accentActive)
        }
    }

    /// Where the on-disk log lives, always shown rather than only after a save.
    ///
    /// The log is written continuously and survives a crash, which is the only record of
    /// how far a report run got when the run dies. But it is only useful if the user can
    /// find it, and it is reachable through Files.app only because `UIFileSharingEnabled`
    /// and `LSSupportsOpeningDocumentsInPlace` are set in Info.plist.
    private var logFileNote: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Live log file (survives a crash)")
                .font(.system(size: Theme.TypeSize.label))
                .foregroundStyle(Theme.ColorToken.textSecondary)
            Text("On My iPhone › LumaFrame › " + LumaFrameLogFile.fileName)
                .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.textDisabled)
                .textSelection(.enabled)
        }
    }

    private func failureBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: Theme.TypeSize.label))
            .foregroundStyle(Theme.ColorToken.stateError)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
            .background(Theme.ColorToken.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .accessibilityLabel("Error: \(message)")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                model.copyToPasteboard()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .disabled(!model.isShareable)
            .accessibilityLabel("Copy report")

            Button {
                isSharing = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(!model.isShareable)
            .accessibilityLabel("Share report")

            Button {
                model.save()
            } label: {
                Image(systemName: "arrow.down.doc")
            }
            .disabled(!model.isShareable)
            .accessibilityLabel("Save report to Files")
        }
    }
}
