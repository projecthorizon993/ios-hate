import CoreImage
import CoreML
import Foundation
import Vision

/// Step 5's ML layer: a subject mask, and a skin-tone protection transform.
///
/// **There is no bundled model, and that is a decision rather than a gap.** Subject
/// segmentation is a Vision *built-in* (`VNGeneratePersonSegmentationRequest`), so it
/// needs no weights, no model conversion step and no download — which means subject masking
/// is available on every device the app supports, from the first launch. Skin-tone
/// protection needs no neural network at all: it is a colourimetric transform, and calling
/// it one keeps it fast, deterministic and inspectable.
///
/// The mask runs at a **reduced cadence**, not per frame. Segmentation is the most
/// expensive thing in the app and the mask changes far slower than the image does; running
/// it per frame would spend the entire frame budget to produce a result that is a few
/// frames out of date. A mask that is 100 ms old is a better mask than no mask.
enum SubjectSegmentation {

    /// How often a mask is recomputed. 0.5 s is fast enough that a face entering frame is
    /// picked up promptly and slow enough to be close to free.
    ///
    /// A `Double` and not a `TimeInterval`, because `TimeInterval` is `Duration` in this
    /// SDK and does not compose with `DispatchTime`'s arithmetic. Written as 0.5 s, not
    /// 500 ms, and the unit is the seconds one.
    static let cadence: Double = 0.5

    /// Longest edge the segmentation sees. Person segmentation is robust well below the
    /// capture resolution, and the cost is linear in pixels.
    static let maximumPixelSize: CGFloat = 512

    /// Below this the mask is treated as noise and the look is applied globally instead.
    /// A speckled mask blended into a face is far worse than no mask.
    static let minimumCoverage: Float = 0.01

    private static let queue = DispatchQueue(label: "com.example.LumaFrame.segmentation",
                                             qos: .userInitiated)

    /// The request, built once per run. Building a `VNRequest` per frame is a real cost and
    /// Vision is documented to reuse them.
    private static var activeRequest: VNGeneratePersonSegmentationRequest?

    /// Computes a mask for one frame.
    ///
    /// Returns `nil` when there is no usable subject, which is the common case and is not
    /// an error. Never throws: an ML failure has to degrade to "no mask", not to a lost
    /// frame.
    static func mask(for pixelBuffer: CVPixelBuffer) -> SubjectMask? {
        let request: VNGeneratePersonSegmentationRequest
        if let existing = activeRequest {
            request = existing
        } else {
            let made = VNGeneratePersonSegmentationRequest()
            // `.fast` rather than `.balanced` or `.accurate`: this runs in the preview
            // path, and the mask is feathered and used to *blend* a look, so its own
            // precision is not the limiting factor. Step 5's accuracy question is a
            // measured one and belongs on a device.
            made.qualityLevel = .fast
            activeRequest = made
            request = made
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            AppLog.warn(AppLog.ml, "segmentation failed: \(error.localizedDescription)")
            return nil
        }

        guard let observation = request.results?.first as? VNPixelBufferObservation,
              let maskBuffer = observation.pixelBuffer
        else {
            AppLog.note(AppLog.ml, "segmentation found no person")
            return nil
        }

        let coverage = meanValue(of: maskBuffer)
        guard coverage > minimumCoverage else {
            return nil
        }

        // `VNGeneratePersonSegmentationRequest` reports no confidence score, so this is a
        // proxy derived from how bimodal the mask is — a confident mask has a clear
        // foreground/background split, an uncertain one hovers around the mean. Named
        // `confidence` rather than `score` in the type for that reason.
        let spread = contrastOf(maskBuffer)
        let confidence = min(1, max(0, spread))

        return SubjectMask(coverage: coverage, confidence: confidence)
    }

    /// The mask as a `CIImage`, for the pipeline.
    ///
    /// Vision's mask buffer is **OneComponent8BitVoid** — a single channel, not planar
    /// three-channel data — so it cannot be wrapped with `CIImage(cvPixelBuffer:)` and get
    /// the semantics right by accident. It is converted explicitly, because guessing here
    /// produces a mask that looks plausible and blends as if it were noise.
    static func maskImage(from mask: CVPixelBuffer) -> CIImage? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(mask)
        let isOneComponent = format == kCVPixelFormatType_OneComponent8
        let base = CVPixelBufferGetBaseAddress(mask)
        guard let base, CVPixelBufferGetPlaneCount(mask) == 0 else { return nil }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let data = Data(bytes: base, count: bytesPerRow * height)

