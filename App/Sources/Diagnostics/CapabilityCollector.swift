import Foundation
import UIKit

/// Runs every probe off the main thread and assembles a `CapabilityReport`.
///
/// This type deliberately depends on nothing but the probes. The report must still
/// be generatable when the camera, processing and ML layers are broken — that is
/// exactly when it is most useful.
enum CapabilityCollector {

    struct Outcome: Sendable {
        var report: CapabilityReport
        var logLines: [String]
    }

    /// - Parameter modelURL: compiled benchmark model if one has been added to the
    ///   target. `nil` is a valid, non-error state: the Core ML section then reports
    ///   the capability surface without inventing a measurement.
    static func collect(modelURL: URL?, logLimit: Int?) async -> Outcome {
        let result = await Task.detached(priority: .userInitiated) { () -> Outcome in
            AppLog.note(AppLog.diagnostics, "capability probe: start")

            var sections: [ReportSection] = []
            sections.append(contentsOf: DeviceProbe.sections())
            sections.append(contentsOf: AVFoundationProbe.sections())
            sections.append(CoreMLProbe.coreMLSection(modelURL: modelURL))
            sections.append(CoreMLProbe.visionSection())
            sections.append(DeviceProbe.renderBenchmark())

            let platform = platformString()
            let report = CapabilityReport(generatedAt: Date(),
                                          platform: platform,
                                          summary: buildSummary(from: sections),
                                          sections: sections)

            AppLog.note(AppLog.diagnostics,
                        "capability probe: done, \(sections.count) sections, \(sections.reduce(0) { $0 + $1.entries.count }) entries")

            return Outcome(report: report, logLines: AppLog.recentLines(limit: logLimit))
        }.value

        return result
    }

    // MARK: - Summary

    /// A one-line answer to "what can this device actually do", so the report is
    /// useful at a glance when three of them are pasted into a chat.
    private static func buildSummary(from sections: [ReportSection]) -> String {
        let back = consensus("back camera count", in: sections) ?? "unknown"
        let raw = consensus("RAW available", in: sections) ?? "unknown"
        let proRAW = consensus("Apple ProRAW supported", in: sections) ?? "unknown"
        let gamut = consensus("display gamut", in: sections) ?? "unknown"
        return "back cameras: \(back) | RAW: \(raw) | ProRAW: \(proRAW) | gamut: \(gamut)"
    }

    /// Returns the single value for `label`, or `"mixed"` when devices disagree. A
    /// per-device difference is more interesting than hiding it behind a `yes`.
    private static func consensus(_ label: String, in sections: [ReportSection]) -> String? {
        let values = sections
            .flatMap(\.entries)
            .filter { $0.label == label }
            .map(\.value)
        guard !values.isEmpty else { return nil }
        let unique = Set(values)
        return unique.count == 1 ? values[0] : "mixed"
    }

    private static func platformString() -> String {
        let device = UIDevice.current
        return "\(device.systemName) \(device.systemVersion) (\(DeviceProbe.hardwareMachine()))"
    }
}
