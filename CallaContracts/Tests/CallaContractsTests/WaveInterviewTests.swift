import XCTest
@testable import CallaContracts

final class WaveInterviewTests: XCTestCase {
    func testCoordinatedCallRequestRetainsIdentityAndReadsOlderCommands() throws {
        let id = UUID()
        let command = CallHostCommand(callID: "call", generation: 1, kind: .answer, text: "Explain this", questionID: id)
        let encoded = try JSONEncoder().encode(command)
        XCTAssertEqual(try JSONDecoder().decode(CallHostCommand.self, from: encoded).questionID, id)
        let older = Data(#"{"contractVersion":1,"callID":"call","generation":1,"kind":"answer","text":"Explain this"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CallHostCommand.self, from: older).questionID)
    }

    func testPresetModelsDoNotSendAnIndependentEffortOverride() {
        for model in ["gemini-3.8-flash-low", "gemini-3.8-flash-medium", "gemini-3.8-flash-high", "gemini-3.1-pro-high", "claude-opus-4-6-thinking"] {
            XCTAssertTrue(CodingModelSelection(modelID: model, effort: "high").effortArguments.isEmpty)
        }
        XCTAssertEqual(CodingModelSelection(modelID: "claude-sonnet-4-6", effort: "medium").effortArguments, ["--effort", "medium"])
    }

    func testReadinessRejectsNarrationNegationAndHypotheticals() {
        XCTAssertTrue(WaveInterviewState.isReadinessCue("This step is complete."))
        for text in ["Not ready for the next step", "Is this step complete?", "What if this step is done?", "When this step is done, I will save", "This step is not complete"] {
            XCTAssertFalse(WaveInterviewState.isReadinessCue(text))
        }
    }
    func testVerifiedSaveCannotDismissAnAnswer() {
        var state = WaveInterviewState(sessionID: "session-1", sourceRevision: "a")
        for kind in [WaveObservationKind.saved, .checked] {
            state.observe(.init(taskID: "references", revision: state.revision, kind: kind,
                detail: "actual saved code", succeeded: true, shadow: false))
        }
        _ = state.dispatchQuestion(id: "question")
        XCTAssertFalse(state.advance(explicit: false))
        XCTAssertEqual(state.currentTaskID, "references")
        XCTAssertEqual(state.surface, .answer)
    }
    func testQuestionOwnershipAndReturnPreserveUnfinishedTask() {
        var state = WaveInterviewState(sessionID: "session-1", sourceRevision: "a")
        state.readingPositions["code:references"] = 87.5
        XCTAssertTrue(state.dispatchQuestion(id: "utterance-1"))
        XCTAssertFalse(state.dispatchQuestion(id: "utterance-1"))
        XCTAssertEqual(state.surface, .answer)
        state.returnToCoding()
        XCTAssertEqual(state.currentTaskID, "references")
        XCTAssertEqual(state.readingPositions["code:references"], 87.5)
        XCTAssertFalse(state.currentTask!.completed)
    }
    func testPartialSaveAndShadowPassCannotAdvance() {
        var state = WaveInterviewState(sessionID: "session-1", sourceRevision: "a")
        state.observe(.init(taskID: "references", revision: state.revision, kind: .saved,
                            detail: "saved partial implementation", succeeded: true, shadow: false))
        state.observe(.init(taskID: "references", revision: state.revision, kind: .checked,
                            detail: "shadow passes", succeeded: true, shadow: true))
        XCTAssertFalse(state.advance(explicit: false))
        state.observe(.init(taskID: "references", revision: state.revision, kind: .checked,
                            detail: "selected saved revision checked", succeeded: true, shadow: false))
        XCTAssertTrue(state.advance(explicit: false))
        XCTAssertEqual(state.currentTaskID, "literals")
    }
    func testCorrectionsSourceChangeAndUnrelatedEvidenceRejectStaleResults() {
        var state = WaveInterviewState(sessionID: "session-1", sourceRevision: "a")
        let old = state.revision
        state.correct("sum ignores blanks")
        XCTAssertFalse(state.accepts(old))
        state.observe(.init(taskID: "sum", revision: old, kind: .checked,
                            detail: "obsolete", succeeded: true, shadow: false))
        XCTAssertTrue(state.tasks.first { $0.id == "sum" }!.evidence.isEmpty)
        state.sourceChanged("b")
        XCTAssertFalse(state.accepts(old))
        XCTAssertFalse(state.advance(explicit: false))
    }
    func testHoldFreezesPresentationWhileQuestionsAreAccepted() {
        var state = WaveInterviewState(sessionID: "session-1", sourceRevision: "a")
        state.held = true
        XCTAssertTrue(state.dispatchQuestion(id: "q"))
        XCTAssertEqual(state.unread, 1)
        XCTAssertEqual(state.surface, .coding)
        XCTAssertFalse(state.advance(explicit: true))
    }
    func testExplicitContinueFromSuspendedTaskDoesNotReturnToOldTask() {
        var state = WaveInterviewState(sessionID: "session-1", sourceRevision: "a")
        _ = state.dispatchQuestion(id: "q")
        XCTAssertTrue(state.advance(explicit: true))
        XCTAssertEqual(state.currentTaskID, "literals")
        XCTAssertNil(state.suspendedTaskID)
    }
    func testForegroundAdmissionSurvivesTwoBackgroundJobsAndVerifier() {
        var admission = WaveWorkerAdmission()
        let revision = WaveRevision(session: "session-1", source: "a")
        for role in [WaveWorkerRole.coder, .planner, .verifier, .fastAnswer, .interruptionAnswer] {
            XCTAssertTrue(admission.admit(.init(role: role, revision: revision, proposalDirectory: role.rawValue)))
        }
        XCTAssertFalse(admission.admit(.init(role: .reviewer, revision: revision, proposalDirectory: "review")))
        XCTAssertFalse(admission.admit(.init(role: .verifier, revision: revision, proposalDirectory: "second-check")))
    }
    func testOlderSnapshotDecodesWithoutWaveFields() throws {
        let original = CodingSessionSnapshot(sessionID: "session-1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CodingSessionSnapshot.self, from: data)
        XCTAssertNil(decoded.wave); XCTAssertNil(decoded.interviewProfile)
    }
}
