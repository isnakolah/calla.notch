import XCTest
@testable import IntelligenceProviders
import IntelligenceCore
import CallaContracts

final class QuizAgyWorkerPoolTests: XCTestCase {
    private struct Fixture: Decodable {
        let id: String
        let questionKind: String
        let expectedOCRContains: [String]
        let expectedAnswer: String
    }

    private func freeCodeCampFixture() throws -> Fixture {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("TestFixtures/Quiz").path) {
            root.deleteLastPathComponent()
        }
        let data = try Data(contentsOf: root.appendingPathComponent(
            "TestFixtures/Quiz/freecodecamp-arborescence-question-2.json"))
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    actor Counter {
        var value = 0
        func next() -> Int { value += 1; return value }
    }

    actor SlotCounter {
        var values: [Int: Int] = [:]
        func next(slot: Int) -> Int {
            values[slot, default: 0] += 1
            return values[slot] ?? 0
        }
    }

    final class FakeChild: QuizAgyChild, @unchecked Sendable {
        let slot: Int
        let serial: Int
        init(slot: Int, serial: Int) { self.slot = slot; self.serial = serial }
        func run(_ request: QuizAgyRequest, timeout: TimeInterval) async throws -> QuizAgyWorkerResult {
            QuizAgyWorkerResult(
                output: QuizWorkerOutput(answer: "B", confidence: 90),
                identity: QuizWorkerIdentity(slot: slot, modelID: "model-\(slot)", effort: "high",
                                               conversationID: "conversation-\(slot)-\(serial)",
                                               numberOfTurns: 1))
        }
        func cancel() async {}
    }

    final class FirstFailureChild: QuizAgyChild, @unchecked Sendable {
        let slot: Int
        let attempt: Int
        init(slot: Int, attempt: Int) { self.slot = slot; self.attempt = attempt }
        func run(_ request: QuizAgyRequest, timeout: TimeInterval) async throws -> QuizAgyWorkerResult {
            if slot == 1, attempt == 1 { throw QuizAgyFailure.processEnded }
            return QuizAgyWorkerResult(
                output: QuizWorkerOutput(answer: "B", confidence: 90),
                identity: QuizWorkerIdentity(
                    slot: slot, modelID: "model-\(slot)", effort: "high",
                    conversationID: "recovery-\(slot)-\(attempt)", numberOfTurns: 1))
        }
        func cancel() async {}
    }

    private let selections = [
        QuizModelSelection(modelID: "gemini-3.1-pro-high"),
        QuizModelSelection(modelID: "claude-opus-4-6-thinking"),
        QuizModelSelection(modelID: "claude-sonnet-4-6"),
    ]

    private func request(_ id: String = "question-1234") -> QuizAgyRequest {
        QuizAgyRequest(sessionID: "session-1234", questionID: id,
                       questionGeneration: 1, questionKind: .singleChoice,
                       frozenContext: "context", ocr: "question", viewportJPEGs: [])
    }

    /// A council of one is a supported setup now, not a rejected one.
    func testASingleVoterCouncilRunsWithNoArbiter() async throws {
        let counter = Counter()
        let pool = try QuizAgyWorkerPool(
            voters: [QuizModelSelection(modelID: "gemini-3.7-flash-low", effort: "low")],
            arbiter: nil) { slot, _, _ in FakeChild(slot: slot, serial: await counter.next()) }
        let count = await pool.voterCount
        let hasArbiter = await pool.hasArbiter
        XCTAssertEqual(count, 1)
        XCTAssertFalse(hasArbiter)
        try await pool.prepare()
        let results = await pool.runVoters(request())
        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(results[0])
        // With no arbiter there is nothing to escalate to, and asking says so.
        let arbiter = await pool.runArbiter(request())
        XCTAssertNil(arbiter)
        await pool.stop()
    }

    func testACouncilLargerThanThreeGetsItsOwnSlots() async throws {
        let counter = Counter()
        let five = (0 ..< 5).map { QuizModelSelection(modelID: "model-\($0)") }
        let pool = try QuizAgyWorkerPool(voters: five, arbiter: nil) { slot, _, _ in
            FakeChild(slot: slot, serial: await counter.next())
        }
        try await pool.prepare()
        let results = await pool.runVoters(request())
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(results.compactMap { $0 }.count, 5)
        // Slots are distinct all the way up; the arbiter used to be pinned to 3
        // and would have collided with a voter here.
        XCTAssertEqual(Set(results.compactMap { $0?.identity.slot }).count, 5)
        await pool.stop()
    }

    func testCouncilSizeIsBounded() async {
        let counter = Counter()
        let factory: QuizAgyChildFactory = { slot, _, _ in
            FakeChild(slot: slot, serial: await counter.next())
        }
        XCTAssertThrowsError(try QuizAgyWorkerPool(voters: [], arbiter: nil, factory: factory))
        let tooMany = (0 ... QuizContract.maximumVoters).map {
            QuizModelSelection(modelID: "model-\($0)")
        }
        XCTAssertThrowsError(try QuizAgyWorkerPool(voters: tooMany, arbiter: nil,
                                                   factory: factory))
    }