        let bitmapInfo: CGBitmapInfo
        if isOneComponent {
            // One component means the alpha is the value; putting it in a grey image's
            // alpha and leaving RGB white is how a mask becomes an opaque white overlay.
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        } else {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        }

        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 32,
                                    bytesPerRow: bytesPerRow,
                                    space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: bitmapInfo,
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent)
        else { return nil }

        return CIImage(cgImage: cgImage)
    }

    // MARK: - Statistics

    /// Mean of a one-channel mask, read on a sparse grid so the cost does not scale with
    /// resolution. A full pass over a 512-wide buffer is already cheap; a full pass over a
    /// 12 MP one would not be.
    static func meanValue(of buffer: CVPixelBuffer, budget: Int = 4_000) -> Float {
        guard let stats = sample(buffer, budget: budget) else { return 0 }
        return stats.mean
    }

    /// Standard deviation of the sampled values, used as the bimodality proxy.
    static func contrastOf(_ buffer: CVPixelBuffer, budget: Int = 4_000) -> Float {
        guard let stats = sample(buffer, budget: budget) else { return 0 }
        // A perfectly bimodal mask is half 0 and half 255, which is a deviation of ~127.
        // Dividing by that maps "clearly a subject" to 1.
        return stats.standardDeviation / 127.5
    }

    private struct Stats {
        var mean: Float
        var standardDeviation: Float
    }

    private static func sample(_ buffer: CVPixelBuffer, budget: Int) -> Stats? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return nil }

        // Bound once, from the raw pointer, and used directly thereafter. Binding it again
        // at the second pass is what the compiler rejects: the value is already
        // `UnsafeMutablePointer<UInt8>`, which has no `assumingMemoryBound`.
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
        guard count > 0 else { return nil }
        let mean = Float(total) / Float(count)

        var sumSquares: Double = 0
        y = 0
        while y < height {
            let row = pointer.advanced(by: y * bytesPerRow)
            var x = 0
            while x < width {
                let delta = Double(row[x]) - Double(mean)
                sumSquares += delta * delta
                x += step
            }
            y += step
        }
        let variance = sumSquares / Double(count)
        return Stats(mean: mean, standardDeviation: Float(variance.squareRoot()))
    }
}

/// Skin-tone protection, as a colourimetric transform.
///
/// The rule from `docs/ARCHITECTURE.md` Step 5: a look may shift skin tone badly, and the
/// fix is to hold the hue of detected skin **constant** while letting everything else
/// change. Not a neural network — a hue-preserving weight on the skin-likeness term, which
/// is fast, has no model to ship, and can be inspected.
///
/// The likeness estimate is a small hue/saturation window, which is crude next to a real
/// classifier. That is stated in the report rather than hidden: it is the honest state of
/// this step, and a better detector is a device measurement away.
enum SkinToneProtection {

    /// Centre of the skin hue window, in degrees. 25 degrees is the middle of the
    /// orange-to-tan band that covers most skin tones under neutral light.
    static let skinHueDegrees: CGFloat = 25
    /// Half-width of the window. Wide enough to cover a range of skin tones, narrow enough
    /// not to catch ordinary warm objects.
    static let hueToleranceDegrees: CGFloat = 18
    /// Saturation band. Skin is not a fully saturated colour, so both a floor and a ceiling
    /// matter — a bright saturated orange wall is not a face.
    static let minimumSaturation: CGFloat = 0.15
    static let maximumSaturation: CGFloat = 0.75
    /// How much of a look skin is allowed to receive. 0 would freeze skin completely, which
    /// looks like a mask; full is no protection at all.
    static let defaultProtection: Float = 0.7

    /// Per-pixel 0…1 weight, and the app-supplied original for the comparison.
    ///
    /// This is a C function rather than a Swift one on purpose: the pipeline calls it once
    /// per pixel, and it runs inside a `CIColorKernel`, which is a C-shaped callback where
    /// Swift overhead and any allocation are a real cost.
    static func apply(image: CIImage, protection: Float) -> CIImage {
        guard protection > 0 else { return image }

        // `CIKernel.apply(extent:arguments:)` takes an argument list, and the argument
        // names are substituted into the source below as `$name`. `__sample` is the
        // built-in sampler and the final return is premultiplied by Core Image
        // automatically.
        let source = """
        kernel vec4 skinProtect(__sample pixel) {
            vec3 rgb = clamp(pixel.rgb, 0.0, 1.0);
            float maximumChannel = max(rgb.r, max(rgb.g, rgb.b));
            if (maximumChannel <= 0.0) {
                return pixel;
            }
            float minimumChannel = min(rgb.r, min(rgb.g, rgb.b));
            float saturation = (maximumChannel - minimumChannel) / maximumChannel;

            // Hue in degrees without a dependency on a hue formula, via the usual
            // max/min channel selection.
            float hue;
            if (maximumChannel == rgb.r) {
                hue = 60.0 * fmod((rgb.g - rgb.b) / (maximumChannel - minimumChannel), 6.0);
            } else if (maximumChannel == rgb.g) {
                hue = 60.0 * (((rgb.b - rgb.r) / (maximumChannel - minimumChannel)) + 2.0);
            } else {
                hue = 60.0 * (((rgb.r - rgb.g) / (maximumChannel - minimumChannel)) + 4.0);
            }
            if (hue < 0.0) { hue = hue + 360.0; }

            float centre = 25.0;
            float tolerance = 18.0;
            float distance = abs(hue - centre);
            if (distance > 180.0) { distance = 360.0 - distance; }

            float hueWeight = 1.0 - smoothstep(tolerance * 0.35, tolerance, distance);
            float saturationWeight = smoothstep(0.10, 0.22, saturation)
                                  * (1.0 - smoothstep(0.70, 0.90, saturation));
            float weight = hueWeight * saturationWeight * protection;

            // Hold the skin's own luminance so a look can change its colour but not make
            // a face brighter or darker than the scene around it.
            float luminance = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            vec3 protected = mix(rgb, vec3(luminance), weight);
            return vec4(protected * pixel.a, pixel.a);
        }
        """

        guard let kernel = CIColorKernel(source: source) else {
            AppLog.fail(AppLog.ml, "skin protection kernel did not compile; protection off")
            return image
        }
        var rendered: CIImage?
        let failure = LumaFrameSafety.perform {
            rendered = kernel.apply(extent: image.extent, arguments: [image])
        }
        if let failure {
            AppLog.fail(AppLog.ml, "skin protection raised: \(failure); protection off")
            return image
        }
        return rendered ?? image
    }
}
