import CoreMedia
import Foundation

/// Formatting shared by the camera UI, the capture metadata and the developer panel.
///
/// Extracted from the deleted capability report, which is the only thing that needed most
/// of it. ISO and shutter read the same in a control label, a metadata value and a log
/// line, and three spellings of "1/120" would be three things to keep in step.
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
