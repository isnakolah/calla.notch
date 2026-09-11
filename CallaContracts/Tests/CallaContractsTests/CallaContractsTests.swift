import XCTest
@testable import CallaContracts

final class CallaContractsTests: XCTestCase {
    func testRejectsStaleHostEvents() {
        let current = CallLifecycleSnapshot(callID: "call-a", generation: 3, state: .capturing)
        let stale = CallHostEvent(callID: "call-a", generation: 2, kind: .finished,
            snapshot: .init(callID: "call-a", generation: 2, state: .finished))
        XCTAssertFalse(current.accepts(stale))
    }

    func testQueueKeepsIndependentQuestionsAndOnlySupersedesContinuation() {
        var queue = CallQuestionQueue()
        let first = CallQuestion(fromSeq: 1, toSeq: 1, prompt: "First?", kind: .direct, confidence: 0.9)
        let second = CallQuestion(fromSeq: 2, toSeq: 2, prompt: "Second?", kind: .direct, confidence: 0.9)
        queue.enqueue(first); queue.enqueue(second)
        XCTAssertEqual(queue.beginNext()?.id, first.id)
        queue.answer(first.id, answerID: "a1")
        XCTAssertEqual(queue.beginNext()?.id, second.id)
        let third = CallQuestion(fromSeq: 3, toSeq: 3, prompt: "Third?", kind: .direct, confidence: 0.9)
        let continuation = CallQuestion(fromSeq: 4, toSeq: 4, prompt: "And timing?", kind: .direct, confidence: 0.9)
        queue.enqueue(third)
        queue.enqueue(continuation, continuing: true)
        XCTAssertEqual(queue.questions[1].state, .answering)
        XCTAssertEqual(queue.questions[2].state, .superseded)
        XCTAssertEqual(queue.questions[3].state, .queued)
    }

    func testSummaryRulesPrioritizeAnswersAndUseDeterministicTriggers() {
        let now = Date(timeIntervalSince1970: 100)
        var trigger = CallSummaryTrigger(now: now)
        trigger.recordStatement(at: now)
        // Mid-sentence: a statement and its continuation a beat apart are one
        // turn, and closing between them puts half a thought in the account.
        XCTAssertFalse(trigger.isDue(now: now.addingTimeInterval(1), commitmentOrDecision: false, answerInFlight: false))
        trigger.recordStatement(at: now); trigger.recordStatement(at: now)
        XCTAssertTrue(trigger.isDue(now: now, commitmentOrDecision: false, answerInFlight: false))
        XCTAssertFalse(trigger.isDue(now: now, commitmentOrDecision: true, answerInFlight: true))
    }

    /// The rule that makes the account keep pace: one turn, a short pause, done.
    /// It used to take three statements or twenty seconds of silence.
    func testOneTurnIsSummarisedOnceItHasSettled() {
        let now = Date(timeIntervalSince1970: 100)
        var trigger = CallSummaryTrigger(now: now)
        trigger.recordStatement(at: now)
        XCTAssertFalse(trigger.isDue(now: now.addingTimeInterval(CallSummaryTrigger.settleInterval - 0.5),
                                     commitmentOrDecision: false, answerInFlight: false))
        XCTAssertTrue(trigger.isDue(now: now.addingTimeInterval(CallSummaryTrigger.settleInterval),
                                    commitmentOrDecision: false, answerInFlight: false))
    }

    /// Nothing is due when nothing has been said, however long it has been.
    func testSilenceAloneNeverTriggersASummary() {
        let now = Date(timeIntervalSince1970: 100)
        let trigger = CallSummaryTrigger(now: now)
        XCTAssertFalse(trigger.isDue(now: now.addingTimeInterval(600),
                                     commitmentOrDecision: false, answerInFlight: false))
    }

    func testV3AnswerClampsShapeAndRejectsDuplicateCitations() {
        let answer = CallAnswer(
            callID: "call-a", generation: 4, questionID: UUID(), question: "What changed?",
            main: (1 ... 30).map(String.init).joined(separator: " "),
            points: [
                (1 ... 14).map(String.init).joined(separator: " "), "second", "third", "fourth"
            ], warning: (1 ... 30).map(String.init).joined(separator: " "),
            grounding: .callPack,
            citations: [
                .init(id: "p1", kind: .document, label: "brief.pdf", page: 2),
                .init(id: "p1", kind: .document, label: "duplicate", page: 9),
                .init(id: "", kind: .note, label: "invalid")
            ], provider: "Agy", model: "gemini")

        XCTAssertEqual(answer.main.split(separator: " ").count, 24)
        XCTAssertEqual(answer.points.count, 3)
        XCTAssertEqual(answer.points[0].split(separator: " ").count, 10)
        XCTAssertEqual(answer.warning?.split(separator: " ").count, 24)
        XCTAssertEqual(answer.citations.map(\.id), ["p1"])
    }

    func testNeedsConfirmationCanBeEditedThenQueued() {
        var queue = CallQuestionQueue()
        let question = CallQuestion(fromSeq: 8, toSeq: 8, prompt: "unclear words",
                                    kind: .direct, confidence: 0.42,
                                    state: .needsConfirmation)
        queue.enqueue(question)
        XCTAssertNil(queue.beginNext())
        queue.confirm(question.id, editedPrompt: "What is renewal date?")
        XCTAssertEqual(queue.beginNext()?.prompt, "What is renewal date?")
    }

    func testTypedEventRejectsWrongGenerationAtLifecycleBoundary() {
        let snapshot = CallLifecycleSnapshot(callID: "call-a", generation: 7, state: .capturing)
        let answer = CallAnswer(callID: "call-a", generation: 6, questionID: UUID(),
                                question: "When?", main: "Not found in call knowledge",
                                grounding: .refused, provider: "Agy", model: "gemini")
        let typed = CallEvent(callID: "call-a", generation: 6, sequence: 9,
                              kind: .answer, answer: answer)
        let envelope = CallHostEvent(callID: typed.callID, generation: typed.generation,
                                     kind: .answer,
                                     snapshot: .init(callID: typed.callID,
                                                     generation: typed.generation,
                                                     state: .capturing))
        XCTAssertFalse(snapshot.accepts(envelope))
    }
}
