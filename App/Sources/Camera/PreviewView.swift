import AVFoundation
import SwiftUI
import UIKit

/// `AVCaptureVideoPreviewLayer` in SwiftUI.
///
/// A plain `UIView` with a preview layer attached, per `docs/ARCHITECTURE.md` section 8:
/// no vendored viewfinder, no third-party camera view. The layer is the only thing that
/// touches the session, and it only ever reads it.
struct PreviewView: UIViewRepresentable {

    let session: AVCaptureSession
    /// Rotation in degrees clockwise. The screen derives it, so it is never `nil` in
    /// practice; an unsupported angle is skipped by the coordinator rather than applied.
    var rotationAngle: CGFloat
    var isFrontFacing: Bool
    /// Handed the coordinator once the layer exists, so the screen can convert a touch
    /// into a device point without the view model knowing about UIKit.
    var onBridgeReady: ((PreviewBridge) -> Void)?

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(view.previewLayer)
        context.coordinator.apply(rotationAngle: rotationAngle, isFrontFacing: isFrontFacing)
        DispatchQueue.main.async { onBridgeReady?(context.coordinator) }
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        context.coordinator.apply(rotationAngle: rotationAngle, isFrontFacing: isFrontFacing)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: PreviewBridge {

        private weak var layer: AVCaptureVideoPreviewLayer?
        private var lastAppliedAngle: CGFloat?
        private var lastMirrored: Bool?

        func attach(_ layer: AVCaptureVideoPreviewLayer) {
            self.layer = layer
        }

        /// Rotation and mirroring are applied together and never drift apart: the front
        /// camera needs both, and setting one without the other on iOS produces a
        /// rotated-but-mirrored or unmirrored-but-rotated preview.
        func apply(rotationAngle: CGFloat, isFrontFacing: Bool) {
            guard let layer, let connection = layer.connection else { return }
            if rotationAngle != lastAppliedAngle {
                guard connection.isVideoRotationAngleSupported(rotationAngle) else {
                    AppLog.warn(AppLog.camera, "preview rotation \(Int(rotationAngle))deg unsupported")
                    return
                }
                if let failure = LumaFrameSafety.perform({ connection.videoRotationAngle = rotationAngle }) {
                    AppLog.warn(AppLog.camera, "preview rotation rejected: \(failure)")
                    return
                }
                lastAppliedAngle = rotationAngle
            }
            guard isFrontFacing != lastMirrored else { return }
            LumaFrameSafety.perform {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = isFrontFacing
            }
            lastMirrored = isFrontFacing
        }

        /// `AVCaptureVideoPreviewLayer` owns the conversion between a touch in its own
        /// space and the capture device's field of view. Re-implementing it is how apps
        /// end up focusing in the wrong place in landscape.
        func devicePoint(fromViewPoint point: CGPoint) -> CGPoint? {
            layer?.captureDevicePointConverted(fromLayerPoint: point)
        }
    }
}

/// What `CameraScreen` needs from the preview, and nothing more.
protocol PreviewBridge: AnyObject {
    func devicePoint(fromViewPoint point: CGPoint) -> CGPoint?
}

/// Hosts the preview layer so SwiftUI controls the size and the layer controls the pixels.
final class PreviewContainerView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
