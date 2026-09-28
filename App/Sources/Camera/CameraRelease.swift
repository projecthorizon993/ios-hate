import Foundation

/// One-bit handover between the camera screen and the capability report.
///
/// The report needs the physical camera to itself: it opens a second
/// `AVCaptureSession` to read the output-level RAW and ProRAW capabilities, and two
/// sessions contending for one device inside one process is what stalled the main
/// runloop on the first on-device attempt. The camera screen therefore tears its
/// session down before presenting the report and rebuilds it afterwards, and it says
/// so here so the probe can trust the answer.
///
/// Deliberately not a stored property on the view model: the report screen has no
/// reference to the camera screen, and a global that only carries a boolean is far
/// smaller than coupling the two to each other.
@MainActor
final class CameraRelease {

    static let shared = CameraRelease()

    /// `true` once the camera screen has released the device, `false` while it holds a
    /// running session. The probe skips its live session when this is `false`, and says
    /// so in the report rather than opening a second session anyway.
    private(set) var isCameraReleased = false

    private init() {}

    /// The session was fully torn down: inputs and outputs removed, not just stopped.
    func markReleased() {
        isCameraReleased = true
        AppLog.note(AppLog.camera, "camera released for the capability report")
    }

    /// The session is back. The camera is no longer available to the report.
    func markRetaken() {
        isCameraReleased = false
        AppLog.note(AppLog.camera, "camera re-acquired after the capability report")
    }
}
