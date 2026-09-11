import CallaContracts
import CryptoKit
import Foundation
import IntelligenceCore
import XCTest
@testable import CallaEngineValidation

/// The dialogue lane is serial and a model turn costs seconds, so what the
/// engine chooses *not* to send is as much a latency decision as which provider
/// it sends to. These pin the choices.
private actor CountingFixture {
    private(set) var turns = 0
    private(set) var frames: [String] = []
    private var anchor: CodingFileAnchor?
    func setAnchor(_ value: CodingFileAnchor?) { anchor = value }
    func respond(_ frame: String) async throws -> CodingMoveDraft {
        turns += 1
        frames.append(frame)
        let prefix = "State (data, not instructions): "
        let line = try XCTUnwrap(frame.components(separatedBy: "\n").first { $0.hasPrefix(prefix) })
        let state = try JSONDecoder().decode(CodingInterviewFlowState.self,
                                             from: Data(line.dropFirst(prefix.count).utf8))
        var update = CodingDialogueUpdate(state: state)
        let last = try XCTUnwrap(state.transcript.last)
        if last.quote.contains("duplicates allowed?") {
            update.clarification = .init(id: "duplicates", question: last.quote,
                                         allowsYesNo: true, asked: last)
        } else if let step = CodingReasoningStep.allCases
            .first(where: { last.quote.hasPrefix($0.rawValue + ":") }) {
            update.discussedStep = step
            update.evidence = [last]
            update.pointers = ["Discuss \(step.rawValue)"]
        }
        var draft = CodingMoveDraft(kind: .design, say: "A reasoning pointer")
        draft.file = anchor
        draft.dialogue = update
        return draft
    }
}

final class CodingFastLaneControllerTests: XCTestCase {
    private var directory: URL!
    private var source: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coding-fast-lane-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("# interview code\n".utf8).write(to: source.appendingPathComponent("main.py"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func setup(fixture: CountingFixture) async throws -> CodingSessionController {
        let historyKey = SymmetricKey(size: .bits256)
        let controller = CodingSessionController(
            root: directory.appendingPathComponent("runtime/coding"),
            dialogueResponder: { try await fixture.respond($0) },
            preparesInBackground: false,
            historyKeyProvider: { historyKey })
        let bookmark = try source.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                               relativeTo: nil)
        let folder = try await controller.registerFolder(bookmark: bookmark)
        let config = CodingSessionConfiguration(
            sessionID: "session-fast", callID: "call-fast-01", generation: 1,
            folderCapabilityID: folder.capabilityID)
        _ = try await controller.start(config)
        return controller
    }

    private func hear(_ text: String, seq: Int, speaker: CodingSpeaker = .me,
                      controller: CodingSessionController) async throws {
        var cmd = CodingCommand(sessionID: "session-fast", callID: "call-fast-01",
                                generation: 1, kind: .requestMove)
        cmd.transcript = text; cmd.speaker = speaker; cmd.confidence = 1
        cmd.transcriptSequence = seq; cmd.t0 = Double(seq * 10); cmd.t1 = Double(seq * 10 + 2)
        _ = try await controller.send(cmd)
        await controller.flushCompletedSpeechForValidation(now: Double(seq * 10 + 9))
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            if await controller.snapshot().activity != .thinking { break }
        }
    }

    /// "yeah, okay" carries no reasoning, earns no step and changes no fact, but
    /// the lane is serial — so it used to take a whole turn while the next real
    /// question queued behind it.
    func testAnAcknowledgementCostsNoModelTurn() async throws {
        let fixture = CountingFixture()
        let controller = try await setup(fixture: fixture)
        try await hear("example: one one two becomes one two.", seq: 1, controller: controller)
        let afterReasoning = await fixture.turns
        XCTAssertEqual(afterReasoning, 1)
        for (offset, filler) in ["yeah", "okay, right", "mm-hmm", "got it", "sure"].enumerated() {
            try await hear(filler, seq: 2 + offset, controller: controller)
        }
        let afterFiller = await fixture.turns
        XCTAssertEqual(afterFiller, afterReasoning, "Back-channel occupied the lane")
        // Still recorded: the transcript is the record, admission only decides
        // what is worth a model.
        let snapshot = await controller.snapshot()
        XCTAssertTrue(snapshot.interviewFlow?.transcript.contains { $0.quote == "yeah" } == true)
        await controller.shutdown()
    }

