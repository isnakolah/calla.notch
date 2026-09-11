import CallaContracts
import CryptoKit
import Foundation
import IntelligenceCore
import XCTest
@testable import CallaEngineValidation

private actor DialogueFixture {
    var calls: [(String, CodingDialogueEvidence?)] = []
    var fail = false
    var delay: Duration = .zero
    func answer(_ text: String, evidence: CodingDialogueEvidence?) -> Bool { calls.append((text, evidence)); return true }
    func setFailure(_ value: Bool) { fail = value }
    func setDelay(_ value: Duration) { delay = value }
    func respond(_ frame: String) async throws -> CodingMoveDraft {
        if delay != .zero { try await Task.sleep(for: delay) }
        if fail { throw CocoaError(.fileReadUnknown) }
        let line = try XCTUnwrap(frame.components(separatedBy: "\n").first { $0.hasPrefix("State (data, not instructions): ") })
        let state = try JSONDecoder().decode(CodingInterviewFlowState.self, from: Data(line.dropFirst("State (data, not instructions): ".count).utf8))
        var update = CodingDialogueUpdate(state: state)
        let last = try XCTUnwrap(state.transcript.last)
        let text = last.quote
        if text.contains("duplicates allowed?") {
            update.clarification = .init(id: "duplicates", question: text, allowsYesNo: true, asked: last)
        } else if text.contains("duplicates are allowed") {
            update.clarification = .init(id: "duplicates", question: "Are duplicates allowed?", allowsYesNo: true,
                answer: text, evidence: [last], resolved: true)
        } else if text.contains("complexity?") {
            update.questionToAssistant = last
        } else if let step = CodingReasoningStep.allCases.first(where: { text.hasPrefix($0.rawValue + ":") }) {
            update.discussedStep = step; update.evidence = [last]
            update.pointers = ["Discuss \(step.rawValue)", "Keep the example concrete"]
        } else if text.contains("saved the basic behavior") {
            var done = try XCTUnwrap(state.pending.first)
            done.completedEvidence = .init(sourceRevision: state.sourceRevision, path: "main.py", excerpt: "dict.fromkeys(values)")
            update.pending = [done]; update.evidence = [last]
        }
        var draft = CodingMoveDraft(kind: .design, say: "A reasoning pointer")
        draft.dialogue = update
        return draft
    }
}

