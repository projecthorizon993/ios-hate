import Foundation

/// Severity of a single report line. The marker is what makes the report greppable
/// on a device with no debugger attached.
enum ReportLevel: String, Equatable, Sendable {
    case info
    case good
    case note
    case warn
    case fail

    /// Empty for `.info` so ordinary lines are not visually noisy.
    var marker: String {
        switch self {
        case .info: return ""
        case .good: return "+"
        case .note: return "#"
        case .warn: return "!"
        case .fail: return "x"
        }
    }
}

/// One measurement. `label` is stable so it can be grepped across devices and across
/// app versions.
struct ReportEntry: Identifiable, Equatable, Sendable {
    var id = UUID()
    var label: String
    var value: String
    var level: ReportLevel = .info

    init(_ label: String, _ value: String, _ level: ReportLevel = .info) {
        self.label = label
        self.value = value
        self.level = level
    }

    init(_ label: String, _ value: Bool, _ level: ReportLevel? = nil) {
        self.label = label
        self.value = value ? "yes" : "no"
        self.level = level ?? (value ? .good : .info)
    }

    /// Counts are measurements like any other. A separate initialiser rather than
    /// stringifying at the call site, so `ReportFormat` stays out of the probes and a
    /// count is never printed through a formatter that rounds it.
    init(_ label: String, _ value: Int, _ level: ReportLevel = .info) {
        self.label = label
        self.value = String(value)
        self.level = level
    }
}

struct ReportSection: Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var entries: [ReportEntry]

    init(_ title: String, _ entries: [ReportEntry] = []) {
        self.title = title
        self.entries = entries
    }

    mutating func add(_ entry: ReportEntry) {
        entries.append(entry)
    }

    mutating func add(entries newEntries: [ReportEntry]) {
        entries.append(contentsOf: newEntries)
    }
}

/// Printed instead of a value when a probe cannot measure something honestly. A report
/// line that says it does not know is useful; one that says zero because a constant did
/// not resolve is not.
let notMeasured = "not measured on iOS"

/// `availableRawPhotoPixelFormatTypes` and Vision's `supportedOutputPixelFormats` are
/// both declared as `NSArray<NSNumber *>`, so their elements arrive boxed rather than as
/// a plain `OSType`. This is the single unwrapping helper for both.
extension NSNumber {
    var ostValue: OSType { OSType(truncatingIfNeeded: uint32Value) }
}

struct CapabilityReport: Equatable, Sendable {
    var generatedAt: Date
    var platform: String
    var summary: String
    var sections: [ReportSection]
}

/// Text rendering for a report. Kept free of platform types so the unit tests can
/// exercise it without a device.
enum ReportText {

    static let entryIndent = "  "

    static func entryLine(_ entry: ReportEntry) -> String {
        let prefix = entry.level.marker.isEmpty ? "" : entry.level.marker + " "
        return entryIndent + prefix + entry.label + ": " + entry.value
    }

    static func sectionHeader(_ title: String) -> String {
        "\n== " + title + " =="
    }

    /// Full plain-text report, including the trailing log dump when provided.
    static func render(_ report: CapabilityReport, logLines: [String] = []) -> String {
        var out = ""
        out += "LumaFrame Capability Report\n"
        out += "platform: " + report.platform + "\n"
        out += "generated: " + stamp(report.generatedAt) + "\n"
        if !report.summary.isEmpty {
            out += "summary: " + report.summary + "\n"
        }

        for section in report.sections {
            out += sectionHeader(section.title) + "\n"
            for entry in section.entries {
                out += entryLine(entry) + "\n"
            }
        }

        if !logLines.isEmpty {
            out += sectionHeader("Recent log (\(logLines.count) lines)") + "\n"
            for line in logLines {
                out += entryIndent + line + "\n"
            }
        }

        return out
    }

    /// Locale-independent, so reports from three devices diff cleanly.
    ///
    /// `ISO8601DateFormatter` rather than `Date.ISO8601FormatStyle`: the format style
    /// spells this option `time(includingFractionalSeconds:)`, and mixing it with
    /// `time(separator:)` is a different API than it looks.
    static let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }
}

// MARK: - Formatting helpers used by the probes

enum ReportFormat {

    /// `1/120` rather than `0.00833s`, because a camera UI shows shutter speed as a
    /// fraction and the fraction is what gets compared against a stock camera.
    static func shutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "n/a" }
        if seconds >= 1.0 {
            return String(format: "%.1fs", seconds)
        }
        let denominator = (1.0 / seconds).rounded()
        guard denominator >= 1, denominator < 10000 else {
            return String(format: "%.5fs", seconds)
        }
        return "1/\(Int(denominator))"
    }

    /// ISO and EV are floats; drop trailing zeroes so the report stays compact.
    static func number(_ value: Double, decimals: Int = 2) -> String {
        if value == value.rounded(), abs(value) < 1e9 {
            return String(Int(value))
        }
        return String(format: "%.\(decimals)f", value)
    }

    static func range(_ lower: Double, _ upper: Double) -> String {
        "\(number(lower)) ... \(number(upper))"
    }

    static func list(_ values: [String], empty: String = "none") -> String {
        values.isEmpty ? empty : values.joined(separator: ", ")
    }

    /// FourCC code from a `CMFormatDescription`, or `?` when it cannot be read.
    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let scalars = bytes.map { byte -> String in
            let scalar = UnicodeScalar(byte)
            if scalar.value >= 0x20 && scalar.value < 0x7F {
                return String(Character(scalar))
            }
            return String(format: "\\x%02X", byte)
        }
        return scalars.joined()
    }
}
