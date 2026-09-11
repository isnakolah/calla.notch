import CallaContracts
import IntelligenceCore
import CryptoKit
import Foundation

public struct QuizStoredCapture: Sendable, Equatable {
    public let id: String
    public let relativePath: String
    public let ciphertextDigest: String
    public let byteCount: Int
}

public struct QuizCaptureVault: @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case invalidJPEG, tooLarge, missing, corrupt, unsafePath
        public var errorDescription: String? {
            switch self {
            case .invalidJPEG: "Quiz capture is not a JPEG"
            case .tooLarge: "Quiz capture exceeds 3 MiB"
            case .missing: "Quiz capture is unavailable"
            case .corrupt: "Quiz capture cannot be decrypted"
            case .unsafePath: "Quiz capture path is invalid"
            }
        }
    }

    private let root: URL
    private let key: SymmetricKey
    private let fileManager: FileManager

    public init(root: URL, key: SymmetricKey, fileManager: FileManager = .default) throws {
        self.root = root.standardizedFileURL
        self.key = key
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.root, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
    }

    public func store(_ jpeg: Data, id: String = UUID().uuidString.lowercased()) throws -> QuizStoredCapture {
        guard jpeg.count <= QuizContract.maximumCaptureBytes else { throw Failure.tooLarge }
        guard jpeg.count >= 4, jpeg.starts(with: [0xff, 0xd8, 0xff]),
              jpeg.suffix(2) == Data([0xff, 0xd9]) else { throw Failure.invalidJPEG }
        let safe = id.replacingOccurrences(of: "-", with: "")
        guard safe.range(of: "^[A-Za-z0-9]{16,64}$", options: .regularExpression) != nil else {
            throw Failure.unsafePath
        }
        let relative = safe + ".aesgcm"
        let destination = root.appendingPathComponent(relative)
        let temporary = root.appendingPathComponent(".\(safe).\(UUID().uuidString).tmp")
        do {
            guard let combined = try AES.GCM.seal(jpeg, using: key).combined else { throw Failure.corrupt }
            try combined.write(to: temporary, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try fileManager.moveItem(at: temporary, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return QuizStoredCapture(id: id, relativePath: relative,
                                     ciphertextDigest: TutorCaptureVault.digest(combined),
                                     byteCount: combined.count)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    public func reveal(relativePath: String) throws -> Data {
        let path = try resolve(relativePath)
        guard fileManager.fileExists(atPath: path.path) else { throw Failure.missing }
        do {
            let combined = try Data(contentsOf: path, options: .mappedIfSafe)
            return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
        } catch { throw Failure.corrupt }
    }

    public func remove(relativePath: String) {
        guard let path = try? resolve(relativePath) else { return }
        try? fileManager.removeItem(at: path)
    }

    public func cleanupTemporaryFiles() {
        guard let entries = try? fileManager.contentsOfDirectory(at: root,
                                                                  includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".") && entry.pathExtension == "tmp" {
            try? fileManager.removeItem(at: entry)
        }
    }

    public func cleanupOrphans(keeping relativePaths: Set<String>) {
        guard let entries = try? fileManager.contentsOfDirectory(at: root,
                                                                  includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.pathExtension == "aesgcm"
            && !relativePaths.contains(entry.lastPathComponent) {
            try? fileManager.removeItem(at: entry)
        }
    }

    private func resolve(_ relative: String) throws -> URL {
        guard relative.range(of: "^[A-Za-z0-9]+\\.aesgcm$", options: .regularExpression) != nil else {
            throw Failure.unsafePath
        }
        let result = root.appendingPathComponent(relative).standardizedFileURL
        guard result.deletingLastPathComponent().path == root.path else { throw Failure.unsafePath }
        return result
    }
}

/// Separate Quiz database. Call/Tutor schema remains untouched.
public actor QuizStore {
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case unsupportedSchema(Int), missingSession, missingCapture
        public var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version): "Quiz store schema \(version) is unsupported"
            case .missingSession: "Quiz session does not exist"
            case .missingCapture: "Quiz capture does not exist"
            }
        }
    }

    private let database: SQLiteDatabase
    private let vault: QuizCaptureVault
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(path: URL, captureRoot: URL, key: SymmetricKey) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        database = try SQLiteDatabase(path: path.path)
        vault = try QuizCaptureVault(root: captureRoot, key: key)
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        try Self.migrate(database)
        try database.run("""
            UPDATE quiz_session
            SET state = 'failed', failure_code = COALESCE(failure_code, 'crash_recovery'),
                ended_at = COALESCE(ended_at, ?)
            WHERE ended_at IS NULL AND state NOT IN ('finished', 'failed')
            """, [.double(Date().timeIntervalSince1970)])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        vault.cleanupTemporaryFiles()
        let referenced = Set(try database.query("SELECT relative_path FROM quiz_capture") { $0.string(0) })
        vault.cleanupOrphans(keeping: referenced)
    }

    public func begin(_ configuration: QuizSessionConfiguration, at: Date = Date()) throws {
        try QuizContractValidation.validate(configuration)
        let config = try encoder.encode(configuration)
        try database.transaction {
            try database.run("""
                INSERT INTO quiz_session(id, started_at, state, event_label, target_app, target_window, configuration_json)
                VALUES(?, ?, 'starting', ?, ?, ?, ?)
                """, [.text(configuration.sessionID), .double(at.timeIntervalSince1970),
                       .text(configuration.eventLabel), .text(configuration.target.applicationName),
                       .text(configuration.target.windowTitle), .blob(config)])
            for item in configuration.context where !configuration.excludedContextIDs.contains(item.id) {
                try database.run("""
                    INSERT INTO quiz_context(session_id, context_id, revision, title, scope, kind, text)
                    VALUES(?, ?, ?, ?, ?, ?, ?)
                    """, [.text(configuration.sessionID), .text(item.id), .text(item.revision),
                           .text(item.title), .text(item.scope.rawValue), .text(item.kind), .text(item.text)])
            }
        }
    }

    public func update(sessionID: String, state: QuizSessionState,
                       failure: String? = nil, endedAt: Date? = nil) throws {
        guard try database.scalarInt("SELECT 1 FROM quiz_session WHERE id = ?", [.text(sessionID)]) == 1 else {
            throw Failure.missingSession
        }
        try database.run("UPDATE quiz_session SET state = ?, failure_code = ?, ended_at = ? WHERE id = ?",
                         [.text(state.rawValue), .text(failure.map { String($0.prefix(120)) }),
                          .date(endedAt), .text(sessionID)])
    }

    /// Atomic ciphertext write precedes metadata commit. Caller may stage
    /// plaintext for remote worker only after this returns successfully.
    public func persist(_ frame: QuizCaptureFrame) throws -> QuizStoredCapture {
        try QuizContractValidation.validate(frame)
        let stored = try vault.store(frame.jpeg, id: frame.id)
        do {
            try database.transaction {
                try database.run("""
                    INSERT INTO quiz_question(id, session_id, generation, kind, fingerprint, detected_at)
                    VALUES(?, ?, ?, 'unknown', ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """, [.text(frame.questionID), .text(frame.sessionID), .int(frame.questionGeneration),
                           .text(frame.fingerprint), .double(frame.capturedAt.timeIntervalSince1970)])
                try database.run("""
                    INSERT INTO quiz_capture(id, question_id, capture_generation, viewport_index,
                      relative_path, ciphertext_digest, width, height, byte_count, created_at)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.text(stored.id), .text(frame.questionID), .int(frame.captureGeneration),
                           .int(frame.viewportIndex), .text(stored.relativePath),
                           .text(stored.ciphertextDigest), .int(frame.width), .int(frame.height),
                           .int(stored.byteCount), .double(frame.capturedAt.timeIntervalSince1970)])
            }
            return stored
        } catch {
            vault.remove(relativePath: stored.relativePath)
            throw error
        }
    }

    public func record(vote: QuizVote, isArbiter: Bool = false) throws {
        guard vote.worker.provesIsolation else {
            throw QuizAgyAuditFailure.invalidWorkerIdentity
        }
        try database.transaction {
            try database.run("""
                INSERT INTO quiz_worker(id, question_id, slot, role, model_id, effort,
                  conversation_id, num_turns, created_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(vote.id), .text(vote.questionID), .int(vote.worker.slot),
                       .text(isArbiter ? "arbiter" : "voter"), .text(vote.worker.modelID),
                       .text(vote.worker.effort), .text(vote.worker.conversationID),
                       .int(vote.worker.numberOfTurns), .double(Date().timeIntervalSince1970)])
            try database.run("""
                INSERT INTO quiz_vote(id, question_id, worker_id, answer, confidence, is_arbiter, created_at)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                """, [.text(vote.id), .text(vote.questionID), .text(vote.id), .text(vote.answer),
                       .int(vote.confidence), .int(isArbiter ? 1 : 0), .double(Date().timeIntervalSince1970)])
            for source in vote.sources {
                guard let url = URL(string: source.url), ["http", "https"].contains(url.scheme?.lowercased()) else { continue }
                try database.run("""
                    INSERT INTO quiz_source(vote_id, url, title, query, accessed_at) VALUES(?, ?, ?, ?, ?)
                    """, [.text(vote.id), .text(source.url), .text(source.title), .text(source.query),
                           .double(source.accessedAt.timeIntervalSince1970)])
            }
        }
    }

    public func record(final answer: QuizFinalAnswer) throws {
        let payload = try encoder.encode(answer)
        try database.run("""
            INSERT INTO quiz_final_answer(id, question_id, answer_json, answer, confidence,
                                          verified, answered_at, revision, rationale)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(question_id, revision) DO UPDATE SET answer_json=excluded.answer_json,
              answer=excluded.answer, confidence=excluded.confidence, verified=excluded.verified,
              answered_at=excluded.answered_at, rationale=excluded.rationale
            """, [.text(answer.id), .text(answer.questionID), .blob(payload), .text(answer.answer),
                   .int(answer.confidence), .int(answer.verified ? 1 : 0),
                   .double(answer.answeredAt.timeIntervalSince1970),
                   .int(answer.revision), .text(answer.rationale)])
        // `quiz_question.kind` is inserted as 'unknown' at capture time, because
        // nothing has classified the question yet. This is the first moment the
        // real kind exists.
        try database.run("UPDATE quiz_question SET kind = ? WHERE id = ?",
                         [.text(answer.kind.rawValue), .text(answer.questionID)])
    }

    /// Records what the classifier decided, at the moment it decided it.
    ///
    /// `quiz_question.kind` was inserted as 'unknown' and only corrected when an
    /// answer was published — so a question that was superseded or rejected left
    /// no trace of what it had been taken for, which is exactly the case worth
    /// diagnosing.
    public func note(questionID: String, kind: QuizQuestionKind, summary: String?) throws {
        try database.run("UPDATE quiz_question SET kind = ?, summary = ? WHERE id = ?",
                         [.text(kind.rawValue), .text(summary), .text(questionID)])
    }

    /// Records the reader's verdict on one answer.
    public func grade(answerID: String, _ grade: QuizAnswerGrade) throws {
        try database.run("UPDATE quiz_final_answer SET grade = ? WHERE id = ?",
                         [.int(grade.rawValue), .text(answerID)])
    }

    public func grade(answerID: String) throws -> QuizAnswerGrade {
        let value = try database.scalarInt(
            "SELECT grade FROM quiz_final_answer WHERE id = ?", [.text(answerID)]) ?? 0
        return QuizAnswerGrade(rawValue: value) ?? .ungraded
    }

    /// Every graded answer, as the calibration builder wants them.
    ///
    /// Only verified answers count: an unverified one carries no model text and a
    /// zero confidence by contract, so it says nothing about whether a given
    /// confidence band deserves to be believed.
    public func calibrationSamples() throws -> [QuizCalibrationSample] {
        // Kind comes from the stored answer rather than `quiz_question.kind`: that
        // column is written at capture time, before the council has classified
        // anything, and was only ever the literal 'unknown'.
        try database.query("""
            SELECT a.answer_json, a.confidence, a.grade FROM quiz_final_answer a
            WHERE a.grade IN (1, 2) AND a.verified = 1
            """) { row -> QuizCalibrationSample? in
                guard let payload = row.blob(0),
                      let answer = try? decoder.decode(QuizFinalAnswer.self, from: payload)
                else { return nil }
                return QuizCalibrationSample(
                    kind: answer.kind,
                    displayedConfidence: row.int(1),
                    correct: row.int(2) == QuizAnswerGrade.correct.rawValue)
            }.compactMap { $0 }
    }

    public func reveal(captureID: String) throws -> Data {
        guard let relative = try database.scalarText(
            "SELECT relative_path FROM quiz_capture WHERE id = ?", [.text(captureID)]) else {
            throw Failure.missingCapture
        }
        return try vault.reveal(relativePath: relative)
    }

    public func history(limit: Int = 100) throws -> [QuizHistorySession] {
        let rows = try database.query("""
            SELECT id, started_at, ended_at, event_label, target_app, target_window
            FROM quiz_session ORDER BY started_at DESC LIMIT ?
            """, [.int(min(500, max(1, limit)))]) { row in
                (row.string(0), Date(timeIntervalSince1970: row.double(1)), row.date(2),
                 row.text(3), row.string(4), row.string(5))
            }
        return try rows.map { session in
            let answers = try database.query("""
                SELECT a.answer_json FROM quiz_final_answer a
                JOIN quiz_question q ON q.id = a.question_id
                WHERE q.session_id = ? ORDER BY a.answered_at, a.revision
                """, [.text(session.0)]) { $0.blob(0) }.compactMap { data in
                    data.flatMap { try? decoder.decode(QuizFinalAnswer.self, from: $0) }
                }
            let captureIDs = try database.query("""
                SELECT c.id FROM quiz_capture c
                JOIN quiz_question q ON q.id = c.question_id
                WHERE q.session_id = ? ORDER BY q.generation, c.viewport_index
                """, [.text(session.0)]) { $0.string(0) }
            return QuizHistorySession(id: session.0, startedAt: session.1, endedAt: session.2,
                                      eventLabel: session.3, targetApplication: session.4,
                                      targetWindow: session.5, answers: answers,
                                      captureIDs: captureIDs)
        }
    }

    public func delete(sessionID: String) throws {
        let paths = try database.query("""
            SELECT c.relative_path FROM quiz_capture c JOIN quiz_question q ON q.id = c.question_id
            WHERE q.session_id = ?
            """, [.text(sessionID)]) { $0.string(0) }
        try database.run("DELETE FROM quiz_session WHERE id = ?", [.text(sessionID)])
        paths.forEach { vault.remove(relativePath: $0) }
    }

    @discardableResult
    public func deleteAll() throws -> Int {
        let paths = try database.query("SELECT relative_path FROM quiz_capture") { $0.string(0) }
        try database.run("DELETE FROM quiz_session")
        paths.forEach { vault.remove(relativePath: $0) }
        return paths.count
    }

    public func schemaVersion() throws -> Int { try database.scalarInt("PRAGMA user_version") ?? 0 }

    private static func migrate(_ database: SQLiteDatabase) throws {
        let version = try database.scalarInt("PRAGMA user_version") ?? 0
        guard version <= 4 else { throw Failure.unsupportedSchema(version) }
        if version == 0 {
            try database.transaction {
                try database.execute(schemaV1)
                try database.execute(schemaV2)
                try database.execute(schemaV3)
                try database.execute(schemaV4)
                try database.execute("PRAGMA user_version = 4")
            }
            return
        }
        if version < 2 {
            try database.transaction {
                try database.execute(schemaV2)
                try database.execute("PRAGMA user_version = 2")
            }
        }
        if version < 3 {
            try database.transaction {
                try database.execute(schemaV3)
                try database.execute("PRAGMA user_version = 3")
            }
        }
        if version < 4 {
            try database.transaction {
                try database.execute(schemaV4)
                try database.execute("PRAGMA user_version = 4")
            }
        }
    }

    /// Room for more than one answer per question.
    ///
    /// `quiz_final_answer.question_id` was `UNIQUE`, so a refinement pass would
    /// have overwritten the answer it improved on and the pair could never be
    /// compared. SQLite cannot drop a constraint, so the table is rebuilt —
    /// existing rows come across as revision 0, which is what they are.
    /// A question remembers what it looked like.
    private static let schemaV4 = """
    ALTER TABLE quiz_question ADD COLUMN summary TEXT;
    """

    private static let schemaV3 = """
    CREATE TABLE quiz_final_answer_v3(
      id TEXT PRIMARY KEY, question_id TEXT NOT NULL REFERENCES quiz_question(id) ON DELETE CASCADE,
      answer_json BLOB NOT NULL, answer TEXT NOT NULL,
      confidence INTEGER NOT NULL CHECK(confidence BETWEEN 0 AND 100),
      verified INTEGER NOT NULL, answered_at REAL NOT NULL,
      grade INTEGER NOT NULL DEFAULT 0,
      revision INTEGER NOT NULL DEFAULT 0,
      rationale TEXT,
      UNIQUE(question_id, revision)
    );
    INSERT INTO quiz_final_answer_v3(id, question_id, answer_json, answer, confidence,
                                     verified, answered_at, grade, revision, rationale)
      SELECT id, question_id, answer_json, answer, confidence, verified, answered_at, grade, 0, NULL
      FROM quiz_final_answer;
    DROP TABLE quiz_final_answer;
    ALTER TABLE quiz_final_answer_v3 RENAME TO quiz_final_answer;
    CREATE INDEX quiz_final_answer_grade ON quiz_final_answer(grade);
    CREATE INDEX quiz_final_answer_question ON quiz_final_answer(question_id, revision);
    """

    /// Whether an answer turned out to be right.
    ///
    /// Confidence calibration needs measured accuracy, and until this column
    /// existed nothing in the product recorded whether an answer was correct — so
    /// `QuizConfidenceCalibration` could only ever be constructed empty, and the
    /// percentage shown in the notch was the model's own self-report passed
    /// straight through.
    private static let schemaV2 = """
    ALTER TABLE quiz_final_answer ADD COLUMN grade INTEGER NOT NULL DEFAULT 0;
    CREATE INDEX quiz_final_answer_grade ON quiz_final_answer(grade);
    """

    private static let schemaV1 = """
    CREATE TABLE quiz_session(
      id TEXT PRIMARY KEY, started_at REAL NOT NULL, ended_at REAL, state TEXT NOT NULL,
      event_label TEXT, target_app TEXT NOT NULL, target_window TEXT NOT NULL,
      configuration_json BLOB NOT NULL, failure_code TEXT
    );
    CREATE TABLE quiz_context(
      session_id TEXT NOT NULL REFERENCES quiz_session(id) ON DELETE CASCADE,
      context_id TEXT NOT NULL, revision TEXT NOT NULL, title TEXT NOT NULL,
      scope TEXT NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL,
      PRIMARY KEY(session_id, context_id, revision)
    );
    CREATE TABLE quiz_question(
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES quiz_session(id) ON DELETE CASCADE,
      generation INTEGER NOT NULL, kind TEXT NOT NULL, fingerprint TEXT NOT NULL, detected_at REAL NOT NULL,
      UNIQUE(session_id, generation)
    );
    CREATE TABLE quiz_capture(
      id TEXT PRIMARY KEY, question_id TEXT NOT NULL REFERENCES quiz_question(id) ON DELETE CASCADE,
      capture_generation INTEGER NOT NULL, viewport_index INTEGER NOT NULL,
      relative_path TEXT NOT NULL UNIQUE, ciphertext_digest TEXT NOT NULL,
      width INTEGER NOT NULL, height INTEGER NOT NULL, byte_count INTEGER NOT NULL, created_at REAL NOT NULL,
      CHECK(viewport_index BETWEEN 0 AND 3), CHECK(byte_count > 0)
    );
    CREATE TABLE quiz_worker(
      id TEXT PRIMARY KEY, question_id TEXT NOT NULL REFERENCES quiz_question(id) ON DELETE CASCADE,
      slot INTEGER NOT NULL, role TEXT NOT NULL, model_id TEXT NOT NULL, effort TEXT NOT NULL,
      conversation_id TEXT NOT NULL UNIQUE, num_turns INTEGER NOT NULL CHECK(num_turns = 1), created_at REAL NOT NULL
    );
    CREATE TABLE quiz_vote(
      id TEXT PRIMARY KEY, question_id TEXT NOT NULL REFERENCES quiz_question(id) ON DELETE CASCADE,
      worker_id TEXT NOT NULL REFERENCES quiz_worker(id) ON DELETE CASCADE,
      answer TEXT NOT NULL, confidence INTEGER NOT NULL CHECK(confidence BETWEEN 0 AND 100),
      is_arbiter INTEGER NOT NULL, created_at REAL NOT NULL
    );
    CREATE TABLE quiz_source(
      id INTEGER PRIMARY KEY, vote_id TEXT NOT NULL REFERENCES quiz_vote(id) ON DELETE CASCADE,
      url TEXT NOT NULL, title TEXT, query TEXT, accessed_at REAL NOT NULL
    );
    CREATE TABLE quiz_final_answer(
      id TEXT PRIMARY KEY, question_id TEXT NOT NULL UNIQUE REFERENCES quiz_question(id) ON DELETE CASCADE,
      answer_json BLOB NOT NULL, answer TEXT NOT NULL,
      confidence INTEGER NOT NULL CHECK(confidence BETWEEN 0 AND 100),
      verified INTEGER NOT NULL, answered_at REAL NOT NULL
    );
    CREATE INDEX quiz_session_started ON quiz_session(started_at DESC);
    CREATE INDEX quiz_question_session ON quiz_question(session_id, generation);
    CREATE INDEX quiz_capture_question ON quiz_capture(question_id, viewport_index);
    """
}

public enum QuizAgyAuditFailure: Error, Sendable, Equatable {
    case invalidWorkerIdentity
}
