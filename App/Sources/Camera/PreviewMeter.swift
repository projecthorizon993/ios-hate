import AVFoundation
import CoreVideo
import Foundation

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
