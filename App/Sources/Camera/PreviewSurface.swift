// The viewfinder: frame source, meter, processing and the two UIKit wrappers.
//
// ProcessedPreview is the real surface; PreviewView and ProcessedPreviewView are the representables that host it and PreviewMeter is the exposure and highlight read-out it draws.
//
// Merged mechanically by scripts/consolidate.mjs. Declarations were moved whole and
// nothing was edited; see the commit message for the reasoning.

import AVFoundation
import CoreImage
import Foundation
import MetalKit
import CoreVideo
import SwiftUI
import UIKit

// MARK: - engine (was App/Sources/Camera/ProcessedPreview.swift)





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

    /// Frames are handed in by `PreviewMeter`, which owns the session's single video data
    /// output.
    ///
    /// It used to own a second one. It was never added to the session on the first
    /// version, so the processed viewfinder got no frames at all and rendered black; when
    /// that was fixed by adding it unconditionally, the session had to carry two video
    /// data outputs with different pixel formats, which is bandwidth nobody needs. One
    /// output, two consumers: the meter reads the luma plane and the pipeline gets the
    /// same buffer. Sharing is also faster, since bi-planar 420 is a third of the bytes of
    /// BGRA.
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

    /// Segmentation state, guarded because it is written from the segmentation queue and
    /// read from the capture queue.
    private let maskLock = NSLock()
    private var cachedMask: SubjectSegmentation.Result?
    private var lastSegmentationAt: UInt64?

    private let segmentationQueue = DispatchQueue(label: "com.example.LumaFrame.preview.segmentation",
                                                   qos: .userInitiated)

    override init() {
        // Before `super.init()`: `output` and the delegate hand-off both need a fully
        // initialised `self`, and Swift will not let `super.init()` run twice.
        pipeline = ProcessingPipeline()
        metalDevice = MTLCreateSystemDefaultDevice()
        // The working colour space is stated, not inherited. Core Image's default already is
        // linear sRGB, so this is a no-op today — which is the point. `LUTProcessor` hands
        // `CIColorCubeWithColorSpace` the table's authored space and relies on the working
        // space being linear to convert into, and a context whose working space is implicit
        // is a context whose working space is Core Image's business. Same reason and same
        // option as `ProcessingPipeline.encodeJPEG`.
        let workingSpace: [CIContextOption: Any] = [
            .workingColorSpace: ColorSpace.linearSRGB.cgColorSpace
        ]
        if let device = metalDevice {
            context = CIContext(mtlDevice: device, options: workingSpace)
        } else {
            // No Metal device: the live preview is unavailable and `isAvailable` says so,
            // but the still path still works on the CPU. Force-unwrapping the device here
            // would crash the app on exactly the hardware least able to report it.
            context = CIContext(options: workingSpace)
            AppLog.warn(AppLog.processing, "no Metal device; stills will be processed on the CPU")
        }
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

    /// Compare mode: render the frame with nothing applied.
    ///
    /// A **hold, not a toggle** (`DESIGN_SPEC.md`, Controls). The user is checking what
    /// the look is doing to their photo, and the answer has to be available continuously
    /// while they look, not after they commit to a mode change and find their way back.
    ///
    /// Implemented by skipping the pipeline rather than by setting the intensity to zero,
    /// so the compare path is genuinely the unprocessed frame and cannot drift from it.
    func setComparing(_ comparing: Bool) {
        queue.sync { isComparing = comparing }
    }

    private var isComparing = false

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

extension ProcessedPreview {

    /// Processes one frame handed over by the session's video data output.
    ///
    /// Not a delegate any more. The buffer arrives unlocked, so the meter's own read and
    /// this are two independent readers of the same memory rather than two consumers
    /// fighting over a lock.
    func render(pixelBuffer: CVPixelBuffer) {
        var image = CIImage(cvPixelBuffer: pixelBuffer)

        // Downscale before anything else. Everything downstream is proportional to the
        // pixel count, and this is the cheapest place to reduce it.
        let longEdge = max(image.extent.width, image.extent.height)
        if longEdge > Self.maximumPixelSize {
            let scale = Self.maximumPixelSize / longEdge
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        // Compare mode bypasses the pipeline entirely rather than rendering the look at
        // zero intensity, so what the user sees while holding is the actual unprocessed
        // frame and not a second code path that happens to look like one.
        if isComparing {
            lastRendered = image
            return
        }

        // Segmentation runs on a cadence, not per frame, and on its own queue: it is the
        // most expensive thing in the app and the mask changes far slower than the image
        // does. A nil is a real "no subject here" rather than "not computed yet", so the
        // look falls back to global for that frame.
        updateSubjectMaskIfDue(for: pixelBuffer)

        let rendered = pipeline.renderOrOriginal(image,
                                                settings: recipeCarryingMask,
                                                inputSpace: inputSpace,
                                                outputSpace: outputSpace,
                                                subjectMaskImage: currentMaskImage)
        lastRendered = rendered
    }

    /// Re-runs segmentation at most once per `SubjectSegmentation.cadence`.
    private func updateSubjectMaskIfDue(for pixelBuffer: CVPixelBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        let interval = UInt64(SubjectSegmentation.cadence * 1_000_000_000)
        if let lastAt = lastSegmentationAt, now &- lastAt < interval { return }
        lastSegmentationAt = now

        segmentationQueue.async { [weak self] in
            guard let self else { return }
            guard let result = SubjectSegmentation.compute(for: pixelBuffer) else {
                self.setMask(nil)
                return
            }
            // A mask the pipeline would reject is not carried forward. Keeping it would let
            // a stale mask survive into frames it no longer describes, and the most common
            // rejection is a mask that covers the whole frame — carrying that forward would
            // blend by it forever.
            guard result.mask.isUsable else {
                AppLog.note(AppLog.ml, "subject mask not used: \(result.mask.decision())")
                self.setMask(nil)
                return
            }
            self.setMask(result)
        }
    }

    private func setMask(_ result: SubjectSegmentation.Result?) {
        maskLock.lock()
        cachedMask = result
        maskLock.unlock()
        if let result {
            AppLog.note(AppLog.ml, "subject mask ready: \(result.mask.decision())")
        }
    }

    private var currentMaskImage: CIImage? {
        maskLock.lock()
        defer { maskLock.unlock() }
        return cachedMask?.image()
    }

    /// The recipe with the mask's statistics folded in, so a capture records that a
    /// subject was found. The pixels stay in `cachedMask`, because they belong to a frame
    /// and a `CIImage` cannot go in a photo's metadata.
    private var recipeCarryingMask: ProcessingSettings {
        maskLock.lock()
        defer { maskLock.unlock() }
        var recipe = settings
        recipe.subjectMask = cachedMask?.mask
        return recipe
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
        // `context` is assigned before `super.init()` because Swift requires every stored
        // property to be initialised by the time the superclass initialiser runs.
        // The working colour space is stated for the same reason as in `ProcessedPreview`
        // above: the colour-managed LUT path depends on it, so it is not left implicit.
        context = CIContext(mtlDevice: metalDevice,
                           options: [.workingColorSpace: ColorSpace.linearSRGB.cgColorSpace])
        view = MTKView(frame: .zero, device: metalDevice)
        super.init()

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

// MARK: - meter (was App/Sources/Camera/PreviewMeter.swift)




/// Measures the preview so the derived HDR badge and the debug overlay have real
/// numbers behind them.
///
/// `docs/ARCHITECTURE.md` section 2.4 is explicit that there is no public API for the
/// system's HDR decision, so the scene half of the badge is our own meter. That makes
/// this type a correctness risk rather than a nicety, and the reason it is bounded by
/// construction:
///
/// - `alwaysDiscardsLateVideoFrames` is on, so a slow consumer drops frames instead of
///   growing a queue;
/// - only a sparse grid of luma samples is read, never a full-frame pass;
/// - results are published at a fixed low rate, so the main actor is never the
///   bottleneck the capture queue has to wait on.
final class PreviewMeter: NSObject {

    struct Sample: Equatable, Sendable {
        /// Fraction of sampled luma at or above `clipLevel`.
        var highlightClipFraction: Double
        /// Mean sampled luma, 0...1.
        var averageLuma: Double
        var framesPerSecond: Double

        /// Coarse scene reading used for the debug overlay and for deciding whether a
        /// scene is dark enough to need a slower shutter. Deliberately not a
        /// replacement for proper metering: it is a grid average, not an integral.
        var isDarkScene: Bool { averageLuma < 0.18 }
    }

    /// Luma at or above this is treated as blown. 250/255 leaves a one-code margin so
    /// 8-bit full-range noise does not read as clipping.
    static let clipLevel: UInt8 = 250

    /// Upper bound on samples read per frame, so the cost is the same on a 12 MP
    /// format and on a 720p one.
    static let sampleBudget = 4_000

    /// How often a sample is handed to the main actor. 4 Hz is faster than anyone can
    /// read a changing number and far slower than the preview frame rate.
    static let publishInterval: TimeInterval = 0.25

    let output: AVCaptureVideoDataOutput

    /// Called on the main queue.
    var onSample: ((Sample) -> Void)?

    /// Called on the meter queue, once per frame, with the **unlocked** buffer.
    ///
    /// This is how the processed preview gets its frames. The session carries one video
    /// data output, shared: bi-planar 420 costs a third of the bandwidth of BGRA, and two
    /// outputs of different formats on one session is more than the pipeline needs. The
    /// buffer is handed over after the meter's own read is done, so the two are readers of
    /// the same memory rather than competitors for a lock.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let queue = DispatchQueue(label: "com.example.LumaFrame.meter", qos: .utility)
    private var windowFrames: Int = 0
    private var windowStart: CFTimeInterval = 0

    override init() {
        output = AVCaptureVideoDataOutput()
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        // Planar full-range 4:2:0 so the luma plane can be read directly. A BGRA output
        // would mean three interleaved channels and an interleave-aware stride for one
        // number the user actually sees.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    // MARK: - Statistics

    /// Pure sampling step, separated from AVFoundation so it can be unit tested against
    /// synthetic luma planes.
    static func measure(luma: UnsafePointer<UInt8>?,
                        width: Int,
                        height: Int,
                        bytesPerRow: Int,
                        budget: Int = sampleBudget,
                        clipLevel: UInt8 = clipLevel) -> (clipFraction: Double, averageLuma: Double) {
        guard let luma, width > 0, height > 0, bytesPerRow >= width else { return (0, 0) }
        let step = max(1, Int((Double(width * height) / Double(max(1, budget))).squareRoot().rounded()))
        var total = 0
        var clipped = 0
        var samples = 0
        var y = 0
        while y < height {
            let row = luma.advanced(by: y * bytesPerRow)
            var x = 0
            while x < width {
                let value = row[x]
                total += Int(value)
                if value >= clipLevel { clipped += 1 }
                samples += 1
                x += step
            }
            y += step
        }
        guard samples > 0 else { return (0, 0) }
        return (Double(clipped) / Double(samples), Double(total) / Double(samples) / 255.0)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension PreviewMeter: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        windowFrames += 1
        if windowStart == 0 { windowStart = now }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        _ = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        else { return }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        let measured = Self.measure(luma: base.assumingMemoryBound(to: UInt8.self),
                                    width: width,
                                    height: height,
                                    bytesPerRow: bytesPerRow)

        // Hand the frame on before the publish-rate guard below, so the processed preview
        // gets **every** frame while the debug overlay is only published a few times a
        // second. They are different consumers with different rates, and gating the
        // preview by the overlay's publish rate would cap the preview at 4 Hz.
        onFrame?(pixelBuffer)

        let elapsed = now - windowStart
        let fps = elapsed > 0 ? Double(windowFrames) / elapsed : 0
        guard elapsed >= Self.publishInterval else { return }
        windowFrames = 0
        windowStart = now

        let sample = Sample(highlightClipFraction: measured.clipFraction,
                            averageLuma: measured.averageLuma,
                            framesPerSecond: fps)
        DispatchQueue.main.async { [weak self] in
            self?.onSample?(sample)
        }
    }
}

// MARK: - view (was App/Sources/Camera/PreviewView.swift)




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

        /// Hands over the layer, and forgets anything previously applied.
        ///
        /// ## Why the caches are cleared here
        ///
        /// `lastAppliedAngle` and `lastMirrored` record what was written to **a
        /// connection**, not to a layer. They exist so `apply` does not rewrite the
        /// connection on every SwiftUI update, and they were doing that job — but the
        /// Coordinator outlives a lens flip, so after `back -> front -> back` they still
        /// described the connection from two flips ago.
        ///
        /// A freshly connected `AVCaptureConnection` starts at
        /// `videoRotationAngle == 0` and unmirrored. So whenever the incoming angle happened
        /// to equal the cached one, the `if rotationAngle != lastAppliedAngle` guard below
        /// skipped the write and left the new connection at 0 — the raw sensor orientation,
        /// which for the front camera in portrait is exactly upside down. Same for mirroring:
        /// returning to the front camera with `lastMirrored` already `true` meant the mirror
        /// was never written to the new connection.
        ///
        /// That is the whole defect: a cache that outlives the thing it caches. Comparing by
        /// identity keeps the optimisation for the common case (same layer, many updates) and
        /// resets only when the layer genuinely changes.
        func attach(_ layer: AVCaptureVideoPreviewLayer) {
            guard self.layer !== layer else { return }
            self.layer = layer
            lastAppliedAngle = nil
            lastMirrored = nil
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

// MARK: - processedview (was App/Sources/Camera/ProcessedPreviewView.swift)



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
