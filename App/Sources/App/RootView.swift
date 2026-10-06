import AVFoundation
import SwiftUI

/// The camera screen needs the camera permission: RAW and ProRAW are output properties
/// that can only be read from a live session, and so is every capability the camera UI
/// gates itself on. The developer panel is reachable from inside the camera screen
/// once the permission is in place.
struct RootView: View {

    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var isRequesting = false

    var body: some View {
        Group {
            switch status {
            case .authorized:
                CameraScreen()
            case .notDetermined:
                permissionPrompt
            case .denied, .restricted:
                permissionRefused
            @unknown default:
                permissionPrompt
            }
        }
        .preferredColorScheme(.dark)
    }

    private var permissionPrompt: some View {
        VStack(spacing: Theme.Space.l) {
            Text("LumaFrame needs camera access")
                .font(.system(size: Theme.TypeSize.title, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.textPrimary)
            Text("The camera screen reads RAW and ProRAW support from a live capture session, so it cannot run without permission. Nothing is recorded or uploaded.")
                .font(.system(size: Theme.TypeSize.label))
                .foregroundStyle(Theme.ColorToken.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                request()
            } label: {
                Text(isRequesting ? "Requesting…" : "Allow camera")
                    .frame(maxWidth: .infinity, minHeight: Theme.Space.minTouch)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.ColorToken.accentActive)
            .foregroundStyle(Theme.ColorToken.surfaceBase)
            .disabled(isRequesting)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ColorToken.surfaceBase)
    }

    private var permissionRefused: some View {
        VStack(spacing: Theme.Space.l) {
            Text("Camera access is off")
                .font(.system(size: Theme.TypeSize.title, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.textPrimary)
            Text("Enable it in Settings, then reopen LumaFrame. The camera and the capability report both need it.")
                .font(.system(size: Theme.TypeSize.label))
                .foregroundStyle(Theme.ColorToken.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                openSettings()
            } label: {
                Text("Open Settings")
                    .frame(maxWidth: .infinity, minHeight: Theme.Space.minTouch)
            }
            .buttonStyle(.bordered)
            .tint(Theme.ColorToken.accentActive)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ColorToken.surfaceBase)
    }

    private func request() {
        isRequesting = true
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                isRequesting = false
                status = granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .video)
                AppLog.note(AppLog.camera, "camera permission result: \(status.rawValue)")
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
