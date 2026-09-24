import Combine
import Foundation

@MainActor
final class PerformanceMonitor: ObservableObject {
    @Published private(set) var framesPerSecond = 0.0
    @Published private(set) var frameTimeMilliseconds = 0.0
    @Published private(set) var processedFrameCount = 0
    @Published private(set) var processingMilliseconds = 0.0
    @Published private(set) var averageProcessingMilliseconds = 0.0
    @Published private(set) var queueWaitMilliseconds = 0.0
    @Published private(set) var averageQueueWaitMilliseconds = 0.0
    @Published private(set) var droppedFrameCount = 0
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private var timer: Timer?
    private var frameCount = 0
    private var lastSample = Date()
    private var processingTotal = 0.0
    private var processingSamples = 0
    private var queueWaitTotal = 0.0
    private var queueWaitSamples = 0

    var thermalLabel: String {
        switch thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    var recommendedPreviewDimension: CGFloat {
        if thermalState == .serious || thermalState == .critical { return 720 }
        if averageProcessingMilliseconds > 50 { return 720 }
        if averageProcessingMilliseconds > 30 { return 960 }
        return 1280
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

    func recordFrameTiming(_ timing: FrameTiming) {
        if timing.dropped {
            droppedFrameCount += 1
            return
        }
        processingMilliseconds = timing.processingMilliseconds
        processingTotal += timing.processingMilliseconds
        processingSamples += 1
        averageProcessingMilliseconds = processingTotal / Double(processingSamples)
    }

    func recordQueueWait(_ milliseconds: Double) {
        queueWaitMilliseconds = milliseconds
        queueWaitTotal += milliseconds
        queueWaitSamples += 1
        averageQueueWaitMilliseconds = queueWaitTotal / Double(queueWaitSamples)
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
