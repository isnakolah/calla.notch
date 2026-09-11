import CallaContracts
import XCTest
@testable import IntelligenceCore

final class CodingPhaseMachineTests: XCTestCase {
    func testPhaseStartsAtUnderstandingAndReachesDesigningOnApproachTalk() {
        var machine = CodingPhaseMachine()
        XCTAssertEqual(machine.phase, .understanding)
        machine.advance(.init(discussedApproach: true))
        XCTAssertEqual(machine.phase, .designing)
    }

    func testFirstCodeMovesToImplementing() {
        var machine = CodingPhaseMachine()
        machine.advance(.init(addedLines: 3, discussedApproach: true))
        XCTAssertEqual(machine.phase, .implementing)
    }

    /// A question late in the interview must not drag the copilot back to
    /// asking what the problem is.
    func testPhaseDoesNotWalkBackwards() {
        var machine = CodingPhaseMachine()
        machine.advance(.init(addedLines: 10))
        XCTAssertEqual(machine.phase, .implementing)
        machine.advance(.init(addedLines: 0))
        XCTAssertEqual(machine.phase, .implementing)
    }

    /// Except here: red output after green is real, and pretending otherwise
    /// keeps offering optimisations over a failing check.
    func testAFailingCheckAfterAPassingOneReturnsToDebugging() {
        var machine = CodingPhaseMachine()
        machine.advance(.init(addedLines: 5, lastVerdict: .satisfied))
        XCTAssertEqual(machine.phase, .verifying)
        machine.advance(.init(addedLines: 5, lastVerdict: .unsatisfied))
        XCTAssertEqual(machine.phase, .debugging)
    }

    func testTheClockForcesWrappingUp() {
        var machine = CodingPhaseMachine()
        machine.advance(.init(addedLines: 2, elapsedFraction: 0.85))
        XCTAssertEqual(machine.phase, .wrappingUp)
    }
}

final class CodingRunVerdictTests: XCTestCase {
    private func run(_ lifecycle: CodingRunLifecycle, output: String = "",
                     truncated: Bool = false) -> CodingRun {
        CodingRun(id: "run-1", relativeCWD: ".", displayedCommand: "swift test",
                  lifecycle: lifecycle, outputSummary: output,
                  outputTruncated: truncated, evidenceRevision: "abc")
    }

    func testGreenExitWithMatchingEvidenceIsSatisfied() {
        let verdict = CodingRunVerdictJudge.judge(
            run: run(.passed, output: "Executed 12 tests, all Swift tests pass"),
            expected: "All Swift tests pass")
        XCTAssertEqual(verdict, .satisfied)
    }

    /// A runner that skipped everything exits 0. That is not proof.
    func testGreenExitWithoutTheExpectedEvidenceIsUnknownNotSatisfied() {
        let verdict = CodingRunVerdictJudge.judge(
            run: run(.passed, output: "No tests were run."),
            expected: "All Swift tests pass")
        XCTAssertEqual(verdict, .unknown)
    }

    func testNoExpectedEvidenceFallsBackToTheExitCode() {
        XCTAssertEqual(CodingRunVerdictJudge.judge(run: run(.passed, output: "ok"), expected: nil),
                       .satisfied)
        XCTAssertEqual(CodingRunVerdictJudge.judge(run: run(.failed, output: "boom"), expected: nil),
                       .unsatisfied)
    }

    /// Sending a candidate to debug their code because the sandbox died is the
    /// worst possible false signal.
    func testEnvironmentFailureAndTimeoutAreUnknown() {
        XCTAssertEqual(CodingRunVerdictJudge.judge(run: run(.environmentFailure), expected: nil),
                       .unknown)
        XCTAssertEqual(CodingRunVerdictJudge.judge(run: run(.timedOut), expected: nil), .unknown)
        XCTAssertEqual(CodingRunVerdictJudge.judge(run: run(.cancelled), expected: nil), .unknown)
    }

    func testTruncatedOutputWithoutAMatchIsUnknown() {
        let verdict = CodingRunVerdictJudge.judge(
            run: run(.failed, output: "a very long tail", truncated: true),
            expected: "All Swift tests pass")
        XCTAssertEqual(verdict, .unknown)
    }
}

final class CodingRubricTrackerTests: XCTestCase {
    private let brief = InterviewBrief(
        source: .text, title: "Sliding window maximum",
        rubric: ["state the time complexity", "explain the deque invariant"],
        constraints: ["no external libraries"],
        depriorities: ["input validation"])

    func testSayingSomethingCoversTheMatchingItemOnly() {
        var tracker = CodingRubricTracker(brief: brief)
        tracker.noteSpoken("so the time complexity here is linear, O of n")
        let complexity = tracker.states.first { $0.id == "rubric-0" }
        let invariant = tracker.states.first { $0.id == "rubric-1" }
        XCTAssertEqual(complexity?.status, .spoken)
        XCTAssertEqual(invariant?.status, .open)
    }

    /// A false "covered" silently removes the nudge that would have made the
    /// candidate say it. Passing chatter must not clear an item.
    func testIncidentalChatterDoesNotCoverAnything() {
        var tracker = CodingRubricTracker(brief: brief)
        tracker.noteSpoken("right, okay, let me think about that for a second")
        XCTAssertTrue(tracker.states.allSatisfy { $0.status == .open })
    }

