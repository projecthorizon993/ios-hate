import Foundation

/// One plain-text log file on the device that outlives the process.
///
/// The unified system log already receives everything `AppLog` writes, but it is only
/// reachable with a Mac attached, and the in-memory ring buffer dies with the process.
/// The capability report has crashed the app several times on device and left nothing to
/// read afterwards, which is the situation this exists for: a jetsam kill writes no crash
/// log, so the only record of how far the run got is whatever reached disk first.
///
/// The file sits at the top of `Documents` rather than in a subfolder so it is the first
/// thing visible when the app is opened in Files.app, which it only is at all because
/// `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` are set.
///
/// Every line is written and `synchronize`d immediately. That is deliberate and is the
/// whole design: buffering would mean the last few lines — the interesting ones — are
/// exactly the ones lost. The volume is a few hundred short lines per report run, so the
/// cost of flushing every one is irrelevant next to losing the tail.
enum LumaFrameLogFile {

    static let fileName = "LumaFrame-log.txt"

    /// Enough for many runs without letting a long debugging session grow without bound.
    private static let maximumBytes = 512 * 1024

    private static let queue = DispatchQueue(label: "com.example.LumaFrame.logfile")

    private static var handle: FileHandle?

    /// For the UI, so the user is told where to look rather than having to guess.
    static var displayPath: String {
        fileURL()?.path ?? "Documents is not available on this device"
    }

    /// One line, timestamped, flushed before returning.
    static func append(_ line: String) {
        queue.sync { write(line) }
    }

    private static func write(_ line: String) {
        guard let url = fileURL() else { return }
        let stamp = timestamp()
        var text = stamp + "  " + line + "\n"
        if text.count > 4_000 { text = String(text.prefix(4_000)) + " …[truncated]\n" }
        guard let data = text.data(using: .utf8) else { return }

        if handle == nil {
            trimIfNeeded(url: url)
            handle = try? FileHandle(forWritingTo: url)
        }
        guard let handle else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            // A log file must never be the reason the app dies. Drop the handle so the
            // next line tries to reopen rather than writing into a dead descriptor.
            self.handle = nil
        }
    }

    /// Keeps the most recent `maximumBytes`. Called before opening, not after every
    /// write, so it costs nothing on the hot path.
    private static func trimIfNeeded(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              size > maximumBytes,
              let data = try? Data(contentsOf: url),
              data.count > maximumBytes
        else { return }
        let start = data.index(data.startIndex, offsetBy: data.count - maximumBytes)
        // Resume from a whole line so the first entry is not a fragment.
        let tail = Data(data[start...])
        let slice = tail.drop(while: { $0 != 0x0A })
        try? Data(slice).write(to: url, options: .atomic)
    }

    private static func fileURL() -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else {
            return nil
        }
        let url = documents.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = "LumaFrame log. One line per event, flushed as it is written, so the"
                + " tail survives a crash. Timestamps are UTC ISO 8601.\n"
            FileManager.default.createFile(atPath: url.path, contents: header.data(using: .utf8))
        }
        return url
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
