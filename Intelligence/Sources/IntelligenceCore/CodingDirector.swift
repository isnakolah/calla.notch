import CallaContracts
import Foundation

/// Whether to say anything at all, and if so, what kind of thing.
///
/// The most important decision in the mode, and today it does not exist: every
/// transcript turn becomes a model request, including the interviewer saying
/// "mm-hmm". The call lane learned this already — `CopilotAdvisor` spends a
/// request only on a remote statement that invites an answer, and everything
/// else merely grows the ledger.
///
/// A coding interview needs a third outcome the call lane does not: some of the
/// most useful direction is a *fact*, not an opinion. "Nine minutes left, no
/// test has run" needs no model and should never wait for one — the same
/// principle as Tutor's "a clean deterministic pass never waits for a model".
public enum CodingDirector {

    public enum Decision: Sendable, Equatable {
        /// Say nothing. The panel keeps whatever it is showing.
        case silent(reason: String)
        /// Publish an engine fact immediately, and do not spend a request.
        case deterministic(CodingIncrement, say: String, priority: CodingMovePriority)
        /// Worth a model turn. `intent` says what kind of help was asked for.
        case ask(CodingIncrement, intent: CodingIntent, priority: CodingMovePriority)
    }

    public struct Facts: Sendable {
        public var cadence: CodingCadenceFacts
        public var openRubric: [CodingRubricState]
        public var remainingSeconds: Int?
        public var lastVerdict: CodingVerdict?
        public var lastCommand: String?
        /// A model turn is already running for this session.
        public var requestInFlight: Bool
        /// The candidate has saved since the last move — they are mid-flow.
        public var typingBurst: Bool

        public init(cadence: CodingCadenceFacts, openRubric: [CodingRubricState] = [],
                    remainingSeconds: Int? = nil, lastVerdict: CodingVerdict? = nil,
                    lastCommand: String? = nil, requestInFlight: Bool = false,
                    typingBurst: Bool = false) {
            self.cadence = cadence; self.openRubric = openRubric
            self.remainingSeconds = remainingSeconds; self.lastVerdict = lastVerdict
            self.lastCommand = lastCommand; self.requestInFlight = requestInFlight
            self.typingBurst = typingBurst
        }
    }

    /// Decide on one completed statement.
    public static func decide(statement: Statement, facts: Facts) -> Decision {
        // Unreliable speech cannot authorize an edit or become a constraint.
        if statement.truncated || statement.text.contains("[unclear]") {
            return .deterministic(.clarify,
                say: "Could you repeat the last requirement? I want to confirm it before changing the solution.",
                priority: .urgent)
        }

        let intent = CodingIntentClassifier.classify(statement.text)
        if statement.speaker == .remote {
            if CodingInterviewerSignal.detect(statement.text) != nil {
                return .ask(increment(for: intent == .none ? .design : intent, facts),
                            intent: intent == .none ? .design : intent, priority: .urgent)
            }
            if intent != .none || CodingIntentClassifier.invitesResponse(statement.text) {
                let resolved = intent == .none ? CodingIntent.explain : intent
                return .ask(increment(for: resolved, facts), intent: resolved, priority: .urgent)
            }
            return .silent(reason: "listening to the interviewer")
        }

        // A deliberate request survives a save or a busy worker. The engine
        // queues it; incidental narration still observes the pacing below.
        //
        // The exception is a request for *code* that is phrased as an
        // announcement — "let me write the sum function now". That is either a
        // request or the candidate narrating what they are about to type, and
        // the words do not settle it. So it defers to the guards below instead
        // of jumping them, and the thing that settles it is evidence: someone
        // mid-edit is doing it themselves and a block of code appearing under
        // their hands is an interruption, while someone who has said it and is
        // sitting still is asking.
        if intent != .none {
            let announced = intent == .writeCode
                && CodingIntentClassifier.announcesOwnWork(statement.text)
            if !announced {
                return .ask(increment(for: intent, facts), intent: intent,
                            priority: intent == .runCommand ? .urgent : .advisory)
            }
            if facts.typingBurst {
                return .silent(reason: "candidate is writing what they just announced")
            }
            if facts.requestInFlight { return .silent(reason: "a move is already in flight") }
            return .ask(increment(for: intent, facts), intent: intent, priority: .advisory)
        }
        if let urgent = urgentFact(facts) { return urgent }
        if facts.typingBurst { return .silent(reason: "candidate is mid-edit") }
        if facts.requestInFlight { return .silent(reason: "a move is already in flight") }
        if CodingIntentClassifier.invitesResponse(statement.text) || isStuck(statement.text) {
            return .ask(.narrate, intent: .explain, priority: .advisory)
        }

        // Fluent narration needs no understudy. This is where most
        //    statements land, and it is the whole point.
        return .silent(reason: "candidate is fluent")
    }

    /// Engine facts worth interrupting for, checked in cost order.
    private static func urgentFact(_ facts: Facts) -> Decision? {
        if facts.lastVerdict == .unsatisfied, let command = facts.lastCommand {
            return .deterministic(
                .narrate,
                say: "`\(command)` is failing. Read the first error aloud and fix only that.",
                priority: .urgent)
        }
        guard let remaining = facts.remainingSeconds else { return nil }
        if remaining <= 0 { return nil }
        if remaining <= 300, !facts.cadence.hasPassingRun {
            return .deterministic(
                .verify,
                say: "\(remaining / 60) minutes left and nothing has passed yet — run the check now.",
                priority: .urgent)
        }
        if remaining <= 600, let next = facts.openRubric.first(where: { $0.status == .open }) {
            return .deterministic(
                .narrate,
                say: "\(remaining / 60) minutes left. You have not covered: \(next.text).",
                priority: .advisory)
        }
        return nil
    }

    private static func preferredIncrement(_ facts: Facts) -> CodingIncrement {
        CodingCadence.allowed(facts.cadence).first ?? .narrate
    }

    /// What the intent asks for, when the pacing ladder allows it.
    ///
    /// Words-only requests can be answered in every phase. The ladder limits
    /// code size; it must not turn an explanation or command into code.
    private static func increment(for intent: CodingIntent, _ facts: Facts) -> CodingIncrement {
        if let preferred = intent.preferredIncrement {
            return preferred
        }
        return preferredIncrement(facts)
    }

    /// Trailing off is the clearest signal a candidate wants help.
    ///
    /// Kept to phrases that are unambiguous when spoken to nobody. "I think" is
    /// excluded on purpose — it prefixes half of all confident narration.
    static func isStuck(_ text: String) -> Bool {
        let value = text.lowercased()
        return stuckPhrases.contains { value.contains($0) }
    }

    private static let stuckPhrases = [
        "i'm not sure", "im not sure", "not sure how", "not sure if",
        "i'm stuck", "im stuck", "hmm", "wait, why", "that's not right",
        "thats not right", "why is that", "what am i missing", "doesn't work",
        "does not work", "i forget", "can't remember", "cant remember"
    ]
}
