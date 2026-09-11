import CallaContracts
@testable import IntelligenceCore
import XCTest

/// The rule under test is "can the outstanding voters still change this".
/// Returning nil means keep waiting; anything else means cancel the stragglers.
final class QuizCouncilTests: XCTestCase {
    private func vote(_ answer: String, _ confidence: Int = 90) -> QuizVoteSlot {
        .returned(QuizWorkerOutput(answer: answer, confidence: confidence))
    }

    private func sentinel(_ value: QuizWorkerSentinel) -> QuizVoteSlot {
        .returned(QuizWorkerOutput(answer: value.rawValue, confidence: 0))
    }

    private func decide(_ slots: [QuizVoteSlot], kind: QuizQuestionKind = .singleChoice,
                        strategy: QuizAnswerStrategy = .unanimous,
                        hasArbiter: Bool = true) -> QuizEnsembleDecision? {
        QuizCouncil.earlyDecision(slots: slots, kind: kind, strategy: strategy,
                                  hasArbiter: hasArbiter)
    }

    // MARK: - Unanimous

    func testUnanimousWaitsWhileAgreementIsStillPossible() {
        XCTAssertNil(decide([vote("B"), .pending, .pending]))
        XCTAssertNil(decide([vote("B"), vote("B"), .pending]))
    }

    func testUnanimousSettlesTheMomentTwoVotersDisagree() {
        // The third voter cannot make three agree, so waiting for it is pure
        // dead time. This is the case that used to cost max(N) every time.
        XCTAssertEqual(decide([vote("B"), vote("C"), .pending]), .arbitrate)
    }

    func testUnanimousSettlesTheMomentAVoterFails() {
        // A failure makes "all three agree" unreachable just as surely as a
        // disagreement does.
        XCTAssertEqual(decide([vote("B"), .failed, .pending]), .arbitrate)
    }

    func testUnanimousPublishesWhenEveryVoterAgrees() {
        XCTAssertEqual(decide([vote("B", 94), vote("B", 88), vote("B", 91)]),
                       .publish(answer: "B", confidence: 88))
    }

    func testUnanimousAcceptsDifferentlyFormattedButIdenticalAnswers() {
        XCTAssertEqual(decide([vote("B) Paris", 94), vote("B — Paris", 90), vote("B", 92)]),
                       .publish(answer: "B) Paris", confidence: 90))
    }

    // MARK: - Majority

    func testMajorityPublishesWithoutWaitingForTheLastVoter() {
        XCTAssertEqual(decide([vote("B", 95), vote("B", 91), .pending], strategy: .majority),
                       .publish(answer: "B", confidence: 91))
    }

    func testMajorityWaitsWhileItIsStillReachable() {
        XCTAssertNil(decide([vote("B"), .pending, .pending], strategy: .majority))
    }

    func testMajoritySettlesOnceNoAnswerCanReachTheThreshold() {
        // Three voters, three different answers: two can never agree.
        XCTAssertEqual(decide([vote("A"), vote("B"), vote("C")], strategy: .majority), .arbitrate)
        // Two failures out of three leaves one vote, short of the two needed.
        XCTAssertEqual(decide([vote("A"), .failed, .failed], strategy: .majority), .arbitrate)
    }

    // MARK: - First

    func testFirstPublishesOnTheFirstAnswerBack() {
        XCTAssertEqual(decide([vote("B", 77), .pending, .pending], strategy: .first),
                       .publish(answer: "B", confidence: 77))
    }

    func testFirstIgnoresASentinelAndKeepsWaiting() {
        // A sentinel is not an answer, so it cannot be the first answer back.
        XCTAssertNil(decide([sentinel(.needsScrollDown), .pending, .pending], strategy: .first))
    }

    func testFirstOnASingleVoterPublishesImmediately() {
        XCTAssertEqual(decide([vote("B", 80)], strategy: .first, hasArbiter: false),
                       .publish(answer: "B", confidence: 80))
    }

