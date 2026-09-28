import Foundation

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

    /// - Parameters:
    ///   - modelURL: compiled benchmark model if one has been added to the target.
    ///     `nil` is a valid, non-error state: the Core ML section then reports the
    ///     capability surface without inventing a measurement.
    ///   - display: UIKit-derived facts, sampled on the main actor by the caller. The
    ///     probe body runs on a detached task and must not touch UIKit.
    ///   - cameraIsOwned: `true` when this report may start and stop its own
    ///     `AVCaptureSession`. `AVFoundationProbe` builds a second session to read the
    ///     output-level RAW and ProRAW capabilities, and two sessions competing for one
    ///     physical device in one process is exactly the kind of contention that stalls
    ///     the main runloop. The camera screen releases the device before opening the
    ///     report and sets this to `true`.
    static func collect(modelURL: URL?,
                        logLimit: Int?,
                        display: DeviceProbe.DisplayFacts,
                        cameraIsOwned: Bool) async -> Outcome {
        let result = await Task.detached(priority: .userInitiated) { () -> Outcome in
            AppLog.note(AppLog.diagnostics, "capability probe: start")

            var sections: [ReportSection] = []
            sections.append(contentsOf: contained("device") { DeviceProbe.sections(display: display) })
            sections.append(contentsOf: contained("avfoundation") { AVFoundationProbe.sections(cameraIsOwned: cameraIsOwned) })
            sections.append(contentsOf: contained("coreml") { [CoreMLProbe.coreMLSection(modelURL: modelURL)] })
            sections.append(contentsOf: contained("vision") { [CoreMLProbe.visionSection()] })
            sections.append(contentsOf: contained("render benchmark") { [DeviceProbe.renderBenchmark()] })

            let report = CapabilityReport(generatedAt: Date(),
                                          platform: display.systemName + " " + display.systemVersion
                                              + " (" + DeviceProbe.hardwareMachine() + ")",
                                          summary: buildSummary(from: sections),
                                          sections: sections)

            AppLog.note(AppLog.diagnostics,
                        "capability probe: done, \(sections.count) sections, \(sections.reduce(0) { $0 + $1.entries.count }) entries")

            return Outcome(report: report, logLines: AppLog.recentLines(limit: logLimit))
        }.value

        return result
    }

    /// Runs one probe inside the exception trap.
    ///
    /// A diagnostics screen must never be able to kill the app it is diagnosing, and an
    /// Objective-C exception from AVFoundation cannot be caught in Swift. So each probe
    /// is contained, and a failure becomes a visible line in the report naming the probe
    /// that failed — which is also what tells the next person where to look.
    private static func contained(_ name: String, _ body: () -> [ReportSection]) -> [ReportSection] {
        let produced = LumaFrameSafety.perform(body)
        if let failure = produced {
            AppLog.fail(AppLog.diagnostics, "probe \(name) raised \(failure)")
            var section = ReportSection("Probe failed")
            section.add(ReportEntry(name, failure, .fail))
            return [section]
        }
        return []
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
}
