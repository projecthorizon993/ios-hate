import Foundation

/// A crash-survivable breadcrumb trail for the capability report.
///
/// This exists because the report has crashed the app on device several times and left
/// no evidence. The in-memory ring buffer dies with the process, the report text itself
/// is only assembled at the very end, and a jetsam kill produces no crash log at all —
/// so in the one case that most needs explaining there is nothing to read afterwards.
///
/// So each probe announces itself here, on disk, before it runs. The file is appended to
/// and flushed immediately, so whatever is in it after the app dies is exactly the point
/// of death. It is written unbuffered and outside the report's own work, which is why it
/// survives when the thing it is describing does not.
///
/// The file lives in Documents next to the exported reports, so it can be pulled with the
/// same one-step Files.app gesture, and it is overwritten on every run so it always
/// describes the run that just failed rather than an accumulation of old ones.
enum ProbeTrace {

    static let fileName = "lumaframe-probe-trace.txt"

    private static let queue = DispatchQueue(label: "com.example.LumaFrame.probetrace")

    /// Overwrites any previous trace so it always belongs to the current run.
    static func begin(at date: Date = Date()) {
        let header = "LumaFrame capability probe trace"
            + " — started " + iso(date)
            + "\nA crash ends this file. The last line is what was running."
        write(header + "\n", append: false)
    }

    /// Records that a probe is about to start. Called *before* the work, so its presence
    /// means the probe was entered and its absence means it was never reached.
    static func entering(_ name: String) {
        write("ENTER " + stamp() + " " + name + "\n", append: true)
    }

    /// Records that a probe finished, and how long it took.
    static func leaving(_ name: String, milliseconds: Double) {
        let ms = String(format: "%.0f", milliseconds)
        write("LEAVE " + stamp() + " " + name + " " + ms + "ms\n", append: true)
    }

    /// Records a probe that raised. `contained` calls this so the reason is on disk even
    /// if the report never gets as far as rendering it.
    static func failed(_ name: String, _ reason: String) {
        write("FAIL  " + stamp() + " " + name + ": " + reason + "\n", append: true)
    }

    /// Records the peak memory seen during the run, which is the only way to tell a jetsam
    /// kill from anything else after the fact.
    static func memory(_ megabytes: Double) {
        write("MEM   " + stamp() + " " + String(format: "%.0f", megabytes) + " MB\n", append: true)
    }

    static func finish() {
        write("DONE  " + stamp() + "\n", append: true)
    }

    // MARK: - Private

    private static func stamp() -> String {
        iso(Date())
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Appends and flushes. Deliberately not buffered: the whole point is that the bytes
    /// are on disk before the next line of the report runs.
    private static func write(_ text: String, append: Bool) {
        queue.sync {
            guard let url = fileURL() else { return }
            guard let data = text.data(using: .utf8) else { return }
            if append, let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.synchronize()
                } catch {
                    // A diagnostics breadcrumb must never be the thing that crashes the
                    // app, and there is nowhere useful to report a failure to write.
                }
                return
            }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func fileURL() -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else {
            return nil
        }
        let directory = documents.appendingPathComponent(ReportExporter.directoryName,
                                                         isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }
}
