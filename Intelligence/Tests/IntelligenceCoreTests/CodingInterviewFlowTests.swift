import CallaContracts
import XCTest
@testable import IntelligenceCore

final class CodingInterviewFlowTests: XCTestCase {
    private func statement(_ text: String, seq: Int = 1, speaker: Speaker = .remote,
                           truncated: Bool = false) -> Statement {
        Statement(fromSeq: seq, toSeq: seq, speaker: speaker, text: text,
                  span: 2, truncated: truncated)
    }

    private var facts: CodingDirector.Facts {
        .init(cadence: .init(phase: .implementing, hasCode: true))
    }

    func testInterviewerRequestsHaveTheRightShapeEvenWhenBusy() {
        var busy = facts
        busy.requestInFlight = true
        busy.typingBurst = true
        for (text, intent) in [
            ("Can you implement a function for this?", CodingIntent.writeCode),
            ("Run the tests.", .runCommand),
            ("How would you design this cache?", .design),
            ("What about duplicate keys?", .explain),
            ("What's the time complexity?", .explain),
            ("Can we optimize this?", .design)
        ] {
            guard case .ask(let increment, let actual, .urgent) = CodingDirector.decide(
                statement: statement(text), facts: busy) else {
                XCTFail("Lost request: \(text)"); continue
            }
            XCTAssertEqual(actual, intent, text)
            if let preferred = intent.preferredIncrement {
                XCTAssertEqual(increment, preferred, "Intent and step must agree")
                XCTAssertFalse(increment.allowsCode)
            }
        }
    }

    func testFailureReminderCannotSwallowTheRequestToExplainIt() {
        var failed = facts
        failed.lastVerdict = .unsatisfied
        failed.lastCommand = "swift test"
        guard case .ask(_, .explain, _) = CodingDirector.decide(
            statement: statement("Why is this test failing?", speaker: .local), facts: failed)
        else { return XCTFail("Repeated reminder swallowed the actual request") }
    }

    func testDirectLocalRequestSurvivesASaveAndBusyWorker() {
        var busy = facts
        busy.typingBurst = true
        busy.requestInFlight = true
        guard case .ask(_, .runCommand, _) = CodingDirector.decide(
            statement: statement("I need a command to run this.", speaker: .local), facts: busy)
        else { return XCTFail("An intentional request should be queued") }
    }

    func testReportedNegatedAndCompletedWorkDoesNotBecomeAnAction() {
        for text in ["We explained the approach.", "Do not run the tests yet.",
                     "I already run the tests.", "She asked me to implement the parser.",
                     "I don't need to write a function.", "We described the data.",
                     "I'll explain the time complexity now.", "The data structure is a deque."] {
            XCTAssertEqual(CodingIntentClassifier.classify(text), .none, text)
            guard case .silent = CodingDirector.decide(statement: statement(text), facts: facts)
            else { XCTFail("Rejected intent became a question again: \(text)"); continue }
        }
        XCTAssertEqual(CodingIntentClassifier.classify(
            "Don't run the tests; explain the failure instead."), .explain)
        XCTAssertEqual(CodingIntentClassifier.classify("Let’s run the tests."), .runCommand)
    }

    func testCorrectionsAndHintsAreActionableWithoutQuestionMarks() {
        for text in ["Actually, the input can contain negative numbers.",
                     "Assume the input is a stream.", "Do not use sorting.",
                     "Consider a hash map."] {
            guard case .ask(_, .design, .urgent) = CodingDirector.decide(
                statement: statement(text), facts: facts) else {
                XCTFail("Missed interviewer signal: \(text)"); continue
            }
        }
    }

    func testUnclearRequirementGetsClarificationWithoutModelWork() {
        for input in [statement("The limit is 50 [unclear]"),
                      statement("Can you implement this with", truncated: true)] {
            guard case .deterministic(.clarify, _, .urgent) = CodingDirector.decide(
                statement: input, facts: facts) else { return XCTFail("Guessed uncertain intent") }
        }
    }

