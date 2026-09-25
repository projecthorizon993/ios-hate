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

            professionalHUD

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

    private var professionalHUD: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LUMA FRAME")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("PHOTO · AUTO")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .foregroundStyle(.white)

                Spacer()

                HStack(spacing: 8) {
                    Text("1× · 24mm")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)

            Spacer()

            HStack(spacing: 8) {
                hudPill("GRID", systemImage: "grid")
                hudPill("AUTO", systemImage: "wand.and.stars")
                hudPill("PHOTO", systemImage: "camera")
            }
            .padding(.bottom, 112)
        }
        .allowsHitTesting(false)
    }

    private func hudPill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.black.opacity(0.42), in: Capsule())
    }
}