    // MARK: - Council size

    func testASingleVoterCanPublishUnderUnanimity() {
        // With one voter, unanimity is just that voter. This could not happen
        // before: `decide` required exactly three valid votes to publish at all.
        XCTAssertEqual(decide([vote("B", 85)], hasArbiter: false),
                       .publish(answer: "B", confidence: 85))
    }

    func testASingleVoterThatFailsHasNothingLeftToWaitFor() {
        XCTAssertEqual(decide([.failed], hasArbiter: false), .arbitrate)
    }

    func testALargeCouncilStillSettlesEarly() {
        let slots: [QuizVoteSlot] = [vote("A"), vote("B")] + Array(repeating: .pending, count: 5)
        // Unanimity is already lost at two disagreeing, whatever the other five say.
        XCTAssertEqual(decide(slots), .arbitrate)
        // Majority of seven is four, still reachable from one vote plus five pending.
        XCTAssertNil(decide([vote("A")] + Array(repeating: .pending, count: 6),
                            strategy: .majority))
    }

    // MARK: - Sentinels

    func testSentinelThresholdIsAMajorityAndUnchangedAtThree() {
        XCTAssertEqual(QuizCouncil.sentinelThreshold(of: 1), 1)
        XCTAssertEqual(QuizCouncil.sentinelThreshold(of: 3), 2)
        XCTAssertEqual(QuizCouncil.sentinelThreshold(of: 7), 4)
    }

    func testALoneVoterAskingToScrollIsHeard() {
        // The old fixed threshold of two made this unreachable for one voter.
        XCTAssertEqual(decide([sentinel(.needsScrollUp)], hasArbiter: false),
                       .scroll(.needsScrollUp))
    }

    func testTwoOfThreeSentinelsStillWin() {
        XCTAssertEqual(decide([sentinel(.notAQuestion), sentinel(.notAQuestion), .pending]),
                       .notAQuestion)
    }

    // MARK: - Kinds the voters cannot settle

    func testASubjectiveKindWaitsForItsVotesBeforeArbitrating() {
        // The votes cannot publish a `.text` answer, but they do cap the
        // arbiter's confidence, so cancelling them the moment one lands would
        // buy a little time and cost the number that tells the reader how much
        // to trust the answer.
        XCTAssertNil(decide([vote("x"), .pending, .pending], kind: .text))
        XCTAssertEqual(decide([vote("x"), vote("y"), vote("z")], kind: .text), .arbitrate)
    }

    /// The rule that makes a written or code answer fast: no agreement to check,
    /// so no arbiter round.
    func testFirstPublishesAWrittenAnswerWithoutAnArbiter() {
        XCTAssertEqual(
            decide([vote("def solve(nums): return 1", 88), .pending, .pending],
                   kind: .code, strategy: .first, hasArbiter: false),
            .publish(answer: "def solve(nums): return 1", confidence: 88))
    }

    func testASubjectiveKindWithNoArbiterWaitsForItsVotesFirst() {
        // Without an arbiter the votes are all there is; they are still recorded,
        // and the caller reports that the council could not agree.
        XCTAssertNil(decide([.pending, .pending], kind: .code, hasArbiter: false))
        XCTAssertEqual(decide([vote("x"), vote("y")], kind: .code, hasArbiter: false), .arbitrate)
    }

    func testCalibrationCapsThePublishedConfidence() {
        let calibration = QuizCalibrationBuilder.build(
            from: (0 ..< 30).map {
                QuizCalibrationSample(kind: .singleChoice, displayedConfidence: 95,
                                      correct: $0 < 21)
            })
        let decision = QuizCouncil.earlyDecision(
            slots: [vote("B", 95), vote("B", 95), vote("B", 95)], kind: .singleChoice,
            strategy: .unanimous, hasArbiter: true, calibration: calibration)
        XCTAssertEqual(decision, .publish(answer: "B", confidence: 70))
    }
}
