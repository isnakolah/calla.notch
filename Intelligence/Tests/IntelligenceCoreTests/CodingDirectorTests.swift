import CallaContracts
import XCTest
@testable import IntelligenceCore

/// "Should I speak now" is the highest-leverage decision in the mode. Today it
/// does not exist — every transcript turn spends a model request, including the
/// interviewer saying "mm-hmm".
final class CodingDirectorTests: XCTestCase {

    private func statement(_ text: String, _ speaker: Speaker = .local) -> Statement {
        Statement(fromSeq: 1, toSeq: 2, speaker: speaker, text: text,
                  span: 3, truncated: false)
    }

    private func facts(phase: CodingPhase = .implementing, code: Bool = true,
                       passing: Bool = false, pending: Bool = false,
                       remaining: Int? = nil, verdict: CodingVerdict? = nil,
                       command: String? = nil, inFlight: Bool = false,
                       typing: Bool = false,
                       open: [CodingRubricState] = []) -> CodingDirector.Facts {
        CodingDirector.Facts(
            cadence: CodingCadenceFacts(phase: phase, hasCode: code,
                                        hasPassingRun: passing, hasPendingRun: pending),
            openRubric: open, remainingSeconds: remaining, lastVerdict: verdict,
            lastCommand: command, requestInFlight: inFlight, typingBurst: typing)
    }

    private func isSilent(_ decision: CodingDirector.Decision) -> Bool {
        if case .silent = decision { return true }
        return false
    }

    // MARK: - Silence is the default

    /// This is the whole point of the mode: a fluent candidate is left alone.
    func testFluentNarrationSpendsNothing() {
        let decision = CodingDirector.decide(
            statement: statement("so I'll keep a deque of indices as I scan across"),
            facts: facts())
        XCTAssertTrue(isSilent(decision), "\(decision)")
    }

    /// The bug this replaces: nodding occupied the worker so a real question
    /// queued behind it.
    func testTheInterviewerNoddingAlongSpendsNothing() {
        let decision = CodingDirector.decide(
            statement: statement("mm-hmm, right, yeah that makes sense", .remote),
            facts: facts())
        XCTAssertTrue(isSilent(decision), "\(decision)")
    }

    /// The sterile cockpit rule: the panel must not change under someone's
    /// hands mid-keystroke.
    func testNothingIsPublishedWhileTheCandidateIsTyping() {
        let decision = CodingDirector.decide(
            statement: statement("I'm not sure how to handle that"),
            facts: facts(typing: true))
        XCTAssertTrue(isSilent(decision), "\(decision)")
    }

    func testOneTurnAtATime() {
        let decision = CodingDirector.decide(
            statement: statement("hmm, that's not right"),
            facts: facts(inFlight: true))
        XCTAssertTrue(isSilent(decision), "\(decision)")
    }

    // MARK: - When it does speak

    func testAnInterviewerQuestionIsAlwaysWorthARequest() {
        let decision = CodingDirector.decide(
            statement: statement("what's the time complexity of that?", .remote),
            facts: facts())
        guard case .ask(_, _, let priority) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(priority, .urgent)
    }

    /// An interviewer's most demanding prompts are imperatives, not questions.
    func testAnInterviewerImperativeCountsAsAQuestion() {
        let decision = CodingDirector.decide(
            statement: statement("walk me through what happens on an empty list", .remote),
            facts: facts())
        guard case .ask = decision else { return XCTFail("\(decision)") }
    }

    func testACandidateTrailingOffGetsHelp() {
        let decision = CodingDirector.decide(
            statement: statement("wait, why is that returning nil"),
            facts: facts())
        guard case .ask(_, _, let priority) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(priority, .advisory)
    }

    // MARK: - Facts never wait for a model

    /// Tutor's rule, applied here: a deterministic fact never waits for a model.
    func testAFailingCheckIsPublishedImmediatelyWithoutARequest() {
        let decision = CodingDirector.decide(
            statement: statement("okay so that should work now"),
            facts: facts(verdict: .unsatisfied, command: "swift test"))
        guard case .deterministic(_, let say, let priority) = decision else {
            return XCTFail("\(decision)")
        }
        XCTAssertEqual(priority, .urgent)
        XCTAssertTrue(say.contains("swift test"))
    }

    func testTheClockRunningOutWithNothingPassingIsUrgent() {
        let decision = CodingDirector.decide(
            statement: statement("let me just tidy this up a bit"),
            facts: facts(passing: false, remaining: 240))
        guard case .deterministic(let increment, let say, let priority) = decision else {
            return XCTFail("\(decision)")
        }
        XCTAssertEqual(increment, .verify)
        XCTAssertEqual(priority, .urgent)
        XCTAssertTrue(say.contains("4 minutes"))
    }

