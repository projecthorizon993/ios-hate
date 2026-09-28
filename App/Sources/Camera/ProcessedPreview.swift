import AVFoundation
import CoreImage
import Foundation
import MetalKit

/// A live preview that shows the actual look, not the unprocessed sensor image.
///
/// The alternative — an `AVCaptureVideoPreviewLayer` — is the fastest preview there is
/// and it is what the app used before looks existed. It draws the sensor buffer straight
/// to the screen, so a look applied only at capture time means the user never sees what
/// they are about to get, which makes the intensity slider a guess.
///
/// So there are two paths, chosen by whether the recipe does anything:
///
/// - **Identity recipe**: the preview layer, untouched. Zero cost, and it is the case
///   that is on screen most of the time.
/// - **Anything to do**: frames come through a `AVCaptureVideoDataOutput`, run the same
///   `ProcessingPipeline` the saved photo runs, and are drawn into a `MTKView`.
///
/// The switch is on `ProcessingSettings.isIdentity` rather than on "is a look selected",
/// so a look dialled to zero also gets the cheap path.
///
/// Deliberately not doing this:
/// - **No CIContext per frame.** One context, reused; creating one is expensive enough to
///   matter at 30 fps.
/// - **No full-resolution preview.** The output is capped, because previewing at 12 MP
///   costs the same as previewing at 720p on a phone that is already thermally limited.
/// - **No work on the main actor.** Capture, processing and encoding all happen on a
///   dedicated queue; only the drawable is touched on the main thread.
///
/// Inherits `NSObject` because `AVCaptureVideoDataOutputSampleBufferDelegate` is an
/// Objective-C protocol, and Swift will not let a plain class declare that conformance.
final class ProcessedPreview: NSObject {

    /// Longest edge of the preview the processor sees. Well above a screen's needs and far
    /// below a sensor frame, which is the whole point.
    static let maximumPixelSize: CGFloat = 1280

    /// The capture output feeding this. Owned here rather than by the session controller
    /// because it is only wanted when something is being processed.
    let output = AVCaptureVideoDataOutput()

    private let queue = DispatchQueue(label: "com.example.LumaFrame.processedpreview",
                                      qos: .userInitiated)
    private let pipeline: ProcessingPipeline
    private let context: CIContext
    private let metalDevice: MTLDevice?

    /// Set from the main actor whenever the recipe or the colour spaces change.
    private var settings = ProcessingSettings.none
    private var inputSpace: ColorSpace = .sRGB
    private var outputSpace: ColorSpace = .sRGB

    /// The most recent rendered image, for the still-frame grab in the compare control.
    private var lastRendered: CIImage?

    override init() {
        pipeline = ProcessingPipeline()
        metalDevice = MTLCreateSystemDefaultDevice()
        if let device = metalDevice {
            context = CIContext(mtlDevice: device)
        } else {
            // No Metal device: the live preview is unavailable and `isAvailable` says so,
            // but the still path still works on the CPU. Force-unwrapping the device here
            // would crash the app on exactly the hardware least able to report it.
            context = CIContext()
            AppLog.warn(AppLog.processing, "no Metal device; stills will be processed on the CPU")
        }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        super.init()
    }

    /// `false` when there is no Metal device, in which case the caller should keep the
    /// direct preview layer.
    var isAvailable: Bool { metalDevice != nil }

    /// The recipe, and the spaces the frames arrive in and leave in.
    ///
    /// Synchronised rather than hopped, because the recipe is read on every frame and a
    /// `queue.async` here would apply a frame with the previous frame's settings. Only the
    /// main actor calls this, and the preview queue is the only reader, so there is no
    /// path where the two could be the same thread.
    func update(settings: ProcessingSettings, inputSpace: ColorSpace, outputSpace: ColorSpace) {
        queue.sync {
            self.settings = settings
            self.inputSpace = inputSpace
            self.outputSpace = outputSpace
        }
    }

    /// The last frame the pipeline produced, for a still comparison.
    func lastStill() -> CIImage? {
        queue.sync { lastRendered }
    }

