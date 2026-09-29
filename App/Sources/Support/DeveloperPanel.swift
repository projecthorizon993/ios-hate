import SwiftUI

/// The developer panel: what this device can do, read from values already discovered.
///
/// This is the replacement for the capability report, and the difference is that **it
/// probes nothing.** Every row is rendered from a `RuntimeCapabilities` that was filled in
/// when the session was configured. There is no second capture session, no GPU benchmark,
/// no large allocation and no asynchronous gap — which is the list of things the report
/// did, and the list of things it crashed on.
///
/// So this panel cannot fail in the way the report did, and it is safe to leave reachable.
///
/// The log is the portable artefact. "Log capabilities" writes the same table to
/// `Documents/LumaFrame-log.txt`, which is the thing to send with a bug report now that
/// there is no shareable report file.
struct DeveloperPanel: View {

    @ObservedObject var model: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var logged = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                headline
                rows
                actions
                howToRead
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.ColorToken.surfaceBase)
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headline: some View {
        Text(model.runtimeCapabilities.headline)
            .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
            .foregroundStyle(Theme.ColorToken.accentActive)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(model.runtimeCapabilities.lines, id: \.0) { label, value in
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Text(label)
                        .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.textDisabled)
                        .frame(width: 92, alignment: .leading)
                    Text(value)
                        .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            Button {
                model.runtimeCapabilities.logEverything()
                logged = true
            } label: {
                Text("Log capabilities")
                    .font(.system(size: Theme.TypeSize.caption))
                    .foregroundStyle(Theme.ColorToken.surfaceBase)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(minHeight: Theme.Space.minTouch)
                    .background(Theme.ColorToken.accentActive)
                    .clipShape(Capsule())
            }
            .accessibilityHint("Writes every capability to the log file, which is what to send with a bug report")
        }
    }

    /// Says where the log is, because a developer looking for the file will not guess that
    /// Documents is exposed through Files.app by two Info.plist keys.
    private var howToRead: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(logged ? "Written. On My iPhone › LumaFrame › \(LumaFrameLogFile.fileName)"
                        : "Log file: On My iPhone › LumaFrame › \(LumaFrameLogFile.fileName)")
                .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                .foregroundStyle(logged ? Theme.ColorToken.accentActive : Theme.ColorToken.textDisabled)
                .fixedSize(horizontal: false, vertical: true)

            Text("These are read at run time on this device. There is no cross-device record "
                 + "any more: capabilities are not a measurement you gather once, they are "
                 + "what the hardware reports while it is running.")
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
