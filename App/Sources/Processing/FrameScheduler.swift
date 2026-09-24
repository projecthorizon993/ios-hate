import CoreImage
import Foundation

final class FrameScheduler {
    private let queue = DispatchQueue(label: "com.lumaframe.camera.frames", qos: .userInitiated)
    private let lock = NSLock()
    private var isProcessing = false
    private var sampleCount = 0

    func submit(_ operation: @escaping () -> CGImage?, completion: @escaping (CGImage?) -> Void) {
        lock.lock()
        guard !isProcessing else {
            lock.unlock()
            return
        }
        isProcessing = true
        lock.unlock()

        queue.async {
            let image = operation()
            self.lock.lock()
            self.isProcessing = false
            self.lock.unlock()
            completion(image)
        }
    }
}
