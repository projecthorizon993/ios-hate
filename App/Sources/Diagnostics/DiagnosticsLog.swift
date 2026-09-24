import Combine
import Foundation
import OSLog

struct DiagnosticEvent: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let level: String
    let message: String
}

@MainActor
final class DiagnosticsLog: ObservableObject {
    @Published private(set) var events: [DiagnosticEvent] = []
    private let storageKey = "com.lumaframe.diagnostics"
    private let logger = Logger(subsystem: "com.lumaframe", category: "diagnostics")

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([DiagnosticEvent].self, from: data) {
            events = stored
        }
    }

    func record(_ message: String, level: String = "error") {
        let event = DiagnosticEvent(id: UUID(), date: Date(), level: level, message: message)
        events.insert(event, at: 0)
        if events.count > 30 {
            events.removeLast(events.count - 30)
        }
        if level == "error" {
            logger.error("\(message, privacy: .public)")
        } else {
            logger.info("\(message, privacy: .public)")
        }
        persist()
    }

    func exportURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LumaFrame-Diagnostics-\(UUID().uuidString).log")
        let content = events.reversed().map { event in
            "[\(ISO8601DateFormatter().string(from: event.date))] [\(event.level.uppercased())] \(event.message)"
        }.joined(separator: "\n")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    func clear() {
        events.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
