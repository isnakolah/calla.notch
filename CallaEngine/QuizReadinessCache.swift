import Foundation

/// What Quiz already knows about this machine, kept across engine restarts.
///
/// Both facts it holds are expensive to establish and slow to change. The model
/// catalogue is an `agy models` process, and every `agy` process pays several
/// seconds of Google round-trips before it answers anything. The authentication
/// verdict is worse: a real model round-trip, because a credential file existing
/// only proves a sign-in happened once.
///
/// Held in memory only, both were re-established on every `start()` — and the
/// engine restarts on every deploy, so "every start" is not rare. Neither answer
/// is worth making a reader wait for twice.
struct QuizReadiness: Codable, Sendable, Equatable {
    var binaryPath: String?
    var binaryVersion: String?
    var models: [String] = []
    var modelsCheckedAt: Date?
    var authenticated = false
    var authCheckedAt: Date?

    /// A day. The catalogue changes when AGY ships models, not while a reader
    /// is answering questions.
    static let modelsLifetime: TimeInterval = 24 * 60 * 60
    /// Half an hour. Shorter deliberately: this is the one that proves the
    /// refresh token still reaches AGY, and a revoked credential should not stay
    /// believed for a day.
    static let authLifetime: TimeInterval = 30 * 60

    func modelsAreFresh(now: Date = Date()) -> Bool {
        guard !models.isEmpty, let checked = modelsCheckedAt else { return false }
        return now.timeIntervalSince(checked) < Self.modelsLifetime
    }

    func authIsFresh(now: Date = Date()) -> Bool {
        guard authenticated, let checked = authCheckedAt else { return false }
        return now.timeIntervalSince(checked) < Self.authLifetime
    }

    /// A catalogue read against a different binary is not this binary's.
    func matches(binary: String) -> Bool {
        binaryPath == binary
    }
}

/// Reads and writes `readiness.json` beside the Quiz store.
///
/// Deliberately plain and failure-tolerant: an unreadable or corrupt file means
/// "nothing is known", which is exactly the state the engine started in before
/// this existed.
/// Not `Sendable`: it holds a `FileManager`, and it is only ever touched from
/// inside `QuizEngineController`'s isolation.
struct QuizReadinessCache {
    private let url: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        url = directory.appendingPathComponent("readiness.json")
        self.fileManager = fileManager
    }

    func load() -> QuizReadiness {
        guard let data = fileManager.contents(atPath: url.path),
              let record = try? JSONDecoder.readiness.decode(QuizReadiness.self, from: data)
        else { return QuizReadiness() }
        return record
    }

    func save(_ record: QuizReadiness) {
        guard let data = try? JSONEncoder.readiness.encode(record) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private extension JSONDecoder {
    static let readiness: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let readiness: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// Which of a slot's two directories the next child gets.
///
/// A slot's replacement child is spawned while the current one is still
/// answering, so the two must not share a workspace: the finishing child's
/// cleanup would delete state the live one is using. Counting per slot and
/// alternating is the whole mechanism.
final class QuizWorkerLanes: @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [Int: Int] = [:]

    func next(slot: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let turn = turns[slot, default: 0]
        turns[slot] = turn + 1
        return turn
    }
}
