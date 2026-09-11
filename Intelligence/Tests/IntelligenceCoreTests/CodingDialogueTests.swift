import CallaContracts
import XCTest
@testable import IntelligenceCore

final class CodingDialogueTests: XCTestCase {
    private func say(_ text: String, _ seq: Int, _ speaker: Speaker = .local) -> Statement {
        Statement(fromSeq: seq, toSeq: seq, speaker: speaker, text: text, span: 2, truncated: false)
    }
    private func state() -> CodingInterviewFlowState { .init(sessionID: "session", generation: 2, sourceRevision: "saved") }
    private func ready() -> CodingInterviewFlowState {
        var flow = state()
        for (seq, step) in CodingReasoningStep.allCases.enumerated() {
            let statement = say("My explanation of \(step.rawValue)", seq)
            CodingInterviewFlow.record(statement, in: &flow)
            var update = CodingDialogueUpdate(state: flow)
            update.discussedStep = step; update.evidence = [CodingInterviewFlow.evidence(statement)]
            XCTAssertTrue(CodingInterviewFlow.apply(update, to: &flow))
        }
        return flow
    }
    func testCandidateStageCueRejectsInterviewerNegationHypotheticalReportedAndQuestions() {
        for stage in [CodingInterviewStage.simple, .hardening, .optimization] {
            XCTAssertEqual(CodingStageCue.stage(stage.cue, speaker: .me), stage)
            XCTAssertNil(CodingStageCue.stage(stage.cue, speaker: .them))
            XCTAssertNil(CodingStageCue.stage(stage.cue, speaker: .me, confident: false))
        }
        for value in ["Don't implement the simple version", "She said let's implement the simple version",
                      "What if let's implement the simple version", "Let's implement the simple version?",
                      "If we had time, let's optimize this", "We already implemented the simple version"] {
            XCTAssertNil(CodingStageCue.stage(value, speaker: .me), value)
        }
    }
    func testReasoningAndSeparateStageCueRequired() {
        var flow = state()
        XCTAssertFalse(CodingInterviewFlow.authorize(.simple, state: &flow))
        flow = ready()
        XCTAssertFalse(CodingInterviewFlow.authorize(.optimization, state: &flow))
        XCTAssertTrue(CodingInterviewFlow.authorize(.simple, state: &flow))
        XCTAssertTrue(CodingInterviewPublication.permitsCode(.simple, flow: flow))
        XCTAssertFalse(CodingInterviewPublication.permitsCode(.hardening, flow: flow))
    }
    func testDisplayedReasoningAndPrivateCodeCannotAuthorizeOrEstablishProgress() {
        var flow = state()
        var update = CodingDialogueUpdate(state: flow)
        update.pointers = ["Use a set", "Linear time"]
        XCTAssertTrue(CodingInterviewFlow.apply(update, to: &flow))
        XCTAssertTrue(flow.discussed.isEmpty)
        var proposal = CodingMove(ordinal: 1, sourceRevision: "saved", kind: .implementation,
                                  say: "Write this", code: "return set(values)")
        proposal.implementationStage = .simple
        XCTAssertNil(CodingInterviewPublication.screen(proposal, flow: flow).code)
        XCTAssertNil(flow.authorizedStage)
    }
    func testClarificationAnsweredByEitherSpeakerAndEarlierExplicitAnswer() {
        for speaker in [Speaker.local, .remote] {
            var flow = state()
            let answer = say("Yes, duplicates are allowed.", 1, speaker)
            CodingInterviewFlow.record(answer, in: &flow)
            var update = CodingDialogueUpdate(state: flow)
            update.clarification = .init(id: "duplicates", question: "Are duplicates allowed?", allowsYesNo: true,
                answer: "Duplicates are allowed", evidence: [CodingInterviewFlow.evidence(answer)], resolved: true)
            XCTAssertTrue(CodingInterviewFlow.apply(update, to: &flow))
            XCTAssertNil(flow.clarification)
            XCTAssertEqual(flow.clarificationHistory.last?.evidence.first?.speaker, speaker == .local ? .me : .them)
        }
    }
    func testShownQuestionDoesNotCountAsAskedAndAmbiguousYesRetainsIt() {
        var flow = state()
        flow.clarification = .init(id: "duplicates", question: "Are duplicates allowed?", allowsYesNo: true)
        let answer = say("yes", 1, .remote)
        CodingInterviewFlow.record(answer, in: &flow)
        var update = CodingDialogueUpdate(state: flow)
        update.clarification = .init(id: "duplicates", question: "Are duplicates allowed?", allowsYesNo: true,
            answer: "Yes", evidence: [CodingInterviewFlow.evidence(answer)], resolved: true)
        XCTAssertFalse(CodingInterviewFlow.apply(update, to: &flow))
        XCTAssertNotNil(flow.clarification)
        XCTAssertNotNil(flow.retry)
    }
    func testIndependentlySpokenQuestionThenShortAnswer() {
        var flow = state()
        let question = say("Are duplicates allowed?", 1)
        CodingInterviewFlow.record(question, in: &flow)
        var update = CodingDialogueUpdate(state: flow)
        update.clarification = .init(id: "duplicates", question: question.text, allowsYesNo: true,
                                     asked: CodingInterviewFlow.evidence(question))
        XCTAssertTrue(CodingInterviewFlow.apply(update, to: &flow))
        let answer = say("yes", 2, .remote)
        CodingInterviewFlow.record(answer, in: &flow)
        update = CodingDialogueUpdate(state: flow)
        update.clarification = .init(id: "duplicates", question: question.text, allowsYesNo: true,
            answer: "Yes", evidence: [CodingInterviewFlow.evidence(answer)], resolved: true)
        XCTAssertTrue(CodingInterviewFlow.apply(update, to: &flow))
        XCTAssertNil(flow.clarification)
    }
    func testPartialAnswerPreservesOpenQuestion() {
        var flow = state()
        let answer = say("Duplicates are allowed; I need to check the size limit.", 1, .remote)
        CodingInterviewFlow.record(answer, in: &flow)
        var update = CodingDialogueUpdate(state: flow)
        update.clarification = .init(id: "size", question: "What is the size limit?", answer: "Duplicates allowed",
                                    evidence: [CodingInterviewFlow.evidence(answer)])
        XCTAssertTrue(CodingInterviewFlow.apply(update, to: &flow))
        XCTAssertEqual(flow.clarification?.id, "size")
        XCTAssertFalse(CodingInterviewFlow.authorize(.simple, state: &flow))
    }
    func testCorrectionRetainsUnrelatedFactsAndReopensDependentWork() {
        var flow = ready()
        let original = say("The input is sorted.", 10, .remote)
        let correction = say("Actually the input is unsorted.", 11, .remote)
        for item in [original, correction] { CodingInterviewFlow.record(item, in: &flow) }
        flow.facts = [.init(id: "order", text: original.text, kind: .interviewerRequirement, evidence: [CodingInterviewFlow.evidence(original)]),
                      .init(id: "choice", text: "I use a set", kind: .candidateChoice, evidence: [])]
        flow.pending = [.init(id: "search", text: "Find values", stage: .simple, requirementIDs: ["order"],
                              completedEvidence: .init(sourceRevision: "saved", path: "main.py", excerpt: "binary_search"))]
        _ = CodingInterviewFlow.authorize(.simple, state: &flow)
        var update = CodingDialogueUpdate(state: flow)
        update.facts = [.init(id: "order", text: correction.text, kind: .interviewerRequirement,
                             evidence: [CodingInterviewFlow.evidence(correction)])]
        XCTAssertTrue(CodingInterviewFlow.apply(update, to: &flow))
        XCTAssertEqual(flow.facts.count, 2)
        XCTAssertNil(flow.authorizedStage)
        XCTAssertNil(flow.pending[0].completedEvidence)
        XCTAssertTrue(flow.discussed.isEmpty)
    }
    func testInvalidSpeakerOrInventedEvidenceCannotConfirmRequirements() {
        var flow = state()
        let candidate = say("I assume input is sorted.", 1)
        CodingInterviewFlow.record(candidate, in: &flow)
        var update = CodingDialogueUpdate(state: flow)
        update.facts = [.init(id: "sorted", text: "Sorted", kind: .interviewerRequirement,
                             evidence: [CodingInterviewFlow.evidence(candidate)])]
        XCTAssertFalse(CodingInterviewFlow.apply(update, to: &flow))
        update.facts?[0].kind = .assumption
        XCTAssertTrue(CodingInterviewFlow.apply(update, to: &flow))
        update = CodingDialogueUpdate(state: flow)
        update.discussedStep = .approach
        update.evidence = [.init(anchor: .init(fromSequence: 99, toSequence: 99), speaker: .me, quote: "made up")]
        XCTAssertFalse(CodingInterviewFlow.apply(update, to: &flow))
    }
    func testAlternativeSavedImplementationAcceptedButShadowEvidenceRejected() {
        var flow = ready()
        flow.pending = [.init(id: "basic", text: "Deduplicate", stage: .simple),
                        .init(id: "empty", text: "Empty input", stage: .hardening)]
        _ = CodingInterviewFlow.authorize(.simple, state: &flow)
        let statement = say("I used a dictionary to preserve insertion order.", 10)
        CodingInterviewFlow.record(statement, in: &flow)
        var update = CodingDialogueUpdate(state: flow)
        update.evidence = [CodingInterviewFlow.evidence(statement)]
        var done = flow.pending[0]
        done.completedEvidence = .init(sourceRevision: "saved", path: "main.py", excerpt: "dict.fromkeys(values)")
        update.pending = [done]
        XCTAssertFalse(CodingInterviewFlow.apply(update, to: &flow, savedFiles: [:]))
        XCTAssertTrue(CodingInterviewFlow.apply(update, to: &flow, savedFiles: ["main.py": "return list(dict.fromkeys(values))"]))
        XCTAssertEqual(flow.nextStage, .hardening)
        XCTAssertNil(flow.authorizedStage)
        XCTAssertEqual(flow.pendingRequired.map(\.id), ["empty"])
        XCTAssertFalse(CodingInterviewFlow.authorize(.hardening, state: &flow), "Explain the change first")
    }
    func testAllRevisionDimensionsFenceStaleResponses() {
        let flow = state()
        for mutate in [
            { (u: inout CodingDialogueUpdate) in u.generation += 1 },
            { $0.sessionID = "other" }, { $0.sourceRevision = "other" },
            { $0.requirementRevision += 1 }, { $0.taskRevision += 1 }
        ] {
            var current = flow; var update = CodingDialogueUpdate(state: flow); mutate(&update)
            XCTAssertFalse(CodingInterviewFlow.apply(update, to: &current))
            XCTAssertEqual(current, flow)
        }
    }
    func testRestoreKeepsContextWithoutAuthorization() throws {
        var flow = ready(); _ = CodingInterviewFlow.authorize(.simple, state: &flow)
        let data = try JSONEncoder().encode(flow)
        var restored = try JSONDecoder().decode(CodingInterviewFlowState.self, from: data)
        restored.restore(generation: 3, sourceRevision: "new")
        XCTAssertNil(restored.authorizedStage)
        XCTAssertFalse(restored.discussed.isEmpty)
        XCTAssertEqual(restored.generation, 3)
    }
    func testShortRepliesAreEmittedAndLowConfidenceDoesNotAdvance() {
        var segmenter = StatementSegmenter(rules: .coding)
        _ = segmenter.ingest(.init(seq: 1, speaker: .remote, start: 0, end: 1, text: "yes"))
        XCTAssertEqual(segmenter.tick(now: 5).first?.text, "yes")
        var flow = ready()
        CodingInterviewFlow.record(say("Let's implement the simple version [unclear]", 12), in: &flow)
        XCTAssertNil(flow.authorizedStage)
        XCTAssertNotNil(flow.retry)
    }
    func testNamedEdgeCaseCueDoesNotAuthorizeOtherCases() {
        var flow = ready(); flow.nextStage = .hardening
        flow.pending = [.init(id: "duplicates", text: "Duplicate behavior", stage: .hardening),
                        .init(id: "empty", text: "Empty input", stage: .hardening)]
        let cue = say("Let's cover duplicates.", 10)
        CodingInterviewFlow.record(cue, in: &flow)
        XCTAssertEqual(flow.authorizedPendingIDs, ["duplicates"])
        var other = CodingMove(ordinal: 1, sourceRevision: "saved", kind: .edit, code: "handle_empty()")
        other.implementationStage = .hardening; other.pendingWorkID = "empty"
        XCTAssertNil(CodingInterviewPublication.screen(other, flow: flow).code)
    }
    func testOneUtteranceCanCoverSeveralReasoningSteps() {
        var flow = state()
        let spoken = say("For one one two, return one two. Scan with a set; only first occurrences enter the result. Linear time and space.", 1)
        CodingInterviewFlow.record(spoken, in: &flow)
        var update = CodingDialogueUpdate(state: flow)
        update.discussedSteps = CodingReasoningStep.allCases
        update.evidence = [CodingInterviewFlow.evidence(spoken)]
        XCTAssertTrue(CodingInterviewFlow.apply(update, to: &flow))
        XCTAssertTrue(flow.readyForImplementation)
    }
    func testHeldStageCannotAdvance() {
        var flow = ready(); flow.held = true
        XCTAssertFalse(CodingInterviewFlow.authorize(.simple, state: &flow))
        XCTAssertNil(flow.authorizedStage)
    }
}
