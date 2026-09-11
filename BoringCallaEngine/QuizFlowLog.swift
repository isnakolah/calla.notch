import Foundation

/// A timeline of one Quiz session, written as it happens.
///
/// Every latency question so far has been answered by reading the SQLite archive
/// afterwards, which records what *finished* — a question with no answer row
/// leaves no trace of where its time went. The gap between a question appearing
/// on screen and the council being asked is exactly the part that record cannot
/// see, and it is the part that feels slow.
///
/// So: one NDJSON line per event, with the milliseconds since the previous event
/// and since the question was first seen. Bounded, and cheap enough to leave on.
actor QuizFlowLog {
    private let url: URL
    private let fileManager: FileManager
    private var handle: FileHandle?
    private var written = 0
    private var questionStart: Date?
    private var previous: Date?

    /// Rotated rather than grown: this is for reading the last few minutes.
    private static let maximumBytes = 2 * 1_024 * 1_024

    init(directory: URL, fileManager: FileManager = .default) {
        url = directory.appendingPathComponent("flow.log")
        self.fileManager = fileManager
    }

    /// Starts a question's clock, so later events read as offsets from it.
    func beginQuestion(_ questionID: String, generation: Int) {
        questionStart = Date()
        previous = nil
        record("question.detected", ["question": questionID, "generation": "\(generation)"])
    }

    func record(_ event: String, _ fields: [String: String] = [:]) {
        let now = Date()
        var line: [String: String] = [
            "at": Self.stamp.string(from: now),
            "event": event,
        ]
        if let questionStart {
            line["sinceQuestionMs"] = "\(Int(now.timeIntervalSince(questionStart) * 1_000))"
        }
        if let previous {
            line["stepMs"] = "\(Int(now.timeIntervalSince(previous) * 1_000))"
        }
        previous = now
        line.merge(fields) { _, new in new }
        write(line)
    }

    private func write(_ line: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        else { return }
        guard let handle = openHandle() else { return }
        try? handle.write(contentsOf: data + Data("\n".utf8))
        written += data.count + 1
        if written > Self.maximumBytes { rotate() }
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil,
                                   attributes: [.posixPermissions: 0o600])
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        opened.seekToEndOfFile()
        written = Int(opened.offsetInFile)
        handle = opened
        return opened
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        written = 0
        let previousRun = url.deletingLastPathComponent()
            .appendingPathComponent("flow.previous.log")
        try? fileManager.removeItem(at: previousRun)
        try? fileManager.moveItem(at: url, to: previousRun)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
