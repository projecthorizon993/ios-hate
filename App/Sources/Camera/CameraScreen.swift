import SwiftUI
import UIKit

struct CameraScreen: View {
    @StateObject private var manager = NativeCameraManager()

    var body: some View {
        ZStack {
            IntegratedCameraView(cameraManager: manager)

            if let lastCapture = manager.lastCapture {
                VStack {
                    HStack {
                        Spacer()
                        Image(uiImage: lastCapture)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.85), lineWidth: 1))
                            .padding(.trailing, 18)
                            .padding(.top, 18)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
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
