import CoreImage
import CoreVideo
import Foundation
import Vision

/// A computed subject mask: the statistics that go in a recipe, and the pixels
/// they describe.
///
/// Two lifetimes, two fields. The statistics are `Codable` and travel with the
/// photo; the buffer belongs to the frame it was computed from. Bundling them is
/// what stops a `CVPixelBuffer` ending up in a recipe.
struct SubjectMaskSnapshot: @unchecked Sendable {

    var stats: SubjectStat
    var buffer: CVPixelBuffer

    /// The mask as an image, scaled to the frame being graded.
    ///
    /// Vision's person mask is single-channel 8-bit: 255 subject, 0 background.
    /// Wrapped explicitly as grayscale rather than trusted to `CIImage(cvPixelBuffer:)`,
    /// which guesses the semantics — a guess here blends as if it were noise.
    /// Bytes are copied out under the lock; nothing here aliases live buffer memory.
    func image(matching extent: CGRect) -> CIImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
              let base = CVPixelBufferGetBaseAddress(buffer),
              CVPixelBufferGetPlaneCount(buffer) == 0
        else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return nil }
        let data = Data(bytes: base, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 8,
                                    bytesPerRow: bytesPerRow,
                                    space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent)
        else { return nil }
        var mask = CIImage(cgImage: cgImage)
        // The mask is the buffer's size; the frame is whatever the pipeline was
        // handed (often downscaled for preview). Scale, never crop: every mask
        // pixel has to land on the frame pixel it describes.
        if !extent.isEmpty, extent.width > 0, extent.height > 0 {
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: extent.width / CGFloat(width),
                scaleY: extent.height / CGFloat(height)))
        }
        return mask
    }
}

/// The seam the preview and the tests share: ask for a mask, read the latest one.
///
/// A protocol rather than the concrete provider so the preview path is testable
/// without Vision and without a camera — an untestable rule is the rule that
/// comes back.
protocol MaskProviding: AnyObject {

    /// Kicks off a computation for this frame unless one is already running or the
    /// last one is still fresh. Never blocks; never throws. A frame that cannot be
    /// masked is worth showing unmasked, not worth losing the preview over.
    func requestMask(for pixelBuffer: CVPixelBuffer)

    /// The latest usable snapshot, or `nil` when there is none. The pipeline treats
    /// `nil` as "grade globally", which is the honest fallback.
    var snapshot: SubjectMaskSnapshot? { get }
}

/// Apple's on-device person segmentation, behind the engine's mask contract.
///
/// **No bundled model, no licence question, no download.** `Vision`'s built-in
/// `VNGeneratePersonSegmentationRequest` needs no weights, so subject masking is
/// available on every device the app supports from the first launch. That is the
/// whole reason this is Vision built-in rather than a shipped `.mlmodel`: a model
/// file would need versioning, distribution and per-device verification for
/// exactly the same mask.
///
/// The mask runs at a reduced cadence on its own queue, not per frame.
/// Segmentation is the most expensive thing in the app and the mask changes far
/// slower than the image does; running it per frame would spend the frame budget
/// producing a result a few frames out of date.
final class PersonSegmentation: MaskProviding {

    /// How often a mask is recomputed. Fast enough that a face entering frame is
    /// picked up promptly, slow enough to be close to free.
    static let cadence: TimeInterval = 0.5

    /// Longest edge the request sees. Person segmentation is robust well below
    /// capture resolution, and the cost is linear in pixels.
    static let maximumPixelSize: CGFloat = 512

    /// Pixels sampled for statistics. A full pass over a 12 MP buffer is never
    /// needed to know its mean; a bounded grid is.
    static let sampleBudget = 4_000

    private let queue = DispatchQueue(label: "com.example.LumaFrame.segmentation",
                                      qos: .userInitiated)
    private let lock = NSLock()
    private var cached: SubjectMaskSnapshot?
    private var lastStart: CFAbsoluteTime = 0
    private var inFlight = false

    /// The request, built once and reused. Building a `VNRequest` per frame is a
    /// real cost and Vision is documented to reuse them.
    private lazy var request: VNGeneratePersonSegmentationRequest = {
        let made = VNGeneratePersonSegmentationRequest()
        // `.fast`: the mask is feathered and blends a grade, so its own precision
        // is not the limiting factor — the blend edge is.
        made.qualityLevel = .fast
        return made
    }()