    /// The point of streaming: results are usable as they land, so the caller can
    /// settle without waiting for the slowest voter.
    func testStreamYieldsEachVoterAsItLands() async throws {
        let counter = Counter()
        let pool = try QuizAgyWorkerPool(
            voters: selections,
            arbiter: QuizModelSelection(modelID: "claude-opus-4-6-thinking")) {
                slot, _, _ in FakeChild(slot: slot, serial: await counter.next())
            }
        try await pool.prepare()
        var seen: [Int] = []
        for await item in pool.streamVoters(request(), deadline: Date().addingTimeInterval(30),
                                            onRetry: {}) {
            seen.append(item.slot)
            XCTAssertNotNil(item.result)
        }
        XCTAssertEqual(Set(seen), [0, 1, 2])
        await pool.stop()
    }

    func testAbandoningTheStreamEarlyLeavesNothingRunning() async throws {
        let counter = Counter()
        let pool = try QuizAgyWorkerPool(
            voters: selections, arbiter: nil) {
                slot, _, _ in FakeChild(slot: slot, serial: await counter.next())
            }
        try await pool.prepare()
        // Take one result and walk away, the way an early settle does.
        for await _ in pool.streamVoters(request(), deadline: Date().addingTimeInterval(30),
                                         onRetry: {}) {
            break
        }
        await pool.cancelActive()
        await pool.stop()
    }

    func testPoolCreatesReplacementAndNeverReusesConversation() async throws {
        let counter = Counter()
        let factory: QuizAgyChildFactory = { slot, _, _ in
            FakeChild(slot: slot, serial: await counter.next())
        }
        let pool = try QuizAgyWorkerPool(voters: selections,
                                        arbiter: QuizModelSelection(modelID: "claude-opus-4-6-thinking"),
                                        factory: factory)
        try await pool.prepare()
        let request = QuizAgyRequest(sessionID: "session-1234", questionID: "question-1234",
                                     questionGeneration: 1, questionKind: .singleChoice,
                                     frozenContext: "context", ocr: "question", viewportJPEGs: [])
        let first = await pool.runVoters(request)
        XCTAssertEqual(first.compactMap { $0 }.count, 3)
        for result in first.compactMap({ $0 }) { try await pool.acceptIsolation(result) }
        let second = await pool.runVoters(request)
        XCTAssertEqual(second.compactMap { $0 }.count, 3)
        XCTAssertEqual(Set(first.compactMap { $0?.identity.conversationID })
            .intersection(Set(second.compactMap { $0?.identity.conversationID })).count, 0)
        await pool.stop()
    }

    func testRetryRunsOnlyMissingSlotWithFreshConversation() async throws {
        let counter = Counter()
        let pool = try QuizAgyWorkerPool(
            voters: selections,
            arbiter: QuizModelSelection(modelID: "claude-opus-4-6-thinking")) {
                slot, _, _ in FakeChild(slot: slot, serial: await counter.next())
            }
        try await pool.prepare()
        let request = QuizAgyRequest(
            sessionID: "session-retry", questionID: "question-retry",
            questionGeneration: 1, questionKind: .singleChoice,
            frozenContext: "", ocr: "which answer", viewportJPEGs: [])
        let first = await pool.runVoters(request)
        let retry = await pool.runVoters(request, slots: [1])

        XCTAssertNil(retry[0])
        XCTAssertNotNil(retry[1])
        XCTAssertNil(retry[2])
        XCTAssertNotEqual(first[1]?.identity.conversationID,
                          retry[1]?.identity.conversationID)
        await pool.stop()
    }

    func testImmediateWorkerFailureUsesWarmReplacementWithinSharedDeadline() async throws {
        let attempts = SlotCounter()
        let retries = Counter()
        let pool = try QuizAgyWorkerPool(
            voters: selections,
            arbiter: QuizModelSelection(modelID: "claude-opus-4-6-thinking")) {
                slot, _, _ in
                FirstFailureChild(slot: slot, attempt: await attempts.next(slot: slot))
            }
        try await pool.prepare()
        let request = QuizAgyRequest(
            sessionID: "session-recover", questionID: "question-recover",
            questionGeneration: 1, questionKind: .singleChoice,
            frozenContext: "", ocr: "which answer", viewportJPEGs: [])
        let results = await pool.runVotersRecovering(
            request, deadline: Date().addingTimeInterval(5)) {
                _ = await retries.next()
            }

        XCTAssertEqual(results.compactMap { $0 }.count, 3)
        XCTAssertEqual(results[1]?.identity.conversationID, "recovery-1-2")
        let retryCount = await retries.value
        XCTAssertEqual(retryCount, 1)
        await pool.stop()
    }

