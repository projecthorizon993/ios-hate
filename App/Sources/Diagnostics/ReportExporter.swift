import Foundation

/// Writes the report into the app's Documents directory so it can be retrieved from
/// the Files app without any sharing UI.
enum ReportExporter {

    static let directoryName = "Reports"

    enum ExportError: LocalizedError {
        case documentsUnavailable

        var errorDescription: String? {
            switch self {
            case .documentsUnavailable:
                return "the Documents directory is not available on this device"
            }
        }
    }

    static func write(_ text: String, now: Date = Date()) throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else {
            throw ExportError.documentsUnavailable
        }
        let directory = documents.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let name = "lumaframe-report-" + ReportText.stamp(now)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "T", with: "-") + ".txt"
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
