import CallaContracts
import XCTest
@testable import IntelligenceCore

/// What a reply has to survive now that no schema forces its shape.
final class CodingDialogueRepairTests: XCTestCase {
    private func evidence(_ quote: String, from: Int, to: Int,
                          speaker: CodingSpeaker = .me) -> CodingDialogueEvidence {
        .init(anchor: .init(fromSequence: from, toSequence: to), speaker: speaker, quote: quote)
    }

    private var transcript: [CodingDialogueEvidence] {
        [evidence("I will key a dictionary on the cell reference", from: 1, to: 1),
         evidence("What about a circular reference?", from: 2, to: 2, speaker: .them),
         evidence("I keep a visited set so it stops", from: 3, to: 3)]
    }

    private func repaired(_ json: String) -> [String: Any] {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return CodingDialogueRepair.repair(dialogue: object, transcript: transcript)
    }

    private func decode(_ dialogue: [String: Any],
                        into state: CodingInterviewFlowState) -> CodingDialogueUpdate? {
        var full = dialogue
        full["sessionID"] = state.sessionID
        full["generation"] = state.generation
        full["sourceRevision"] = state.sourceRevision
        full["requirementRevision"] = state.requirementRevision
        full["taskRevision"] = state.taskRevision
        let data = try! JSONSerialization.data(withJSONObject: full)
        return try? JSONDecoder().decode(CodingDialogueUpdate.self, from: data)
    }

    private var state: CodingInterviewFlowState {
        var value = CodingInterviewFlowState(sessionID: "s", generation: 1, sourceRevision: "rev")
        value.transcript = transcript
        return value
    }

    /// The reply that reached the panel as "The reply left out
    /// dialogue.evidence.Index 0.anchor" — three usable pointers thrown away
    /// for one missing field.
    func testTheReplyThatFailedInTheInterviewNowLands() {
        let dialogue = repaired("""
        {"pointers":["Resolve the reference first","Keep a visited set"],
         "discussedSteps":["approach"],
         "evidence":[{"speaker":"me","quote":"I keep a visited set so it stops"}]}
        """)
        let update = decode(dialogue, into: state)
        XCTAssertEqual(update?.pointers, ["Resolve the reference first", "Keep a visited set"])
        XCTAssertEqual(update?.discussedSteps, [.approach])
        // The anchor was recovered from the engine's own transcript, so the
        // citation still passes `apply`'s validity check and the stage moves.
        XCTAssertEqual(update?.evidence?.first?.anchor, .init(fromSequence: 3, toSequence: 3))
        var applied = state
        XCTAssertTrue(CodingInterviewFlow.apply(try! XCTUnwrap(update), to: &applied))
        XCTAssertNotNil(applied.discussed[.approach])
    }

    /// Recovery is a lookup in recorded data, never a guess.
    func testAnUnrecoverableAnchorDropsTheItemAndNothingElse() {
        let dialogue = repaired("""
        {"pointers":["Still useful"],
         "evidence":[{"speaker":"me","quote":"something nobody ever said"},
                     {"speaker":"me","quote":"I keep a visited set so it stops"}]}
        """)
        let update = decode(dialogue, into: state)
        XCTAssertEqual(update?.pointers, ["Still useful"])
        XCTAssertEqual(update?.evidence?.count, 1)
        XCTAssertEqual(update?.evidence?.first?.quote, "I keep a visited set so it stops")
    }

    func testAnAmbiguousQuoteIsNotAnchoredToEitherTurn() {
        let repeated = [evidence("the same words", from: 1, to: 1),
                        evidence("the same words", from: 5, to: 5)]
        XCTAssertNil(CodingDialogueRepair.anchor(forQuote: "the same words", in: repeated))
        XCTAssertNil(CodingDialogueRepair.anchor(forQuote: "", in: transcript))
        XCTAssertEqual(CodingDialogueRepair.anchor(forQuote: "visited set", in: transcript),
                       .init(fromSequence: 3, toSequence: 3))
    }

    /// A fact with no readable citation is what `apply` refuses anyway. Dropping
    /// it here is what stops it taking the pointers down with it.
    func testAnUnciteableFactIsDroppedRatherThanTheWholeReply() {
        let dialogue = repaired("""
        {"pointers":["Keep going"],
         "facts":[{"id":"f1","text":"no citation","kind":"assumption","evidence":[]},
                  {"id":"f2","text":"input can repeat","kind":"interviewerRequirement",
                   "evidence":[{"speaker":"them","quote":"What about a circular reference?"}]}]}
        """)
        let update = decode(dialogue, into: state)
        XCTAssertEqual(update?.facts?.count, 1)
        XCTAssertEqual(update?.facts?.first?.id, "f2")
        XCTAssertEqual(update?.pointers, ["Keep going"])
    }

    /// An unreadable proof makes the item outstanding, not lost.
    func testAMalformedCompletionLeavesThePendingItemOpen() {
        let dialogue = repaired("""
        {"pending":[{"id":"basic","text":"Sum a range","stage":"simple","required":true,
                     "requirementIDs":[],"completedEvidence":{"path":"main.py"}}]}
        """)
        let update = decode(dialogue, into: state)
        XCTAssertEqual(update?.pending?.count, 1)
        XCTAssertNil(update?.pending?.first?.completedEvidence)
    }

    func testAMalformedClarificationIsDroppedWithoutLosingTheRest() {
        let dialogue = repaired("""
        {"pointers":["Ask about duplicates"],
         "clarification":{"question":"Are duplicates allowed?"}}
        """)
        let update = decode(dialogue, into: state)
        XCTAssertNil(update?.clarification)
        XCTAssertEqual(update?.pointers, ["Ask about duplicates"])
    }

    /// A well-formed reply must come through untouched.
    func testACompleteReplyIsNotAltered() {
        let dialogue = repaired("""
        {"pointers":["a"],"limitation":"none",
         "evidence":[{"anchor":{"fromSequence":1,"toSequence":1},
                      "speaker":"me","quote":"I will key a dictionary on the cell reference"}]}
        """)
        let update = decode(dialogue, into: state)
        XCTAssertEqual(update?.evidence?.first?.anchor, .init(fromSequence: 1, toSequence: 1))
        XCTAssertEqual(update?.limitation, "none")
        XCTAssertEqual(update?.pointers, ["a"])
    }
}
