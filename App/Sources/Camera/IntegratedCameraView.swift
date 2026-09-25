import SwiftUI

struct IntegratedCameraView: View {
    @ObservedObject var cameraManager: NativeCameraManager

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            NativeCameraPreview(session: cameraManager.session)
                .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .statusBarHidden()
    }
}