    func testTheBriefsDeprioritisedItemsAreNeverNagged() {
        let tracker = CodingRubricTracker(brief: brief)
        XCTAssertFalse(tracker.open.contains { $0.kind == .deprioritised })
    }

    func testConstraintsAreRaisedBeforeRubricNiceties() {
        let tracker = CodingRubricTracker(brief: brief)
        XCTAssertEqual(tracker.open.first?.kind, .constraint)
    }

    func testCoverageIsMonotonic() {
        var tracker = CodingRubricTracker(brief: brief)
        tracker.noteSpoken("the time complexity is linear")
        tracker.noteSpoken("anyway, forget that")
        XCTAssertEqual(tracker.states.first { $0.id == "rubric-0" }?.status, .spoken)
    }

    func testOnlyASatisfiedVerdictVerifies() {
        var tracker = CodingRubricTracker(brief: brief)
        tracker.noteSpoken("the time complexity is linear")
        tracker.noteVerified(expected: nil, verdict: .unsatisfied, runID: "run-1")
        XCTAssertEqual(tracker.states.first { $0.id == "rubric-0" }?.status, .spoken)
        tracker.noteVerified(expected: nil, verdict: .satisfied, runID: "run-1")
        XCTAssertEqual(tracker.states.first { $0.id == "rubric-0" }?.status, .verified)
    }
}

final class CodingClaimGuardTests: XCTestCase {
    private func move(say: String? = nil, path: String? = nil, code: String? = nil,
                      command: String? = nil) -> CodingMove {
        CodingMove(ordinal: 1, sourceRevision: "abc", kind: .implementation, say: say,
                   file: path.map { CodingFileAnchor(path: $0) }, code: code,
                   check: command.map { CodingRunPlan(displayedCommand: $0) })
    }

    /// Tabbing to a file that does not exist, in front of the interviewer.
    func testAFileAnchorThatIsNotInTheTreeIsDropped() {
        let evidence = CodingClaimGuard.Evidence(knownPaths: ["Sources/solve.py"])
        let outcome = CodingClaimGuard.screen(move(path: "src/Solution.java"),
                                              increment: .fillOne, evidence: evidence)
        XCTAssertNil(outcome.move.file)
        XCTAssertEqual(outcome.problems, [.unknownPath("src/Solution.java")])
    }

    func testAKnownPathSurvives() {
        let evidence = CodingClaimGuard.Evidence(knownPaths: ["Sources/solve.py"])
        let outcome = CodingClaimGuard.screen(move(path: "Sources/solve.py"),
                                              increment: .fillOne, evidence: evidence)
        XCTAssertEqual(outcome.move.file?.path, "Sources/solve.py")
        XCTAssertTrue(outcome.isClean)
    }

    func testACheckWithNoRunnerIsDropped() {
        let evidence = CodingClaimGuard.Evidence(runnableCommands: ["swift test"])
        let outcome = CodingClaimGuard.screen(move(command: "npm test"),
                                              increment: .fillOne, evidence: evidence)
        XCTAssertNil(outcome.move.check)
        XCTAssertEqual(outcome.problems, [.unrunnableCheck("npm test")])
    }

    /// The pacing rule, enforced rather than requested.
    func testAWholeSolutionIsCutBackAndTheCandidateIsTold() {
        var body = ["diff --git a/s.py b/s.py", "--- a/s.py", "+++ b/s.py",
                    "@@ -1,1 +1,30 @@", " def solve():"]
        body += (0 ..< 30).map { "+    step\($0)()" }
        let outcome = CodingClaimGuard.screen(move(code: body.joined(separator: "\n")),
                                              increment: .fillOne,
                                              evidence: .init())
        XCTAssertEqual(outcome.problems,
                       [.oversizeIncrement(added: 30,
                                           allowed: CodingIncrement.fillOne.maximumAddedLines)])
        XCTAssertTrue(outcome.withheldCode)
        XCTAssertNotNil(outcome.move.watch)
    }

    func testCodeOnAWordsOnlyIncrementIsRemoved() {
        let outcome = CodingClaimGuard.screen(move(code: "+one\n+two"),
                                              increment: .sketch, evidence: .init())
        XCTAssertNil(outcome.move.code)
        XCTAssertEqual(outcome.problems, [.codeOnAWordsOnlyIncrement])
    }

    func testASymbolNobodyWroteIsFlagged() {
        var evidence = CodingClaimGuard.Evidence()
        evidence.learn(text: "def solve(nums, k): pass")
        let outcome = CodingClaimGuard.screen(move(say: "Now call `rebalanceHeap` on it"),
                                              increment: .fillOne, evidence: evidence)
        XCTAssertEqual(outcome.problems, [.inventedSymbol("rebalanceheap")])
    }

    /// A guard nobody can satisfy gets removed, so ordinary prose must pass.
    func testOrdinaryProseIsNotTreatedAsAClaim() {
        var evidence = CodingClaimGuard.Evidence()
        evidence.learn(text: "def solve(nums, k): pass")
        let outcome = CodingClaimGuard.screen(
            move(say: "Let me start with the signature and fill the body in after."),
            increment: .fillOne, evidence: evidence)
        XCTAssertTrue(outcome.isClean, "\(outcome.problems)")
    }
}
