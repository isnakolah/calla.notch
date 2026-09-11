import CallaContracts
import XCTest
@testable import IntelligenceCore

final class CodingTasksTests: XCTestCase {
    /// A move that lands after the moment has passed is worse than none, and a
    /// 120s timeout is not a budget.
    func testTheMoveLaneIsFastAndTightlyBudgeted() {
        XCTAssertEqual(CodingTasks.move.defaultTier, .fast)
        XCTAssertLessThanOrEqual(CodingTasks.move.latencyBudget, 8)
    }

    func testTheThinkingLanesDoNotBlockOnAStatement() {
        XCTAssertEqual(CodingTasks.plan.batching, .manual)
        XCTAssertEqual(CodingTasks.edit.batching, .manual)
        XCTAssertEqual(CodingTasks.move.batching, .statement(.coding))
    }

    /// Sharing a conversation between lanes loses the id between them.
    func testEachLaneGetsItsOwnConversation() {
        let keys = CodingTasks.all.map { CodingTasks.sessionKey("session-1", lane: $0) }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testEveryLaneStaysLocal() {
        for task in CodingTasks.all {
            XCTAssertEqual(task.allowedProviders, [.localAgy], task.id)
        }
    }
}

final class CodingTurnFrameTests: XCTestCase {
    private let state = CodingWorkspace.State(
        phase: .implementing, increment: .skeleton, sourceRevision: "abc",
        syncState: .current, remainingSeconds: 600, pendingCommand: "swift test",
        lastVerdict: .unsatisfied)

    private func statement(_ text: String, _ speaker: Speaker = .local) -> Statement {
        Statement(fromSeq: 1, toSeq: 1, speaker: speaker, text: text, span: 2, truncated: false)
    }

    /// The common case must not need a single file read: the move lane has six
    /// seconds and every read is a round trip.
    func testTheFrameCarriesTheVolatileFactsInline() {
        let frame = CodingTurn.frame(
            statement: statement("okay so now the main loop"),
            state: state,
            openRubric: [CodingRubricState(id: "r0", kind: .rubric,
                                           text: "state the time complexity")],
            recentlySaid: [statement("I'll use a deque", .local)])
        XCTAssertTrue(frame.contains("Step: skeleton"))
        XCTAssertTrue(frame.contains("at most 12 added lines"))
        XCTAssertTrue(frame.contains("Time left: 10 min"))
        XCTAssertTrue(frame.contains("Last check: unsatisfied"))
        XCTAssertTrue(frame.contains("state the time complexity"))
        XCTAssertTrue(frame.contains("Me: okay so now the main loop"))
        XCTAssertTrue(frame.contains("__NO_MOVE__"))
    }

    func testAWordsOnlyStepSaysSoInTheFrame() {
        var words = state
        words.increment = .sketch
        let frame = CodingTurn.frame(statement: statement("hmm"), state: words,
                                     openRubric: [], recentlySaid: [])
        XCTAssertTrue(frame.contains("words only, no code"))
    }

    /// An hour of interview must not become an hour of prompt.
    func testTheFrameStaysSmall() {
        let many = (0 ..< 50).map { statement("statement number \($0) with some words in it") }
        let frame = CodingTurn.frame(statement: statement("and now?"), state: state,
                                     openRubric: (0 ..< 20).map {
                                         CodingRubricState(id: "r\($0)", kind: .rubric,
                                                           text: "rubric item \($0)")
                                     },
                                     recentlySaid: many)
        XCTAssertLessThan(frame.count, 1_400, "frame grew to \(frame.count) characters")
    }
}

final class CodingTurnPublishTests: XCTestCase {
    private func publish(_ draft: CodingMoveDraft, increment: CodingIncrement = .fillOne,
                         evidence: CodingClaimGuard.Evidence = .init())
        -> CodingTurn.Publication {
        CodingTurn.publish(draft: draft, increment: increment, ordinal: 2,
                           sourceRevision: "abc", anchor: nil, priority: .advisory,
                           rubricIDs: [], confidence: 70, evidence: evidence)
    }

    /// Silence has to be expressible, or every request produces a move.
    func testTheSentinelIsHonoured() {
        let result = publish(CodingMoveDraft(say: "__NO_MOVE__"))
        guard case .noMove = result else { return XCTFail("\(result)") }
    }

    func testAnEmptyDraftIsSilenceNotAnEmptyPanel() {
        let result = publish(CodingMoveDraft(say: "   "))
        guard case .noMove = result else { return XCTFail("\(result)") }
    }

    /// A declined turn must not be resurrected by the repair path.
    func testTheSentinelWinsEvenWhenOtherFieldsAreSet() {
        let result = publish(CodingMoveDraft(say: "__NO_MOVE__", code: "+something"))
        guard case .noMove = result else { return XCTFail("\(result)") }
    }

    func testAGoodDraftBecomesAModelMoveWithItsConfidence() {
        let result = publish(CodingMoveDraft(
            kind: .implementation, say: "I'll stub the signature first.",
            why: "Get the shape agreed before the body."))
        guard case .move(let move, let problems) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(move.origin, .model)
        XCTAssertEqual(move.confidence, 70)
        XCTAssertEqual(move.say, "I'll stub the signature first.")
        XCTAssertTrue(problems.isEmpty)
    }

    /// Everything screened away is silence, not a blank move.
    func testAMoveStrippedOfEverythingIsNotPublished() {
        let result = publish(CodingMoveDraft(code: "+one\n+two"), increment: .sketch)
        guard case .noMove = result else { return XCTFail("\(result)") }
    }

    func testTheIncrementSuppliesTheKindWhenTheDraftOmitsIt() {
        let result = publish(CodingMoveDraft(say: "Let me name the approach first."),
                             increment: .sketch)
        guard case .move(let move, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(move.kind, .design)
    }

    func testADeterministicMoveIsMarkedAsAFactAndCarriesNoConfidence() {
        let move = CodingTurn.deterministic(
            say: "9 minutes left and nothing has passed yet.",
            increment: .verify, ordinal: 3, sourceRevision: "abc", priority: .urgent)
        XCTAssertEqual(move.origin, .deterministic)
        XCTAssertNil(move.confidence)
        XCTAssertEqual(move.priority, .urgent)
    }
}
