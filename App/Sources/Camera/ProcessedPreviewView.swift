import MetalKit
import SwiftUI

/// Hosts the `MTKView` the processed preview draws into.
///
/// Exists because `UIViewRepresentable` will not accept a failable `makeUIView`. The first
/// version returned `MTKView?` to signal "no Metal device, use the direct preview layer
/// instead", and the protocol rejected it — and the rejection is correct: the associated
/// type has to be one concrete view type whether or not the backing thing exists.
///
/// So the host is a plain `UIView` that either contains a live `MTKView` or contains
/// nothing, and `hasDrawable` reports which. The caller checks that and keeps
/// `AVCaptureVideoPreviewLayer` when it is false.
struct ProcessedPreviewView: UIViewRepresentable {

    let preview: ProcessedPreview

    /// Bumped by the caller whenever a new frame should be shown. SwiftUI does not
    /// redraw a `MTKView` on its own, and polling it from a timer would wake the main
    /// actor for frames that may not exist yet.
    let redrawToken: Int

    func makeUIView(context: Context) -> HostView {
        let host = HostView()
        context.coordinator.host = host
        if let device = MTLCreateSystemDefaultDevice(),
           let renderer = ProcessedPreviewRenderer(metalDevice: device) {
            renderer.attach(to: preview)
            context.coordinator.renderer = renderer
            host.install(renderer.metalView)
        } else {
            AppLog.warn(AppLog.processing, "processed preview unavailable; using the direct preview layer")
        }
        return host
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        context.coordinator.renderer?.redraw()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: ProcessedPreviewRenderer?
        var host: HostView?
    }

    /// The representable's view type. `MTKView` is optional inside it rather than being
    /// the type itself.
    final class HostView: UIView {
        private(set) var hasDrawable = false

        func install(_ metalView: MTKView) {
            metalView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(metalView)
            NSLayoutConstraint.activate([
                metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
                metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
                metalView.topAnchor.constraint(equalTo: topAnchor),
                metalView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            hasDrawable = true
        }
    }
}
