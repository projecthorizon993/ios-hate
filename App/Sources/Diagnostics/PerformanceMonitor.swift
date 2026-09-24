import Combine
import Foundation

@MainActor
final class PerformanceMonitor: ObservableObject {
    @Published private(set) var framesPerSecond = 0.0
    @Published private(set) var frameTimeMilliseconds = 0.0
    @Published private(set) var processedFrameCount = 0
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private var timer: Timer?
    private var frameCount = 0
    private var lastSample = Date()

    var thermalLabel: String {
        switch thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    func start() {
        guard timer == nil else { return }
        lastSample = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func recordFrame() {
        frameCount += 1
        processedFrameCount += 1
    }

    private func sample() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSample)
        guard elapsed > 0 else { return }
        framesPerSecond = Double(frameCount) / elapsed
        frameTimeMilliseconds = framesPerSecond > 0 ? 1000 / framesPerSecond : 0
        thermalState = ProcessInfo.processInfo.thermalState
        frameCount = 0
        lastSample = now
    }
}