    func requestMask(for pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let fresh = now - lastStart < Self.cadence
        guard !inFlight, !fresh else {
            lock.unlock()
            return
        }
        inFlight = true
        lastStart = now
        lock.unlock()

        // The buffer is retained by the block until the request finishes; the
        // preview has moved on by then, which is the point of the cadence.
        queue.async { [weak self, pixelBuffer] in
            guard let self else { return }
            let snapshot = Self.compute(pixelBuffer: pixelBuffer, request: self.request)
            self.lock.lock()
            // Only a usable mask displaces the cache. A "no subject" result must
            // not evict a good mask that is half a cadence old.
            if let snapshot, snapshot.stats.isUsable {
                self.cached = snapshot
            }
            self.inFlight = false
            self.lock.unlock()
        }
    }

    var snapshot: SubjectMaskSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Runs the request synchronously and returns a snapshot for any usable mask.
    ///
    /// Shared by the background preview path above and the export path, which
    /// recomputes the mask from the original bytes so the saved file and the
    /// preview are graded by the same numbers. `nil` for no usable subject —
    /// the common case, and not an error.
    static func compute(pixelBuffer: CVPixelBuffer,
                        request: VNGeneratePersonSegmentationRequest) -> SubjectMaskSnapshot? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            AppLog.warn(AppLog.ml, "segmentation failed: \(error.localizedDescription)")
            return nil
        }
        guard let observation = request.results?.first as? VNPixelBufferObservation else {
            return nil
        }
        let mask = observation.pixelBuffer
        let stats = statistics(of: mask)
        guard stats.isUsable else {
            AppLog.note(AppLog.ml, "subject mask not used: \(stats.decision())")
            return nil
        }
        return SubjectMaskSnapshot(stats: stats, buffer: mask)
    }

    /// Mean and spread over a bounded stride grid. A perfectly bimodal mask is
    /// half 0 and half 255 (deviation ~127.5), which maps "clearly a subject" to
    /// confidence 1.
    static func statistics(of buffer: CVPixelBuffer, budget: Int = sampleBudget) -> SubjectStat {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return SubjectStat(coverage: 0, confidence: 0)
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else {
            return SubjectStat(coverage: 0, confidence: 0)
        }
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let step = max(1, Int((Double(width * height) / Double(max(1, budget))).squareRoot().rounded()))

        var total = 0
        var count = 0
        var y = 0
        while y < height {
            let row = pointer.advanced(by: y * bytesPerRow)
            var x = 0
            while x < width {
                total += Int(row[x])
                count += 1
                x += step
            }
            y += step
        }
        guard count > 0 else { return SubjectStat(coverage: 0, confidence: 0) }
        let mean = Double(total) / Double(count)

        var sumSquares = 0.0
        y = 0
        while y < height {
            let row = pointer.advanced(by: y * bytesPerRow)
            var x = 0
            while x < width {
                let delta = Double(row[x]) - mean
                sumSquares += delta * delta
                x += step
            }
            y += step
        }
        let deviation = (sumSquares / Double(count)).squareRoot()
        return SubjectStat(coverage: Float(mean / 255.0),
                           confidence: min(1, max(0, Float(deviation / 127.5))))
    }

    /// Export-path helper: segments the saved original so the file blends by the
    /// same numbers the preview did.
    ///
    /// Preview and file must run the same program with the same parameters — that
    /// is the whole pipeline contract. The recipe carries the shutter-time
    /// statistics; the mask pixels are recomputed here from the original bytes,
    /// because the preview frame's pixels are a different (smaller) image. A
    /// caller whose recompute finds nothing usable blends globally; the recipe it
    /// writes must then drop the statistics, or the file would describe a blend
    /// it does not contain.
    ///
    /// One-shot and synchronous: the export path is already a background task, so
    /// no cadence, no cache, no queue — just the request and the buffer.
    static func exportBlendInput(for image: CIImage,
                                 stats: SubjectStat,
                                 context: CIContext) -> SubjectBlendInput? {
        guard stats.isUsable else { return nil }
        let width = Int(image.extent.width.rounded(.up))
        let height = Int(image.extent.height.rounded(.up))
        guard width > 0, height > 0 else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary,
                                  &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        context.render(image, to: buffer, bounds: image.extent, colorSpace: nil)
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        // Same request configuration as the preview cadence: a better-quality
        // export mask would be a different program, and preview and file must not
        // run different programs.
        guard let snapshot = compute(pixelBuffer: buffer, request: request),
              snapshot.stats.isUsable,
              let maskImage = snapshot.image(matching: image.extent) else {
            return nil
        }
        return SubjectBlendInput(mask: maskImage, stats: snapshot.stats)
    }
}
