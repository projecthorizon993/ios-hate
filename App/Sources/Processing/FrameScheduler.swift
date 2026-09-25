import CoreImage
import Foundation
import os.log

struct FrameTiming {
    let processingMilliseconds: Double
    let dropped: Bool
}

final class FrameScheduler {
    private let queue = DispatchQueue(label: "com.lumaframe.camera.frames", qos: .userInitiated)
    private let signpostLog = OSLog(subsystem: "com.lumaframe", category: .pointsOfInterest)
    private let lock = NSLock()
    private var isProcessing = false
    var onTiming: ((FrameTiming) -> Void)?

    func submit(_ operation: @escaping () -> CGImage?, completion: @escaping (CGImage?) -> Void) {
        lock.lock()
        guard !isProcessing else {
            lock.unlock()
            os_signpost(.event, log: signpostLog, name: "Preview frame dropped")
            onTiming?(FrameTiming(processingMilliseconds: 0, dropped: true))
            return
        }
        isProcessing = true
        lock.unlock()

        queue.async {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            os_signpost(.begin, log: self.signpostLog, name: "Preview frame processing")
            let image = operation()
            os_signpost(.end, log: self.signpostLog, name: "Preview frame processing")
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            self.onTiming?(FrameTiming(processingMilliseconds: elapsed, dropped: false))
            self.lock.lock()
            self.isProcessing = false
            self.lock.unlock()
            completion(image)
        }
    }
}
