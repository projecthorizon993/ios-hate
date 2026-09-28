import Foundation
import SwiftUI

/// State for the diagnostic screen. No camera, no AVFoundation, no ML — it only
/// forwards to `CapabilityCollector` and holds the resulting text.
@MainActor
final class ReportViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case running
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var report: CapabilityReport?
    @Published private(set) var logLines: [String] = []
    @Published private(set) var savedLocation: String?
    @Published var includeLog = true

    private let modelURL: URL?
    private let logLimit: Int?

    init(bundle: Bundle = .main, logLimit: Int? = nil) {
        self.modelURL = bundle.url(forResource: CoreMLProbe.modelResourceName,
                                   withExtension: CoreMLProbe.modelResourceExtension)
            ?? bundle.url(forResource: CoreMLProbe.modelResourceName, withExtension: "mlpackage")
        self.logLimit = logLimit
    }

    var canRun: Bool { state != .running }

    var isShareable: Bool { report != nil }

    /// The exact text that gets copied, shared or saved.
    var text: String {
        guard let report else { return "" }
        return ReportText.render(report, logLines: includeLog ? logLines : [])
    }

    var summary: String {
        report?.summary ?? "Not measured yet. Run the report."
    }

    var sections: [ReportSection] {
        report?.sections ?? []
    }

    func run() async {
        guard canRun else { return }
        state = .running
        savedLocation = nil
        // Sampled here, on the main actor, because the probe body runs detached and
        // `UIDevice`, `UIScreen` and `UIApplication` are all main-thread-affine.
        let display = DeviceProbe.displayFacts()
        // The report opens a second capture session to read output-level capabilities.
        // The camera screen tells us whether it has already released the device.
        let ownsCamera = CameraRelease.shared.isCameraReleased
        AppLog.note(AppLog.diagnostics,
                    "capability report: running, cameraIsOwned=\(ownsCamera)")
        let outcome = await CapabilityCollector.collect(modelURL: modelURL,
                                                        logLimit: logLimit,
                                                        display: display,
                                                        cameraIsOwned: ownsCamera)
        report = outcome.report
        logLines = outcome.logLines
        state = .ready
        AppLog.note(AppLog.diagnostics, "capability report ready: \(outcome.report.summary)")
    }

    func copyToPasteboard() {
        UIPasteboard.general.string = text
        AppLog.note(AppLog.ui, "capability report copied to pasteboard (\(text.count) chars)")
    }

    func save() {
        do {
            let url = try ReportExporter.write(text)
            savedLocation = url.lastPathComponent
            AppLog.note(AppLog.diagnostics, "capability report saved: \(url.path)")
        } catch {
            state = .failed("Could not save report: \(error.localizedDescription)")
            AppLog.fail(AppLog.diagnostics, "capability report save failed: \(error.localizedDescription)")
        }
    }
}