    /// Encodes a processed still to HEVC data.
    ///
    /// Separate from the preview on purpose: this is the path the "save the processed
    /// frame" control uses, and it must run the identical `ProcessingPipeline` call so the
    /// still and the preview cannot disagree.
    func encodeStill(to url: URL, quality: Float = 0.9) {
        guard let still = lastRendered else {
            AppLog.warn(AppLog.processing, "no processed frame available to save")
            return
        }
        // `AVAssetWriter` is the only encoder that writes HEVC from a `CIImage` without
        // an intermediate file, and the app has to produce HEVC because that is the codec
        // chosen for stills. It has a throwing initialiser, so a bad URL fails here
        // rather than silently producing a zero-byte file.
        let encoder: AVAssetWriter
        do {
            encoder = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            AppLog.fail(AppLog.processing, "still encoder could not be created: \(error.localizedDescription)")
            return
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(still.extent.width),
            AVVideoHeightKey: Int(still.extent.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(quality * 24_000_000)
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(still.extent.width),
                kCVPixelBufferHeightKey as String: Int(still.extent.height)
            ]
        )

        guard encoder.canAdd(input) else {
            AppLog.fail(AppLog.processing, "still encoder rejected its input")
            return
        }
        encoder.add(input)
        encoder.startWriting()
        encoder.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            AppLog.fail(AppLog.processing, "still encoder has no pixel buffer pool")
            return
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let pixelBuffer = buffer else {
            AppLog.fail(AppLog.processing, "could not allocate a pixel buffer for the still")
            return
        }

        context.render(still,
                       to: pixelBuffer,
                       bounds: still.extent,
                       colorSpace: outputSpace.cgColorSpace)

        let finish: () -> Void = {
            input.markAsFinished()
            encoder.finishWriting {
                if encoder.status == .failed {
                    AppLog.fail(AppLog.processing, "still encode failed: \(encoder.error?.localizedDescription ?? "unknown")")
                } else {
                    AppLog.note(AppLog.processing, "processed still written")
                }
            }
        }

        if input.isReadyForMoreMediaData {
            adaptor.append(pixelBuffer, withPresentationTime: .zero)
            finish()
        } else {
            input.requestMediaDataWhenReady(on: queue) {
                if input.isReadyForMoreMediaData {
                    adaptor.append(pixelBuffer, withPresentationTime: .zero)
                    finish()
                }
            }
        }
    }
}

// MARK: - Frame intake

extension ProcessedPreview: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var image = CIImage(cvPixelBuffer: pixelBuffer)

        // Downscale before anything else. Everything downstream is proportional to the
        // pixel count, and this is the cheapest place to reduce it.
        let longEdge = max(image.extent.width, image.extent.height)
        if longEdge > Self.maximumPixelSize {
            let scale = Self.maximumPixelSize / longEdge
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let rendered = pipeline.renderOrOriginal(image,
                                                settings: settings,
                                                inputSpace: inputSpace,
                                                outputSpace: outputSpace)
        lastRendered = rendered
    }
}

/// Draws whatever `ProcessedPreview` last rendered into a `MTKView`.
///
/// Kept apart from `ProcessedPreview` on purpose: the capture side is a class with a
/// delegate and a queue, the display side is a `UIView` with a drawable, and merging them
/// would mean the view's lifetime controlled the capture output's.
///
/// `@MainActor` because `MTKViewDelegate` is main-actor isolated in this SDK, so a
/// non-isolated class cannot satisfy it. That is also the right isolation anyway: the only
/// thing touched here is the drawable, and only the main thread may touch that.
@MainActor
final class ProcessedPreviewRenderer: NSObject, MTKViewDelegate {

    private let view: MTKView
    private let context: CIContext
    private weak var source: ProcessedPreview?

    init?(metalDevice: MTLDevice) {
        guard metalDevice.makeCommandQueue() != nil else { return nil }
        view = MTKView(frame: .zero, device: metalDevice)
        super.init()

        context = CIContext(mtlDevice: metalDevice)
        view.device = metalDevice
        view.framebufferOnly = false
        // `framebufferOnly = false` because the pipeline writes into the drawable's
        // texture through Core Image, not through the render command encoder.
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.preferredFramesPerSecond = 30
        view.delegate = self
    }

    func attach(to source: ProcessedPreview) {
        self.source = source
    }

    var metalView: MTKView { view }

    /// Draws the latest processed frame, if there is one.
    ///
    /// `redraw()` is the public entry point and only *asks* for a draw. The work happens in
    /// `draw(in:)`, which is the delegate's required method — `MTKView` owns when a
    /// drawable exists, and reaching for `currentDrawable` from outside the delegate means
    /// rendering into a texture the view is not presenting.
    func redraw() {
        view.setNeedsDisplay()
    }

    /// The one required member of `MTKViewDelegate`. `enableSetNeedsDisplay` is on and the
    /// view is paused, so this is called only when `redraw()` or a size change asks for it.
    func draw(in view: MTKView) {
        guard let image = source?.lastStill(),
              let drawable = view.currentDrawable,
              // `MTLDevice` has no `makeCommandBuffer`; the buffer comes from a queue.
              let queue = view.device?.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer()
        else { return }

        let drawableSize = view.drawableSize
        guard drawableSize.width > 1, drawableSize.height > 1 else { return }

        context.render(image,
                       to: drawable.texture,
                       commandBuffer: commandBuffer,
                       bounds: CGRect(origin: .zero, size: drawableSize),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// The drawable is recreated on every size change, so the view renders into a texture
    /// that is no longer attached to anything unless it is asked for a draw again — which
    /// is what makes the preview go black on rotation if this is left out.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        redraw()
    }
}
