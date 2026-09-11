import Foundation
import Testing
import CallaContracts
@testable import IntelligenceCore

/// Announcing your own next move is talk aimed at the interviewer, not a
/// request aimed at this panel — nothing is ever addressed to it out loud.
/// Answering an announcement with a block of code changes the panel at the
/// exact moment the candidate starts typing.
struct CodingAnnouncementTests {
    private func intent(_ text: String) -> CodingIntent {
        CodingIntentClassifier.classify(text)
    }

    @Test func announcementsAreRecognisedAsSuch() {
        for sentence in [
            "Let me write the sum function now.",
            "I'll implement the range expansion next.",
            "So, now I'll write the evaluator for binary operators.",
            "I'm going to implement this recursively.",
            "Then I'll write a test for the empty case.",
            "First I'll implement the reference lookup.",
        ] {
            #expect(CodingIntentClassifier.announcesOwnWork(sentence),
                    "not read as an announcement: \(sentence)")
            // Most are still a code intent — the words alone do not settle
            // whether it is a request, and a recorded session exists where
            // treating one as narration left a real request unanswered.
            // "Then I'll write a test" carries no write phrase at all, so it
            // was never a code intent to begin with.
            #expect(intent(sentence) == .writeCode || intent(sentence) == .none)
        }
    }

    /// The evidence that settles it: someone mid-edit is doing it themselves.
    @Test func anAnnouncementWhileTypingDoesNotInterrupt() {
        let statement = Statement(fromSeq: 0, toSeq: 0, speaker: .local,
                                  text: "Let me write the sum function now.",
                                  span: 2, truncated: false)
        let typing = CodingDirector.Facts(
            cadence: CodingCadenceFacts(phase: .implementing, hasCode: true),
            typingBurst: true)
        guard case let .silent(reason) = CodingDirector.decide(statement: statement, facts: typing)
        else { Issue.record("interrupted a candidate who was typing"); return }
        #expect(reason.contains("announced"))

        // Sitting still, the same sentence is a request.
        let still = CodingDirector.Facts(
            cadence: CodingCadenceFacts(phase: .implementing, hasCode: true))
        guard case .ask = CodingDirector.decide(statement: statement, facts: still) else {
            Issue.record("ignored a request from a candidate who was not typing"); return
        }
    }

    /// A plain request is not subject to that: it survives a save, as before.
    @Test func anExplicitRequestSurvivesATypingBurst() {
        let statement = Statement(fromSeq: 0, toSeq: 0, speaker: .local,
                                  text: "Can you implement the range expansion?",
                                  span: 2, truncated: false)
        let typing = CodingDirector.Facts(
            cadence: CodingCadenceFacts(phase: .implementing, hasCode: true),
            typingBurst: true)
        guard case .ask = CodingDirector.decide(statement: statement, facts: typing) else {
            Issue.record("dropped an explicit request"); return
        }
    }

    @Test func askingForCodeStillAsks() {
        #expect(intent("Can you implement the range expansion?") == .writeCode)
        #expect(intent("Could you implement this for me?") == .writeCode)
        #expect(intent("I'm not sure how to write the sum function.") == .writeCode)
        #expect(intent("I need a function that expands a range.") == .writeCode)
    }

    @Test func anAnnouncementThatAlsoAsksIsStillARequest() {
        // The second clause is a real question; the first must not swallow it.
        #expect(intent("I'll write the parser, but how would I implement the recursion?")
                == .writeCode)
        #expect(intent("Let me write the sum, can you implement the range part?")
                == .writeCode)
    }

    /// An announced run is deliberately still a run: a staged check sits there
    /// until Run is pressed, so it costs the reader nothing and saves a step.
    @Test func anAnnouncedRunStillStagesTheCheck() {
        #expect(intent("Let me run the tests.") == .runCommand)
        #expect(intent("I'll run the app now.") == .runCommand)
    }

    @Test func opinionsAreNotAnnouncements() {
        // "I think" and "I would" prefix half of all confident narration, and
        // neither is about to do anything.
        #expect(!CodingIntentClassifier.announcesOwnWork("I think we should implement it lazily"))
        #expect(!CodingIntentClassifier.announcesOwnWork("I would implement the parser first"))
        // And a bare announcement is one.
        #expect(CodingIntentClassifier.announcesOwnWork("let me write the function"))
        #expect(CodingIntentClassifier.announcesOwnWork("so, now I'll implement it"))
    }

    /// The whole point of the mode: most of what the candidate says is them
    /// answering the interviewer, and it should produce nothing at all.
    @Test func answeringTheInterviewerIsSilent() {
        let facts = CodingDirector.Facts(
            cadence: CodingCadenceFacts(phase: .implementing, hasCode: true))
        for sentence in [
            "So the engine stores the raw string and evaluates it lazily on read.",
            "I chose a NamedTuple because it is immutable and cheap to hash.",
            "Right, so this returns the formatted string rather than the value.",
            "In my part one I kept formatting separate from evaluation.",
        ] {
            let statement = Statement(fromSeq: 0, toSeq: 0, speaker: .local,
                                      text: sentence, span: 2, truncated: false)
            guard case .silent = CodingDirector.decide(statement: statement, facts: facts) else {
                Issue.record("spoke over the candidate: \(sentence)")
                continue
            }
        }
    }

    /// And the interviewer's own backchannel is not a question.
    @Test func backchannelFromTheInterviewerIsSilent() {
        let facts = CodingDirector.Facts(
            cadence: CodingCadenceFacts(phase: .implementing, hasCode: true))
        for sentence in ["Mm-hmm.", "Okay, that makes sense.", "Right."] {
            let statement = Statement(fromSeq: 0, toSeq: 0, speaker: .remote,
                                      text: sentence, span: 1, truncated: false)
            guard case .silent = CodingDirector.decide(statement: statement, facts: facts) else {
                Issue.record("answered a backchannel: \(sentence)")
                continue
            }
        }
    }
}