    func testQueuePreservesIndependentQuestionsAndReportsOverload() {
        var queue = CodingGuidanceQueue(capacity: 2)
        let first = statement("Explain the complexity.")
        let second = statement("Run the tests.", seq: 2)
        XCTAssertEqual(queue.enqueue(first), .accepted)
        XCTAssertEqual(queue.enqueue(first), .duplicate)
        XCTAssertEqual(queue.enqueue(second, context: [first]), .accepted)
        XCTAssertEqual(queue.enqueue(statement("Implement the next case.", seq: 3)), .full)
        XCTAssertEqual(queue.next()?.statement, first)
        let next = queue.next()
        XCTAssertEqual(next?.statement, second)
        XCTAssertEqual(next?.context, [first])
        XCTAssertNil(queue.next())
        _ = queue.enqueue(first)
        queue.reset()
        XCTAssertNil(queue.next())
    }

    func testSpokenCodingRequestDoesNotWaitForSixSecondIdleTimer() {
        var segmenter = StatementSegmenter(rules: .coding)
        _ = segmenter.ingest(.init(seq: 1, speaker: .local, start: 0, end: 2,
                                    text: "I need a command to run this"))
        XCTAssertTrue(segmenter.tick(now: 2.2).isEmpty)
        XCTAssertEqual(segmenter.tick(now: 2.4).first?.toSeq, 1)
    }

    func testQuestionFragmentWaitsForTheConstraintThatFollows() {
        var segmenter = StatementSegmenter(rules: .coding)
        _ = segmenter.ingest(.init(seq: 1, speaker: .remote, start: 0, end: 2,
                                    text: "Can you implement this with"))
        XCTAssertTrue(segmenter.tick(now: 2.4).isEmpty)
        _ = segmenter.ingest(.init(seq: 2, speaker: .remote, start: 2.5, end: 3,
                                    text: "constant space"))
        let result = segmenter.tick(now: 3.4)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.text, "Can you implement this with constant space")
    }

    func testRequirementsSurviveNarrationAndUncertainOnesAreNotPromoted() {
        var ledger = CodingLedger()
        ledger.append(statement("Assume the input is sorted."))
        ledger.append(statement("Actually, it is unsorted.", seq: 2))
        ledger.append(statement("Actually, it is sorted [unclear]", seq: 3))
        for seq in 4...20 {
            ledger.append(statement("I am examining the loop", seq: seq, speaker: .local))
        }
        XCTAssertEqual(ledger.interviewerContext.count, 2)
        XCTAssertTrue(ledger.markdown().contains("Actually, it is unsorted."))
        XCTAssertTrue(ledger.decisions.isEmpty)
    }

    func testFrameKeepsEvidenceBoundedAndDoesNotLeakFutureConversation() {
        let large = String(repeating: "x", count: 20_000)
        let state = CodingWorkspace.State(phase: .implementing, increment: .narrate,
                                          sourceRevision: "abc", syncState: .current,
                                          pendingCommand: large)
        let frame = CodingTurn.frame(
            statement: statement("Why did it fail?", seq: 10), state: state,
            openRubric: (0..<20).map { .init(id: "r\($0)", kind: .rubric, text: large) },
            recentlySaid: [statement(large, seq: 8), statement("FUTURE TURN", seq: 11)],
            intent: .explain,
            brief: InterviewBrief(source: .text, title: large, constraints: [large, large]),
            interviewerContext: [statement("Actually, use constant space.", seq: 9),
                                 statement("FUTURE CONSTRAINT", seq: 12)],
            lastRun: .init(id: "run", command: "test", verdict: .unsatisfied, summary: large))
        XCTAssertTrue(frame.contains("Step: narrate"))
        XCTAssertTrue(frame.contains("Actually, use constant space."))
        XCTAssertTrue(frame.contains("Check evidence [unsatisfied]"))
        XCTAssertTrue(frame.contains("not a result"))
        XCTAssertFalse(frame.contains("FUTURE"))
        XCTAssertLessThan(frame.count, 6_500)
    }
}