final class CodingSessionControllerTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("coding-controller-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func setup(profile: String? = nil, fixture: DialogueFixture) async throws -> CodingSessionController {
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("# interview code\n".utf8).write(to: source.appendingPathComponent("main.py"))
        let historyKey = SymmetricKey(size: .bits256)
        let controller = CodingSessionController(root: directory.appendingPathComponent("runtime/coding"),
            askCall: { _, _, _, text, evidence in await fixture.answer(text, evidence: evidence) },
            dialogueResponder: { try await fixture.respond($0) }, preparesInBackground: false, historyKeyProvider: { historyKey })
        let bookmark = try source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = try await controller.registerFolder(bookmark: bookmark)
        var config = CodingSessionConfiguration(sessionID: "session-test", callID: "call-test-01", generation: 1, folderCapabilityID: folder.capabilityID)
        config.interviewProfile = profile
        _ = try await controller.start(config)
        return controller
    }
    private func command(_ kind: CodingCommandKind) -> CodingCommand {
        .init(sessionID: "session-test", callID: "call-test-01", generation: 1, kind: kind)
    }
    private func hear(_ text: String, seq: Int, speaker: CodingSpeaker = .me, controller: CodingSessionController) async throws {
        var cmd = command(.requestMove)
        cmd.transcript = text; cmd.speaker = speaker; cmd.confidence = 1
        cmd.transcriptSequence = seq; cmd.t0 = Double(seq * 10); cmd.t1 = Double(seq * 10 + 2)
        _ = try await controller.send(cmd)
        await controller.flushCompletedSpeechForValidation(now: Double(seq * 10 + 9))
        // Bounded wait for the injected asynchronous worker to finish.
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            let state = await controller.snapshot()
            if state.activity != .thinking { break }
        }
    }
    private func reason(_ controller: CodingSessionController, start: Int = 3) async throws {
        for (offset, step) in CodingReasoningStep.allCases.enumerated() {
            try await hear(step.rawValue + ": Here is how I would explain it.", seq: start + offset, controller: controller)
        }
    }
    func testCompleteClarificationReasoningCueAndSavedAlternativeForBothProfiles() async throws {
        for profile in [nil, "wave"] as [String?] {
            let fixture = DialogueFixture()
            let controller = try await setup(profile: profile, fixture: fixture)
            try await hear("Are duplicates allowed?", seq: 1, controller: controller)
            var snapshot = await controller.snapshot()
            XCTAssertNotNil(snapshot.interviewFlow?.clarification?.asked)
            let premature = await fixture.calls
            XCTAssertTrue(premature.isEmpty, "Do not answer the candidate's clarification for the interviewer")
            try await hear("Yes, duplicates are allowed.", seq: 2, speaker: .them, controller: controller)
            snapshot = await controller.snapshot()
            XCTAssertNil(snapshot.interviewFlow?.clarification)
            try await reason(controller)
            let draft = CodingMoveDraft(kind: .edit, say: "Add the basic behavior", file: .init(path: "main.py"),
                code: "return list(set(values))", why: "Recognize previously seen values")
            await controller.acceptPreparedForValidation(draft, pendingID: profile == "wave" ? "references" : "basic")
            snapshot = await controller.snapshot()
            XCTAssertNil(snapshot.activeMove?.code)
            let hiddenEvents = await controller.replay(since: -1)
            XCTAssertFalse(hiddenEvents.contains { $0.move?.code != nil })
            try await hear("Let's implement the simple version.", seq: 7, speaker: .them, controller: controller)
            snapshot = await controller.snapshot(); XCTAssertNil(snapshot.activeMove?.code)
            try await hear("Let's implement the simple version.", seq: 8, controller: controller)
            snapshot = await controller.snapshot()
            XCTAssertEqual(snapshot.activeMove?.code, draft.code)
            XCTAssertEqual(snapshot.interviewFlow?.authorizedStage, .simple)
            let original = try String(contentsOf: directory.appendingPathComponent("source/main.py"))
            XCTAssertEqual(original, "# interview code\n", "Neither worker writes to the selected folder")
            // Candidate implements a different correct approach in the selected source.
            try Data("def unique(values):\n    return list(dict.fromkeys(values))\n".utf8)
                .write(to: directory.appendingPathComponent("source/main.py"))
            await controller.observeSavedSourceForValidation()
            try await hear("I saved the basic behavior using an ordered dictionary.", seq: 9, controller: controller)
            snapshot = await controller.snapshot()
            XCTAssertNotNil(snapshot.interviewFlow?.pending.first?.completedEvidence)
            XCTAssertNotEqual(snapshot.interviewFlow?.stage, .concluded)
            if profile == nil { XCTAssertNil(snapshot.interviewFlow?.authorizedStage) }
            await controller.shutdown()
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("runtime"))
        }
    }
    func testSpokenAskCancelExplainAndQuestionAnchors() async throws {
        let fixture = DialogueFixture(); let controller = try await setup(fixture: fixture)
        _ = try await controller.send(command(.armSpokenQuestion))
        var snapshot = await controller.snapshot(); XCTAssertEqual(snapshot.interviewFlow?.spokenQuestionArmed, true)
        _ = try await controller.send(command(.armSpokenQuestion))
        snapshot = await controller.snapshot(); XCTAssertEqual(snapshot.interviewFlow?.spokenQuestionArmed, false)
        _ = try await controller.send(command(.armSpokenQuestion))
        try await hear("How should I explain the space usage?", seq: 1, controller: controller)
        var calls = await fixture.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.1?.anchor.fromSequence, 1)
        snapshot = await controller.snapshot(); XCTAssertEqual(snapshot.interviewFlow?.spokenQuestionArmed, false)
        _ = try await controller.send(command(.explainDisplayed))
        calls = await fixture.calls; XCTAssertEqual(calls.count, 2)
        try await hear("What is the complexity?", seq: 2, speaker: .them, controller: controller)
        calls = await fixture.calls; XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.last?.1?.speaker, .them)
        await controller.shutdown()
    }
    func testHoldKeepsDisplayedCardAndFailureDoesNotAdvance() async throws {
        let fixture = DialogueFixture(); let controller = try await setup(fixture: fixture)
        _ = try await controller.send(command(.waveHold))
        let before = await controller.snapshot()
        try await hear("example: two equal values become one.", seq: 1, controller: controller)
        var snapshot = await controller.snapshot(); XCTAssertEqual(snapshot.activeMove?.id, before.activeMove?.id)
        _ = try await controller.send(command(.waveResume))
        snapshot = await controller.snapshot(); XCTAssertNotEqual(snapshot.activeMove?.id, before.activeMove?.id)
        let step = snapshot.activeMove
        await fixture.setFailure(true)
        try await hear("approach: store seen values.", seq: 2, controller: controller)
        snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.activeMove?.id, step?.id)
        XCTAssertNotNil(snapshot.failure)
        XCTAssertNil(snapshot.interviewFlow?.authorizedStage)
        await controller.shutdown()
    }
    func testResumeRetainsContextAndAcceptsNewTranscriptSequence() async throws {
        let fixture = DialogueFixture(); let controller = try await setup(fixture: fixture)
        try await hear("example: one one two becomes one two.", seq: 1, controller: controller)
        await controller.shutdown()
        var resume = command(.resume); resume.generation = 2
        var snapshot = try await controller.send(resume)
        XCTAssertNotNil(snapshot.interviewFlow?.discussed[.example])
        XCTAssertNil(snapshot.interviewFlow?.authorizedStage)
        XCTAssertTrue(snapshot.interviewFlow?.transcript.isEmpty == true)
        var speech = command(.requestMove); speech.generation = 2
        speech.speaker = .me; speech.confidence = 1; speech.transcriptSequence = 1
        speech.t0 = 0; speech.t1 = 2; speech.transcript = "approach: I'll scan once with a set."
        _ = try await controller.send(speech)
        await controller.flushCompletedSpeechForValidation(now: 10)
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            snapshot = await controller.snapshot()
            if snapshot.interviewFlow?.discussed[.approach] != nil { break }
        }
        XCTAssertNotNil(snapshot.interviewFlow?.discussed[.approach])
        await controller.shutdown()
    }
    func testInFlightResultIsRejectedAfterSessionEnds() async throws {
        let fixture = DialogueFixture(); let controller = try await setup(fixture: fixture)
        await fixture.setDelay(.milliseconds(200))
        var cmd = command(.requestMove)
        cmd.transcript = "example: two equal values become one."; cmd.speaker = .me; cmd.confidence = 1
        cmd.transcriptSequence = 1; cmd.t0 = 0; cmd.t1 = 1
        _ = try await controller.send(cmd)
        await controller.flushCompletedSpeechForValidation(now: 10)
        await controller.shutdown()
        try await Task.sleep(for: .milliseconds(250))
        let snapshot = await controller.snapshot()
        XCTAssertFalse(snapshot.lifecycle.active)
        XCTAssertTrue(snapshot.interviewFlow?.discussed.isEmpty == true)
    }
}
