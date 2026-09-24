import Combine
import Foundation

@MainActor
final class PerformanceMonitor: ObservableObject {
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var memoryUsage = 0
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.thermalState = ProcessInfo.processInfo.thermalState
            self.memoryUsage = Int(ProcessInfo.processInfo.physicalMemory) > 0 ? Int(Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576) : 0
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