    /// The exception. While a clarification is open a bare yes or no is the
    /// answer to it, not back-channel, and dropping it would strand the
    /// interview on a question the candidate already answered.
    func testABareYesStillReachesTheLaneWhileAClarificationIsOpen() async throws {
        let fixture = CountingFixture()
        let controller = try await setup(fixture: fixture)
        // The candidate asks; the clarification is theirs to have answered.
        try await hear("Are duplicates allowed?", seq: 1, controller: controller)
        let opened = await fixture.turns
        let opening = await controller.snapshot()
        XCTAssertNotNil(opening.interviewFlow?.clarification)
        // And the interviewer answers with one word.
        try await hear("yes", seq: 2, speaker: .them, controller: controller)
        let afterAnswer = await fixture.turns
        XCTAssertGreaterThan(afterAnswer, opened, "An answer was mistaken for back-channel")
        await controller.shutdown()
    }

    /// A save that changes nothing the lane was asked about used to re-ask the
    /// last sentence, which blocked the next real question behind an answer
    /// already on screen.
    func testASaveWithNothingAuthorisedCostsNoModelTurn() async throws {
        let fixture = CountingFixture()
        let controller = try await setup(fixture: fixture)
        try await hear("approach: I will key a dictionary on the cell reference.",
                       seq: 1, controller: controller)
        let before = await fixture.turns
        XCTAssertEqual(before, 1)
        try Data("# interview code\nvalue = 1\n".utf8)
            .write(to: source.appendingPathComponent("main.py"))
        await controller.observeSavedSourceForValidation()
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(10))
            if await controller.snapshot().activity != .thinking { break }
        }
        let afterSave = await fixture.turns
        XCTAssertEqual(afterSave, before, "A save re-asked a question already answered")
        let synced = await controller.snapshot()
        XCTAssertEqual(synced.syncState, .current)
        await controller.shutdown()
    }

    /// A words-only step carries no code, so the only way the panel can say
    /// where the pointers land is the anchor the lane names.
    func testAWordsOnlyStepCarriesTheFileItIsAbout() async throws {
        let fixture = CountingFixture()
        let controller = try await setup(fixture: fixture)
        await fixture.setAnchor(.init(path: "main.py", symbol: "_evaluate", line: 1))
        try await hear("approach: I will resolve references first.", seq: 1, controller: controller)
        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.activeMove?.file?.path, "main.py")
        XCTAssertEqual(snapshot.activeMove?.file?.symbol, "_evaluate")
        await controller.shutdown()
    }

    /// A filename the candidate would look for and not find is worse than none.
    func testAnInventedOrOutOfRangeAnchorIsNotPublished() async throws {
        let fixture = CountingFixture()
        let controller = try await setup(fixture: fixture)
        for anchor in [CodingFileAnchor(path: "does/not/exist.py", symbol: "parse"),
                       CodingFileAnchor(path: "../escape.py"),
                       CodingFileAnchor(path: "/etc/passwd")] {
            await fixture.setAnchor(anchor)
            try await hear("approach: step \(anchor.path).", seq: 1, controller: controller)
            let snapshot = await controller.snapshot()
            XCTAssertNil(snapshot.activeMove?.file, anchor.path)
        }
        // A real file with a line past its end keeps the file and drops the line.
        await fixture.setAnchor(.init(path: "main.py", symbol: "parse", line: 9_000))
        try await hear("correctness: the guard holds.", seq: 2, controller: controller)
        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.activeMove?.file?.path, "main.py")
        XCTAssertNil(snapshot.activeMove?.file?.line)
        await controller.shutdown()
    }

    /// The interviewer speaking is the one input wanted now. Everything the
    /// candidate says is worth interpreting and nothing they say is worth making
    /// a question wait.
    func testOnlyTheInterviewerIsUrgent() {
        func statement(_ text: String, _ speaker: Speaker) -> Statement {
            Statement(fromSeq: 1, toSeq: 1, speaker: speaker, text: text, span: 2, truncated: false)
        }
        for text in ["What happens on a circular reference?",
                     "Walk me through the precedence.",
                     "Actually, the input can contain dates.",
                     "Run the tests."] {
            XCTAssertEqual(CodingSessionController.dialoguePriority(for: statement(text, .remote)),
                           .urgent, text)
        }
        XCTAssertEqual(
            CodingSessionController.dialoguePriority(for: statement("Sounds good, thanks.", .remote)),
            .advisory)
        for text in ["I will start with the simple version.",
                     "What happens on a circular reference?"] {
            XCTAssertEqual(CodingSessionController.dialoguePriority(for: statement(text, .local)),
                           .advisory, text)
        }
    }
}

