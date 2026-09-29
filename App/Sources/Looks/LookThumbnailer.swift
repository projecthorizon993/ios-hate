import CoreImage
import Foundation
import UIKit

/// Renders a small preview of each look, so the carousel shows the looks rather than
/// naming them.
///
/// The design spec asks for "live thumbnails" in the style carousel. The honest
/// interpretation is **live enough, not per frame**: each thumbnail is the current frame
/// pushed through one look at full strength, recomputed when the recipe or the source
/// frame changes, on a background queue.
///
/// Not per frame, and deliberately. There are five built-ins plus whatever the user has
/// imported, each needing a full `CIColorCube` pass over a small image. Doing that 30 times
/// a second to animate a thumbnail strip would cost more than the preview itself, and the
/// thumbnails would still look identical between updates — the user is choosing a look, not
/// tracking a moving subject.
enum LookThumbnailer {

    /// Square thumbnails; the carousel is a fixed-size strip so a non-square crop would
    /// change every tile's aspect as looks are added.
    static let size: CGFloat = 96

    /// Below this, recomputing is not worth the queue hop.
    static let minimumInterval: Double = 0.5

    private static let queue = DispatchQueue(label: "com.example.LumaFrame.thumbnails",
                                             qos: .utility)

    private static var lastRun: Double = 0
    private static let stateLock = NSLock()

    /// Renders `looks` against `source` and calls `onResult` on the main queue.
    ///
    /// Rate-limited rather than debounced: a debounce would postpone the update until the
    /// user stopped dragging, which is exactly when they are looking at the strip least.
    static func render(looks: [Look],
                       source: CIImage,
                       recipe: ProcessingSettings,
                       library: LookLibrary = .shared,
                       now: Double = Date().timeIntervalSince1970,
                       completion: @escaping ([Look: UIImage]) -> Void) {
        stateLock.lock()
        if now - lastRun < minimumInterval {
            stateLock.unlock()
            return
        }
        lastRun = now
        stateLock.unlock()

        let target = source.transformed(by: CGAffineTransform(
            scaleX: size / max(1, source.extent.width),
            y: size / max(1, source.extent.height)))
        let cropped = target.cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let settings = looks.map { look -> (Look, ProcessingSettings) in
            var one = recipe
            one.look = look
            // Full strength: a thumbnail at the user's current intensity would show every
            // tile identically dark and tell them nothing about which is which.
            one.lookIntensity = 1
            one.subjectMask = nil
            one.grain = 0
            one.sharpen = 0
            return (look, one)
        }

        queue.async {
            let pipeline = ProcessingPipeline(library: library)
            let context = CIContext(options: [.cacheIntermediates: false])
            var images: [Look: UIImage] = [:]
            for (look, one) in settings {
                let rendered = pipeline.renderOrOriginal(cropped,
                                                        settings: one,
                                                        inputSpace: .sRGB,
                                                        outputSpace: .sRGB)
                guard let cgImage = context.createCGImage(rendered, from: rendered.extent) else {
                    continue
                }
                images[look] = UIImage(cgImage: cgImage)
            }
            DispatchQueue.main.async { completion(images) }
        }
    }

    /// A neutral placeholder tile, so a look whose table is missing still occupies a slot
    /// instead of collapsing the strip and moving every other tile under the finger.
    static func placeholder() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            Theme.ColorToken.surfaceRaised.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }
}
