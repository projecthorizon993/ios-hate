import MetalKit
import SwiftUI

/// SwiftUI host for the processed preview.
///
/// Returns `nil` from `makeUIView` when there is no Metal device, and the caller falls
/// back to the direct `AVCaptureVideoPreviewLayer`. That is why this is a
/// `UIViewRepresentable` over `MTKView` rather than a SwiftUI drawing the pipeline itself:
/// Core Image needs a drawable and a command buffer, which SwiftUI's `Canvas` cannot
/// provide.
struct ProcessedPreviewView: UIViewRepresentable {

    let preview: ProcessedPreview

    /// Bumped by the caller whenever a new frame should be shown. SwiftUI does not
    /// redraw a `MTKView` on its own, and polling it at 30 Hz from a timer would wake the
    /// main actor for frames that may not exist yet.
    let redrawToken: Int

    func makeUIView(context: Context) -> MTKView? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = ProcessedPreviewRenderer(metalDevice: device)
        else { return nil }
        renderer.attach(to: preview)
        // Held by the coordinator so it outlives `makeUIView`.
        context.coordinator.renderer = renderer
        return renderer.metalView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.redraw()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: ProcessedPreviewRenderer?
    }
}
