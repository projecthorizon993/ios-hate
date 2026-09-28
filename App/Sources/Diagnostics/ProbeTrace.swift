import Foundation

/// Crash-survivable breadcrumbs for the capability report.
///
/// This exists because the report has crashed the app on device several times and left
/// no evidence. The in-memory ring buffer dies with the process, the report text is only
/// assembled at the very end, and a jetsam kill produces no crash log at all — so in the
/// one case that most needs explaining there was nothing to read afterwards.
///
/// Each probe announces itself before it runs. The line is written and flushed
/// immediately, so whatever is in the file after the app dies is exactly the point of
/// death: a probe with `ENTER` and no `LEAVE` is where it happened, and a probe with no
/// `ENTER` was never reached at all.
///
/// These go into the same file as the rest of the app log rather than a second one, so
/// there is a single thing to pull off the device.
enum ProbeTrace {

    /// Records that a probe is about to start.
    static func entering(_ name: String) {
        LumaFrameLogFile.append("PROBE ENTER " + name)
    }

    /// Records that a probe finished, and how long it took.
    static func leaving(_ name: String, milliseconds: Double) {
        LumaFrameLogFile.append("PROBE LEAVE " + name + " "
                                + String(format: "%.0f", milliseconds) + "ms")
    }

    /// Records a probe that raised, so the reason is on disk even if the report never
    /// gets as far as rendering it.
    static func failed(_ name: String, _ reason: String) {
        LumaFrameLogFile.append("PROBE FAIL  " + name + ": " + reason)
    }

    /// Records the footprint, which is the only way to tell a jetsam kill from anything
    /// else after the fact.
    static func memory(_ megabytes: Double) {
        LumaFrameLogFile.append("PROBE MEM   " + String(format: "%.0f", megabytes) + " MB")
    }

    static func begin() {
        LumaFrameLogFile.append("PROBE ==== capability report run starting")
    }

    static func finish() {
        LumaFrameLogFile.append("PROBE ==== capability report run finished")
    }
}
