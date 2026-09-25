import MijickCameraView
import SwiftUI
import UIKit

struct CameraScreen: View {
    @StateObject private var manager = CameraManager(
        outputType: .photo,
        cameraPosition: .back,
        resolution: .hd1920x1080,
        frameRate: 30,
        flashMode: .off,
        isGridVisible: true
    )
    @State private var lastCapture: UIImage?

    var body: some View {
        ZStack {
            MCameraController(manager: manager)
                .mediaPreviewScreen(nil)
                .onImageCaptured { image in
                    withAnimation(.easeOut(duration: 0.2)) {
                        lastCapture = image
                    }
                }
                .afterMediaCaptured {
                    $0.returnToCameraView(true)
                }

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
