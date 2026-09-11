import Foundation
import XCTest
@testable import CallaContracts

final class CodingDialogueContractsTests: XCTestCase {
    func testOlderSnapshotMoveAndEventDecodeWithoutFlowOrAuthorization() throws {
        let move = CodingMove(ordinal: 1, sourceRevision: "old", kind: .implementation, code: "old model output")
        let snapshot = CodingSessionSnapshot(sessionID: "session-old", generation: 1, activeMove: move)
        let decoded = try JSONDecoder().decode(CodingSessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertNil(decoded.interviewFlow)
        XCTAssertNil(decoded.activeMove?.implementationStage)
        var restored = CodingInterviewFlowState(sessionID: "session-old", generation: 2, sourceRevision: "old")
        restored.restore(generation: 2, sourceRevision: "old")
        XCTAssertNil(CodingInterviewPublication.screen(try XCTUnwrap(decoded.activeMove), flow: restored).code)
        let event = CodingEvent(sessionID: "session-old", callID: "call-old", generation: 1, sequence: 1, kind: .move, move: move)
        let oldEvent = try JSONDecoder().decode(CodingEvent.self, from: JSONEncoder().encode(event))
        XCTAssertNil(oldEvent.interviewFlow)
    }
    func testFlowRoundTripsThroughArchiveSnapshotAndEvents() throws {
        var flow = CodingInterviewFlowState(sessionID: "session-new", generation: 3, sourceRevision: "saved")
        flow.pending = [.init(id: "empty", text: "Empty input", stage: .hardening)]
        flow.clarification = .init(id: "duplicates", question: "Are duplicates allowed?")
        var snapshot = CodingSessionSnapshot(sessionID: flow.sessionID, generation: flow.generation)
        snapshot.interviewFlow = flow
        let decoded = try JSONDecoder().decode(CodingSessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.interviewFlow, flow)
        var event = CodingEvent(sessionID: flow.sessionID, callID: "call-new", generation: 3, sequence: 1, kind: .move)
        event.interviewFlow = flow
        XCTAssertEqual(try JSONDecoder().decode(CodingEvent.self, from: JSONEncoder().encode(event)).interviewFlow, flow)
    }
    func testCoordinatedQuestionCarriesStableIDAndActualTranscriptAnchor() throws {
        var command = CallHostCommand(callID: "call-new", generation: 3, kind: .answer, text: "What is the complexity?", questionID: UUID())
        command.codingEvidence = .init(anchor: .init(fromSequence: 20, toSequence: 22), speaker: .them, quote: "What is the complexity?")
        let decoded = try JSONDecoder().decode(CallHostCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(decoded.questionID, command.questionID)
        XCTAssertEqual(decoded.codingEvidence, command.codingEvidence)
    }

    /// The gate withholds private code. An anchor with no code beside it is a
    /// location, not a proposal, and it is what lets a words-only step say
    /// where the explanation lands.
    func testTheGateWithholdsCodeButKeepsAWordsOnlyStepsLocation() {
        var flow = CodingInterviewFlowState(sessionID: "s", generation: 1, sourceRevision: "rev")
        flow.pointers = ["Resolve the reference first", "Then format the value"]

        var proposal = CodingMove(ordinal: 1, sourceRevision: "rev", kind: .edit,
                                  say: "Add the branch",
                                  file: .init(path: "sheet/formula.py", symbol: "_evaluate"),
                                  code: "if node.kind == 'ref':", why: "It is the smallest slice")
        proposal.implementationStage = .simple
        let screened = CodingInterviewPublication.screen(proposal, flow: flow)
        XCTAssertNil(screened.code, "Private code must not reach the reader")
        XCTAssertNil(screened.file, "An anchor beside withheld code points at an unseen edit")
        XCTAssertEqual(screened.kind, .design)

        let pointer = CodingMove(ordinal: 2, sourceRevision: "rev", kind: .design,
                                 say: "Resolve the reference first",
                                 file: .init(path: "sheet/formula.py", symbol: "_evaluate"),
                                 why: "Then format the value", origin: .deterministic)
        let kept = CodingInterviewPublication.screen(pointer, flow: flow)
        XCTAssertNil(kept.code)
        XCTAssertEqual(kept.file?.path, "sheet/formula.py")
        XCTAssertEqual(kept.file?.symbol, "_evaluate")
    }

}