    func testPresetThinkingModelOmitsUnsupportedEffortFlag() {
        XCTAssertEqual(
            QuizAgyModelCapabilities.effortArguments(
                modelID: "claude-opus-4-6-thinking", effort: "high"), [])
        XCTAssertEqual(
            QuizAgyModelCapabilities.effortArguments(
                modelID: "gemini-3.1-pro-high", effort: "high"),
            ["--effort", "high"])
        XCTAssertEqual(
            QuizAgyModelCapabilities.effortArguments(
                modelID: "claude-sonnet-4-6", effort: "high"),
            ["--effort", "high"])
    }

    func testDuplicateConversationFailsIsolationAudit() async throws {
        let counter = Counter()
        let pool = try QuizAgyWorkerPool(voters: selections,
                                        arbiter: QuizModelSelection(modelID: "claude-opus-4-6-thinking")) {
            slot, _, _ in FakeChild(slot: slot, serial: await counter.next())
        }
        let result = QuizAgyWorkerResult(
            output: .init(answer: "True", confidence: 90),
            identity: .init(slot: 0, modelID: "model", effort: "high",
                            conversationID: "same-conversation", numberOfTurns: 1))
        try await pool.acceptIsolation(result)
        do {
            try await pool.acceptIsolation(result)
            XCTFail("expected duplicate rejection")
        } catch {
            XCTAssertEqual(error as? QuizAgyFailure, .conversationReused)
        }
    }

    func testStreamResultRequiresOneTurn() throws {
        let event: [String: Any] = [
            "result": [
                "status": "SUCCESS", "conversation_id": "conversation-1", "num_turns": 2,
                "structured_output": ["answer": "B", "confidence": 90],
            ],
        ]
        XCTAssertThrowsError(try QuizAgyProcessChild.parseResult(
            event, slot: 0, selection: selections[0], sources: []))
    }

    func testOneTurnPlainJSONResponseParsesWithoutSchemaRepairTurn() throws {
        let event: [String: Any] = [
            "result": [
                "status": "SUCCESS", "conversation_id": "conversation-plain", "num_turns": 1,
                "response": #"{"answer":"C","confidence":96}"#,
            ],
        ]
        let parsed = try QuizAgyProcessChild.parseResult(
            event, slot: 0, selection: selections[0], sources: [])
        XCTAssertEqual(parsed.output, QuizWorkerOutput(answer: "C", confidence: 96))
        XCTAssertTrue(parsed.identity.provesIsolation)
    }

    func testCatalogParsesLiveShape() {
        XCTAssertEqual(QuizAgyModelCatalog.parse("Fetching available models...\ngemini-3.1-pro-high\tGemini\nclaude-opus-4-6-thinking\tClaude\n"),
                       ["gemini-3.1-pro-high", "claude-opus-4-6-thinking"])
    }

    func testFreeCodeCampFixtureProducesBoundedOneViewportWorkerPrompt() throws {
        let fixture = try freeCodeCampFixture()
        XCTAssertEqual(fixture.questionKind, QuizQuestionKind.singleChoice.rawValue)
        let ocr = fixture.expectedOCRContains.joined(separator: " ")
        let request = QuizAgyRequest(
            sessionID: "fixture-session", questionID: fixture.id,
            questionGeneration: 1, questionKind: .singleChoice,
            frozenContext: "", ocr: ocr,
            viewportJPEGs: [Data([0xff, 0xd8, 0xff, 0xd9])])
        let viewportPath = "/private/quiz-worker/viewport-1.jpg"
        let prompt = QuizAgyProcessChild.prompt(
            request, role: .voter, viewportPaths: [viewportPath])
        XCTAssertTrue(prompt.contains("Viewport 1: \(viewportPath)"))
        XCTAssertFalse(prompt.contains("@viewport-2.jpg"))
        for fragment in fixture.expectedOCRContains { XCTAssertTrue(prompt.contains(fragment)) }
        XCTAssertTrue(fixture.expectedAnswer.hasPrefix("C —"))
    }

    func testOnlyExactStagedViewportReadIsAllowed() {
        let staged = "/private/quiz-worker/viewport-1.jpg"
        let info: [String: Any] = ["parameters": ["AbsolutePath": staged]]
        XCTAssertTrue(QuizAgyProcessChild.isAllowedTool(
            "view_file", info: info, allowedViewportPaths: [staged]))
        XCTAssertFalse(QuizAgyProcessChild.isAllowedTool(
            "view_file",
            info: ["parameters": ["AbsolutePath": "/private/quiz-worker/../secret.txt"]],
            allowedViewportPaths: [staged]))
        XCTAssertFalse(QuizAgyProcessChild.isAllowedTool(
            "find_by_name", info: info, allowedViewportPaths: [staged]))
        XCTAssertFalse(QuizAgyProcessChild.isAllowedTool(
            "run_command", info: info, allowedViewportPaths: [staged]))
        XCTAssertFalse(QuizAgyProcessChild.isAllowedTool(
            "search_web", info: info, allowedViewportPaths: [staged]))
        XCTAssertTrue(QuizAgyProcessChild.isAllowedTool(
            "search_web", info: info, allowedViewportPaths: [staged],
            allowsWebResearch: true))
    }
}
