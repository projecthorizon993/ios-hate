import CoreImage
import Foundation
import os.log

final class FrameScheduler {
    private let queue = DispatchQueue(label: "com.lumaframe.camera.frames", qos: .userInitiated)
    private let signpostLog = OSLog(subsystem: "com.lumaframe", category: .pointsOfInterest)
    private let lock = NSLock()
    private var isProcessing = false
    private var sampleCount = 0

    func submit(_ operation: @escaping () -> CGImage?, completion: @escaping (CGImage?) -> Void) {
        lock.lock()
        guard !isProcessing else {
            lock.unlock()
            os_signpost(.event, log: signpostLog, name: "Preview frame dropped")
            return
        }
        isProcessing = true
        lock.unlock()

        queue.async {
            os_signpost(.begin, log: self.signpostLog, name: "Preview frame processing")
            let image = operation()
            os_signpost(.end, log: self.signpostLog, name: "Preview frame processing")
            self.lock.lock()
            self.isProcessing = false
            self.lock.unlock()
            completion(image)
        }
    }
}
