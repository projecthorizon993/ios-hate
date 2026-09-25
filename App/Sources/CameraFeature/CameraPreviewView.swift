import AVFoundation
import CoreImage
import MetalKit
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let image: CIImage?
    let showsProcessedImage: Bool

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewContainerView, context: Context) {
        view.previewLayer.session = session
        view.updateConnectionOrientation()
        view.updateProcessedImage(image, showsProcessedImage: showsProcessedImage)
    }
}

final class PreviewContainerView: UIView, MTKViewDelegate {
    let previewLayer = AVCaptureVideoPreviewLayer()
    let metalView: MTKView

    private let ciContext: CIContext
    private let commandQueue: MTLCommandQueue?
    private var currentImage: CIImage?

    override init(frame: CGRect) {
        let metalDevice = MTLCreateSystemDefaultDevice()
        metalView = MTKView(frame: .zero, device: metalDevice)
        if let metalDevice {
            ciContext = CIContext(mtlDevice: metalDevice)
            commandQueue = metalDevice.makeCommandQueue()
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
            commandQueue = nil
        }
        super.init(frame: frame)
        backgroundColor = .black
        layer.addSublayer(previewLayer)
        metalView.delegate = self
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.framebufferOnly = false
        metalView.autoResizeDrawable = false
        metalView.contentMode = .scaleAspectFill
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.isHidden = true
        addSubview(metalView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        metalView.frame = bounds
        updateConnectionOrientation()
    }

    func updateConnectionOrientation() {
        guard let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(90) else { return }
        connection.videoRotationAngle = 90
    }

    func updateProcessedImage(_ image: CIImage?, showsProcessedImage: Bool) {
        currentImage = image
        metalView.isHidden = image == nil || !showsProcessedImage
        if let image, showsProcessedImage {
            let extent = image.extent
            let origin = CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
            currentImage = image.transformed(by: origin)
            metalView.drawableSize = currentImage?.extent.size ?? .zero
            metalView.draw()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let image = currentImage,
              let commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let drawable = view.currentDrawable else { return }

        let extent = image.extent
        view.drawableSize = extent.size
        ciContext.render(
            image,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: extent,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