    func testAnUncoveredRubricItemIsRaisedBeforeTimeRunsOut() {
        let open = [CodingRubricState(id: "rubric-0", kind: .rubric,
                                      text: "state the time complexity", status: .open)]
        let decision = CodingDirector.decide(
            statement: statement("okay I think that's basically it"),
            facts: facts(passing: true, remaining: 540, open: open))
        guard case .deterministic(_, let say, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertTrue(say.contains("state the time complexity"))
    }

    /// Facts outrank conversation, but only real ones — a healthy session with
    /// plenty of clock says nothing.
    func testAHealthySessionWithTimeLeftStaysQuiet() {
        let decision = CodingDirector.decide(
            statement: statement("now I'll add the second branch for the empty case"),
            facts: facts(passing: true, remaining: 1_500))
        XCTAssertTrue(isSilent(decision), "\(decision)")
    }
}

final class CodingLedgerTests: XCTestCase {
    func testDecisionsAreAppendedNotRewritten() {
        var ledger = CodingLedger()
        ledger.decide("use a deque of indices")
        ledger.decide("skip input validation, brief deprioritised it")
        XCTAssertEqual(ledger.decisions.count, 2)
        XCTAssertEqual(ledger.decisions.first, "use a deque of indices")
    }

    func testARepeatedDecisionIsNotRecordedTwice() {
        var ledger = CodingLedger()
        ledger.decide("use a deque of indices")
        ledger.decide("use a deque of indices")
        XCTAssertEqual(ledger.decisions.count, 1)
    }

    /// An hour of interview must not become an hour of prompt.
    func testTheAccountStaysBoundedOverALongInterview() {
        var ledger = CodingLedger()
        for index in 0 ..< 200 {
            ledger.append(Statement(fromSeq: index, toSeq: index, speaker: .local,
                                    text: "statement \(index)", span: 2, truncated: false))
            ledger.decide("decision \(index)")
        }
        XCTAssertLessThanOrEqual(ledger.tail.count, ledger.maximumTail)
        XCTAssertLessThanOrEqual(ledger.decisions.count, ledger.maximumDecisions)
        XCTAssertLessThanOrEqual(ledger.markdown().count, 4_000)
    }

    /// Folding must not silently drop everything it folded.
    func testFoldedDecisionsSurviveInStanding() {
        var ledger = CodingLedger()
        for index in 0 ..< 20 { ledger.decide("decision \(index)") }
        XCTAssertTrue(ledger.standing.contains("decision 0"))
    }

    func testRunsAreDeduplicatedByIdentity() {
        var ledger = CodingLedger()
        ledger.record(.init(id: "r1", command: "swift test", verdict: .unsatisfied, summary: "boom"))
        ledger.record(.init(id: "r1", command: "swift test", verdict: .satisfied, summary: "ok"))
        XCTAssertEqual(ledger.runs.count, 1)
        XCTAssertEqual(ledger.runs.first?.verdict, .satisfied)
    }
}

/// Intent routing, pinned against the real session that exposed the gap.
///
/// Every line here is a verbatim statement from a recorded Live Coding session
/// in which the director said nothing at all.
final class CodingIntentTests: XCTestCase {

    func testTheRequestsThatWereSilentlyDropped() {
        XCTAssertEqual(CodingIntentClassifier.classify(
            "So the first order of business, I will start by running this application. "
            + "So I need to get a command to run this application."), .runCommand)
        XCTAssertEqual(CodingIntentClassifier.classify(
            "Yeah, I should be running a command to... I have to start this up, so... "
            + "Let me check for the command..."), .runCommand)
        XCTAssertEqual(CodingIntentClassifier.classify(
            "build a... to extend this and implement the sum function. So... "
            + "Yeah, let's start with the implementation of the sum function."), .writeCode)
    }

    func testAskingToUnderstandIsNotAskingForCode() {
        XCTAssertEqual(CodingIntentClassifier.classify("wait, why is this returning nil"), .explain)
        XCTAssertEqual(CodingIntentClassifier.classify("what's the best way to store these"), .design)
    }

    /// The guard against the opposite failure: ordinary narration must stay
    /// silent, or the panel churns through advice nobody asked for.
    func testNarrationCarriesNoIntent() {
        for line in ["so I'll keep a deque of indices as I scan across",
                     "okay, that looks right",
                     "yeah, exactly, that's what I was thinking",
                     "right, so this is the part that tracks the window"] {
            XCTAssertEqual(CodingIntentClassifier.classify(line), .none, line)
        }
    }

    func testAnIntentTurnsAStatementIntoARequest() {
        let statement = Statement(fromSeq: 1, toSeq: 2, speaker: .local,
                                  text: "So I need to get a command to run this application.",
                                  span: 6, truncated: false)
        let facts = CodingDirector.Facts(
            cadence: CodingCadenceFacts(phase: .implementing, hasCode: true))
        guard case .ask(_, let intent, let priority) =
                CodingDirector.decide(statement: statement, facts: facts) else {
            return XCTFail("a direct request was treated as fluent narration")
        }
        XCTAssertEqual(intent, .runCommand)
        XCTAssertEqual(priority, .urgent)
    }

    /// Wanting code does not license handing over a finished function.
    func testIntentNeverOverridesThePacingLadder() {
        let statement = Statement(fromSeq: 1, toSeq: 1, speaker: .local,
                                  text: "let me implement the whole thing now",
                                  span: 4, truncated: false)
        let facts = CodingDirector.Facts(
            cadence: CodingCadenceFacts(phase: .implementing, hasCode: false))
        guard case .ask(let increment, _, _) =
                CodingDirector.decide(statement: statement, facts: facts) else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(increment, .skeleton, "an empty file still gets a skeleton first")
    }
}