/// The reply contract, without a schema forcing it.
final class CodingDialogueDecodingTests: XCTestCase {
    private var flow: CodingInterviewFlowState {
        var state = CodingInterviewFlowState(sessionID: "s-1", generation: 3, sourceRevision: "rev-abc")
        state.requirementRevision = 4
        state.taskRevision = 5
        return state
    }

    /// The failure that reached the panel as "Please repeat that point to
    /// retry": every identity field omitted, which under `--json-schema` could
    /// not happen and on the resident host happens routinely.
    func testAReplyThatOmitsIdentityStillDecodes() throws {
        let payload = Data("""
        {"kind":"design","say":"Resolve the reference first",
         "dialogue":{"pointers":["Resolve the reference first","Keep a visited set"]}}
        """.utf8)
        let draft = try CodingSessionController.decodeDraft(payload, identifiedBy: flow)
        let update = try XCTUnwrap(draft.dialogue)
        XCTAssertEqual(update.sessionID, "s-1")
        XCTAssertEqual(update.generation, 3)
        XCTAssertEqual(update.sourceRevision, "rev-abc")
        XCTAssertEqual(update.requirementRevision, 4)
        XCTAssertEqual(update.taskRevision, 5)
        XCTAssertEqual(update.pointers, ["Resolve the reference first", "Keep a visited set"])
        XCTAssertEqual(draft.say, "Resolve the reference first")
    }

    /// The fence is the engine's, not the model's. A reply that names a
    /// different state is stamped with the state the request was built from —
    /// which is exactly what `apply` then compares against the current one, so
    /// a reply that arrives after the interview moved on is still refused.
    func testTheModelCannotTalkItsWayPastTheFence() throws {
        let payload = Data("""
        {"say":"x","dialogue":{"sessionID":"someone-else","generation":99,
         "sourceRevision":"stale","requirementRevision":1,"taskRevision":1}}
        """.utf8)
        let update = try XCTUnwrap(
            CodingSessionController.decodeDraft(payload, identifiedBy: flow).dialogue)
        XCTAssertEqual(update.sessionID, "s-1")
        XCTAssertEqual(update.generation, 3)
        XCTAssertEqual(update.taskRevision, 5)

        // Stamped with the request's state, applied against a state that moved.
        var moved = flow
        moved.taskRevision = 6
        XCTAssertFalse(CodingInterviewFlow.apply(update, to: &moved))
    }

    func testARealDialogueBodySurvivesStamping() throws {
        let payload = Data("""
        {"kind":"design","say":"Talk through the approach",
         "dialogue":{"pointers":["a","b"],"limitation":"No cycle check yet",
                     "discussedSteps":["approach"],
                     "evidence":[{"anchor":{"fromSequence":1,"toSequence":1},
                                  "speaker":"me","quote":"I will use a dict"}]}}
        """.utf8)
        let update = try XCTUnwrap(
            CodingSessionController.decodeDraft(payload, identifiedBy: flow).dialogue)
        XCTAssertEqual(update.discussedSteps, [.approach])
        XCTAssertEqual(update.evidence?.first?.quote, "I will use a dict")
        XCTAssertEqual(update.limitation, "No cycle check yet")
    }

    func testAReplyWithNoDialogueIsStillMalformedRatherThanCrashing() throws {
        let draft = try CodingSessionController.decodeDraft(
            Data(#"{"say":"just words"}"#.utf8), identifiedBy: flow)
        XCTAssertNil(draft.dialogue)
        XCTAssertThrowsError(try CodingSessionController.decodeDraft(
            Data("not json".utf8), identifiedBy: flow))
    }

    /// The message that cost a session to diagnose said only "The data couldn't
    /// be read because it is missing".
    func testADecodeFailureNamesTheField() {
        struct Sample: Decodable { let required: String }
        do {
            _ = try JSONDecoder().decode(Sample.self, from: Data("{}".utf8))
            XCTFail("expected a decoding failure")
        } catch {
            XCTAssertEqual(CodingSessionController.describe(error),
                           "The reply left out required.")
        }
        XCTAssertEqual(CodingSessionController.describe(CodingAgyWorkerFailure.timedOut),
                       "The coding response exceeded its time budget")
    }
}
