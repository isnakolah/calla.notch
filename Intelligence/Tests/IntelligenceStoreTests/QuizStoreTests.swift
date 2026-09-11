import XCTest
import CryptoKit
import CallaContracts
@testable import IntelligenceStore

final class QuizStoreTests: XCTestCase {
    private func makeStore() throws -> (QuizStore, URL, SymmetricKey) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let key = SymmetricKey(size: .bits256)
        let store = try QuizStore(path: root.appendingPathComponent("quiz/quiz.sqlite"),
                                  captureRoot: root.appendingPathComponent("quiz/captures"), key: key)
        return (store, root, key)
    }

    private func configuration() -> QuizSessionConfiguration {
        .init(sessionID: "session-1234", target: .init(
            processID: 12, windowID: 34, bundleID: "com.example.browser",
            applicationName: "Browser", windowTitle: "Quiz", pixelWidth: 1000, pixelHeight: 700),
              eventLabel: "Biology", context: [.init(id: "context-1234", revision: "revision-1",
                                                      title: "Notes", scope: .event,
                                                      kind: "note", text: "frozen")],
              voters: [.init(modelID: "gemini-3.1-pro-high"),
                       .init(modelID: "claude-opus-4-6-thinking"),
                       .init(modelID: "claude-sonnet-4-6")],
              arbiter: .init(modelID: "claude-opus-4-6-thinking"))
    }

    func testEncryptedCaptureRoundTripAndDeletion() async throws {
        let (store, root, _) = try makeStore()
        try await store.begin(configuration())
        let jpeg = Data([0xff, 0xd8, 0xff, 1, 2, 3, 0xff, 0xd9])
        let frame = QuizCaptureFrame(id: "capture-123456789", sessionID: "session-1234",
                                     questionID: "question-1234", questionGeneration: 1,
                                     captureGeneration: 1, viewportIndex: 0, width: 1, height: 1,
                                     jpeg: jpeg, normalizedOCR: "question", fingerprint: "fingerprint")
        let stored = try await store.persist(frame)
        let ciphertext = try Data(contentsOf: root.appendingPathComponent("quiz/captures/\(stored.relativePath)"))
        XCTAssertFalse(ciphertext.contains(jpeg))
        let revealed = try await store.reveal(captureID: frame.id)
        XCTAssertEqual(revealed, jpeg)
        try await store.delete(sessionID: "session-1234")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("quiz/captures/\(stored.relativePath)").path))
    }

    func testHistoryContainsOnlyFinalAnswerProjection() async throws {
        let (store, _, _) = try makeStore()
        try await store.begin(configuration())
        let frame = QuizCaptureFrame(id: "capture-123456789", sessionID: "session-1234",
                                     questionID: "question-1234", questionGeneration: 1,
                                     captureGeneration: 1, viewportIndex: 0, width: 1, height: 1,
                                     jpeg: Data([0xff, 0xd8, 0xff, 0xd9]),
                                     normalizedOCR: "question", fingerprint: "fingerprint")
        _ = try await store.persist(frame)
        try await store.record(final: .init(sessionID: "session-1234", questionID: "question-1234",
                                            questionGeneration: 1, kind: .boolean,
                                            answer: "True", confidence: 82, verified: true))
        let history = try await store.history()
        XCTAssertEqual(history.first?.answers.first?.answer, "True")
        XCTAssertEqual(history.first?.answers.first?.confidence, 82)
    }

    func testGradingAnswersProducesCalibrationSamples() async throws {
        let (store, _, _) = try makeStore()
        try await store.begin(configuration())
        let frame = QuizCaptureFrame(id: "capture-223456789", sessionID: "session-1234",
                                     questionID: "question-2234", questionGeneration: 1,
                                     captureGeneration: 1, viewportIndex: 0, width: 1, height: 1,
                                     jpeg: Data([0xff, 0xd8, 0xff, 0xd9]),
                                     normalizedOCR: "a alpha\nb beta", fingerprint: "fingerprint-2")
        _ = try await store.persist(frame)
        let answer = QuizFinalAnswer(id: "answer-123456789", sessionID: "session-1234",
                                     questionID: "question-2234", questionGeneration: 1,
                                     kind: .singleChoice, answer: "B — beta", confidence: 91,
                                     verified: true)
        try await store.record(final: answer)

        // Ungraded answers say nothing about whether a confidence band is honest.
        let initial = try await store.grade(answerID: answer.id)
        XCTAssertEqual(initial, .ungraded)
        let before = try await store.calibrationSamples()
        XCTAssertTrue(before.isEmpty)

        try await store.grade(answerID: answer.id, .incorrect)
        let recorded = try await store.grade(answerID: answer.id)
        XCTAssertEqual(recorded, .incorrect)
        let samples = try await store.calibrationSamples()
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.kind, .singleChoice)
        XCTAssertEqual(samples.first?.displayedConfidence, 91)
        XCTAssertEqual(samples.first?.correct, false)

        // A grade can be taken back.
        try await store.grade(answerID: answer.id, .ungraded)
        let cleared = try await store.calibrationSamples()
        XCTAssertTrue(cleared.isEmpty)
    }

    func testSchemaIsAtTheCurrentVersion() async throws {
        let (store, _, _) = try makeStore()
        let version = try await store.schemaVersion()
        XCTAssertEqual(version, 4)
    }

    /// A refinement must not overwrite the answer it improves on: the pair is the
    /// point, and `question_id` used to be UNIQUE.
    func testARefinementIsStoredBesideTheAnswerItImprovesOn() async throws {
        let (store, _, _) = try makeStore()
        try await store.begin(configuration())
        let frame = QuizCaptureFrame(id: "capture-323456789", sessionID: "session-1234",
                                     questionID: "question-3234", questionGeneration: 1,
                                     captureGeneration: 1, viewportIndex: 0, width: 1, height: 1,
                                     jpeg: Data([0xff, 0xd8, 0xff, 0xd9]),
                                     normalizedOCR: "write a function", fingerprint: "fingerprint-3")
        _ = try await store.persist(frame)

        let first = QuizFinalAnswer(sessionID: "session-1234", questionID: "question-3234",
                                    questionGeneration: 1, kind: .code, answer: "brute force",
                                    confidence: 70, verified: true)
        let refined = QuizFinalAnswer(sessionID: "session-1234", questionID: "question-3234",
                                      questionGeneration: 1, kind: .code, answer: "two pointers",
                                      confidence: 92, verified: true, revision: 1,
                                      rationale: "O(n) instead of O(n^2)")
        try await store.record(final: first)
        try await store.record(final: refined)

        let history = try await store.history()
        let answers = history.first?.answers ?? []
        XCTAssertEqual(answers.count, 2)
        XCTAssertEqual(answers.map(\.revision), [0, 1])
        // The reasoning is what makes the refinement worth keeping.
        XCTAssertEqual(answers.last?.rationale, "O(n) instead of O(n^2)")
        XCTAssertEqual(answers.first?.answer, "brute force")
    }

    func testWrongKeyRejectsCiphertext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = try QuizCaptureVault(root: root, key: SymmetricKey(size: .bits256))
        let stored = try first.store(Data([0xff, 0xd8, 0xff, 0xd9]), id: "capture-123456789")
        let second = try QuizCaptureVault(root: root, key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try second.reveal(relativePath: stored.relativePath))
    }
}
