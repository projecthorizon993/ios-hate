import Foundation

/// A section saying what a run chose **not** to measure, and why.
///
/// The alternative — leaving a probe out and saying nothing — produces a report that reads
/// as complete while quietly missing a section, and a missing section is indistinguishable
/// from a probe that failed. So a skipped probe still gets a section, marked as skipped,
/// and says which switch would turn it on.
///
/// The same reason is behind the existence of `ReportEntry`'s `.note` level: a capability
/// report is read as a record, and a record that cannot distinguish "not attempted" from
/// "did not work" is not a record.
enum ReportSkipped {

    static func section(_ title: String, _ reason: String) -> ReportSection {
        var section = ReportSection(title)
        section.add(ReportEntry("status", "not measured", .warn))
        section.add(ReportEntry("reason", reason, .note))
        return section
    }
}
