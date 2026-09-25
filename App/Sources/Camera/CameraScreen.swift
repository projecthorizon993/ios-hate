import SwiftUI

struct CameraScreen: View {
    @StateObject private var manager = NativeCameraManager()

    var body: some View {
        IntegratedCameraView(cameraManager: manager)
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
            .onAppear {
                manager.start()
            }
            .onDisappear {
                manager.stop()
            }
    }
}
