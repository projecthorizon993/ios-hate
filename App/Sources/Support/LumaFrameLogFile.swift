import Foundation

/// Which build this binary is, read once from the bundle.
///
/// ## Why this exists
///
/// The log file accumulates every session and is read by attaching it to a message, so
/// "which run was this?" has to be answerable from the file alone. It was not: one log file
/// holds a week of sessions and nothing in it named the app version, let alone the commit.
/// Two exported copies were then both called `LumaFrame-1.txt`, because `CFBundleVersion` is
/// hardcoded to `1`, and which one was newer was decided by looking at the timestamps.
///
/// `LumaFrameBuild` is a custom Info.plist key holding the commit, because `CFBundleVersion`
/// cannot carry it — Apple requires that key to be a dotted number and a hash there makes an
/// install fail. It reads `local` for a build that did not go through CI, which is honest
/// rather than blank: "not stamped" should look different from a real hash.
enum AppVersion {

/// `beta v1.0.0 build 138-2ff7527` — channel, version, then the build.
    static var description: String {
        "\(releaseLabel) build \(build)"
    }

    /// `beta v1.0.0` — the version as a person says it, from `CFBundleShortVersionString`.
    ///
    /// The channel is a constant here rather than a build setting because it changes with a
    /// decision, not with a build, and a decision that needs a build to change it has already
    /// gone wrong once.
    static var releaseLabel: String {
        let short = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        return "\(channel) v\(short)"
    }

    /// The pre-release channel this build is on.
    static let channel = "beta"

    /// The commit and build number this binary was built from, or `local` / `unknown`.
    ///
    /// CI writes `<run number>-<short sha>`, so the number at the front increments by one on
    /// every single build and the hash still pins the exact commit. That is what makes "which
    /// version was this?" answerable from a log file alone instead of from memory.
    static var build: String {
        let trimmed = (Bundle.main.infoDictionary?["LumaFrameBuild"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !Self.isUnsubstituted(trimmed) else { return "unknown" }
        return trimmed
    }

    /// Whether a bundle value is a build setting nobody expanded.
    ///
    /// An unsubstituted value would otherwise be reported as a build name, which is the one
    /// thing this type exists to make impossible. A build setting is always a dollar sign
    /// followed by a bracketed name — Info.plist leaves it verbatim — so the prefix is the
    /// whole test, and spelling the marker out literally here would be the same defect.
    static func isUnsubstituted(_ value: String) -> Bool {
        value.hasPrefix("$")
    }

    /// `build` reduced to something safe for a file name: no dots, no slashes.
    static var fileNameSafeBuild: String {
        build.replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}

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

    /// A copy of the whole log as a shareable file, or `nil` if it could not be made.
    ///
    /// The point is to stop the Phase 1 loop depending on the user finding
    /// `Documents` through Files.app. Every device test so far has needed a log, and every
    /// one has cost a round trip because the file was somewhere a person has to go and look
    /// for it. One tap in the Developer panel should produce something sendable.
    ///
    /// Written to a temporary directory rather than into `Documents`, so it does not
    /// accumulate in the folder the user can see, and named with the build so two logs from
    /// different runs are not confused when both are attached to the same report.
    @discardableResult
    static func exportShareableCopy(build: String) -> URL? {
        guard let url = fileURL() else { return nil }
        // Read through the same serial queue the writer uses, so the copy cannot be taken
        // halfway through a line.
        let text = queue.sync { () -> String in
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        guard !text.isEmpty else { return nil }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaFrame-\(build).txt")
        do {
            try text.data(using: .utf8)?.write(to: destination, options: .atomic)
        } catch {
            // Sharing is a convenience; failing to prepare the file must not be fatal and
            // must not be silent either.
            AppLog.warn(AppLog.diagnostics, "log export failed: \(error.localizedDescription)")
            return nil
        }
        return destination
    }

    /// Marks the start of a run, so a log containing several sessions is readable.
    ///
    /// The banner names the build, because the whole point of the file is being read later
    /// than the run that wrote it: "the front camera was upside down" means something only
    /// once you know which build had the bug. Cheap, and the alternative is inferring both
    /// the run boundary and the version from timestamps.
    static func markRun(_ note: String) {
        append("")
        append("==== \(AppVersion.description) ====")
        append("---- run: \(note) ----")
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
                + "This file holds every session; each run prints its own version banner, so"
                + " read the banner nearest the event rather than this header.\n"
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
