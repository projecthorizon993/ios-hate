import Darwin
import Foundation

/// Resident footprint of this process, for the debug overlay.
///
/// `physicalMemory` is the device total, which is useless for spotting a leak, and
/// `ProcessInfo` exposes no used-memory value. `task_info` with `TASK_VM_INFO` is the
/// supported way to read it; `phys_footprint` is the number the jetsam limit is
/// measured against, so it is the number worth watching.
///
/// Returns `nil` rather than a guess when the query fails, so the overlay shows `—`
/// instead of a fabricated figure.
enum MemoryProbe {

    /// Megabytes, one decimal place, or `nil` when unavailable.
    static func usedMegabytes() -> Double? {
        guard let bytes = usedBytes() else { return nil }
        return Double(bytes) / (1024 * 1024)
    }

    static func usedBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
            / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}
