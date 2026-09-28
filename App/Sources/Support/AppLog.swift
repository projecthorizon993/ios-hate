import Foundation
import os

/// Single logging entry point for the app.
///
/// Every call writes to the unified system log (so it shows up in the device console
/// and in a sysdiagnose) *and* to a bounded in-memory ring buffer. The buffer exists
/// because the user debugs from logs on a device with no debugger attached: the
/// Capability Report can dump recent lines into a shareable text file.
///
/// Never log image contents, file names, or user identifiers through this type.
enum AppLog {

    static let diagnostics = Logger(subsystem: "com.example.LumaFrame", category: "diagnostics")
    static let camera = Logger(subsystem: "com.example.LumaFrame", category: "camera")
    static let processing = Logger(subsystem: "com.example.LumaFrame", category: "processing")
    static let ml = Logger(subsystem: "com.example.LumaFrame", category: "ml")
    static let ui = Logger(subsystem: "com.example.LumaFrame", category: "ui")

    /// How many recent lines the ring buffer keeps.
    static let bufferCapacity = 600

    private static let buffer = RingBuffer(capacity: bufferCapacity)

    // MARK: - Categories

    static func note(_ logger: Logger, _ message: String) {
        logger.info("\(message, privacy: .public)")
        buffer.append(message)
    }

    static func warn(_ logger: Logger, _ message: String) {
        logger.warning("\(message, privacy: .public)")
        buffer.append("! " + message)
    }

    static func fail(_ logger: Logger, _ message: String) {
        logger.error("\(message, privacy: .public)")
        buffer.append("x " + message)
    }

    /// ML lines are the most useful to grep for, and the brief requires a log line on
    /// every model load and every 30th inference.
    static func inference(_ logger: Logger, model: String, backend: String, index: Int, milliseconds: Double) {
        let line = "ml #\(index) \(model) backend=\(backend) "
            + String(format: "%.2f", milliseconds) + "ms"
        if index % 30 == 0 || index == 1 {
            buffer.append(line)
        }
        logger.debug("\(line, privacy: .public)")
    }

    // MARK: - Ring buffer

    /// Oldest-first snapshot of recent log lines.
    static func recentLines(limit: Int? = nil) -> [String] {
        let all = buffer.snapshot()
        guard let limit, limit < all.count else { return all }
        return Array(all.suffix(limit))
    }

    static func clearBuffer() {
        buffer.removeAll()
    }
}

// MARK: - Ring buffer

/// Minimal fixed-capacity FIFO. Not thread-safe by itself; `AppLog.buffer` is only
/// ever touched through the lock inside.
private final class RingBuffer {
    private let capacity: Int
    private var storage: [String] = []
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(line)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll(keepingCapacity: true)
    }
}
