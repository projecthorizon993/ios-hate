import MijickCamera
import SwiftUI
import UIKit

struct CameraScreen: View {
    @State private var lastCapture: UIImage?

    var body: some View {
        ZStack {
            MCamera()
                .setCameraOutputType(.photo)
                .setCameraPosition(.back)
                .setAudioAvailability(false)
                .setResolution(.hd1920x1080)
                .setFrameRate(30)
                .setGridVisibility(true)
                .setCapturedMediaScreen(nil)
                .onImageCaptured { image, controller in
                    withAnimation(.easeOut(duration: 0.2)) {
                        lastCapture = image
                    }
                    controller.reopenCameraScreen()
                }
                .startSession()

            if let lastCapture {
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
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}
