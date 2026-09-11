import CallaContracts
import Foundation

/// What the candidate is asking for.
///
/// The director's first cut only spoke for an interviewer's question or a
/// candidate who had visibly stalled, and treated everything else as fluent
/// narration to be left alone. That is wrong in the most common case of all:
///
///     "So I need to get a command to run this application."
///
/// which is a direct request, phrased as a statement, with no question mark and
/// no sign of being stuck. A copilot that stays quiet through that is not being
/// disciplined, it is being useless.
///
/// So intent is read explicitly, and it decides what *kind* of help comes back —
/// a command to run, a piece of code, an explanation, or a design — rather than
/// leaving the twin to infer it from prose.
public enum CodingIntent: String, Codable, Sendable, CaseIterable {
    /// Wants a command staged and run: build, test, launch, install.
    case runCommand
    /// Wants code written or extended.
    case writeCode
    /// Wants to understand something — an error, a behaviour, a trade-off.
    case explain
    /// Wants the shape of a solution before any code.
    case design
    /// Nothing actionable; the candidate is narrating.
    case none

    /// The step this intent asks for, when the cadence ladder permits it.
    public var preferredIncrement: CodingIncrement? {
        switch self {
        case .runCommand: .verify
        case .writeCode: nil          // the ladder decides how big a bite
        case .explain: .narrate
        case .design: .sketch
        case .none: nil
        }
    }

    /// Whether a move for this intent should carry a runnable check.
    public var wantsCommand: Bool { self == .runCommand }
}

public enum CodingIntentClassifier {

    /// Read one completed statement.
    ///
    /// Deterministic and deliberately literal. This is a *routing* decision, not
    /// an answer — getting it wrong costs one badly-shaped move, while a model
    /// call to classify would cost the whole latency budget before any work
    /// started.
    public static func classify(_ text: String) -> CodingIntent {
        let value = normalized(text)

        // Ordered: a request to run outranks the code that would be run, because
        // "write the test and run it" ends in an execution the engine performs.
        if matches(value, runPhrases) { return .runCommand }
        if matches(value, explainPhrases) { return .explain }
        if matches(value, designPhrases) { return .design }
        if matches(value, writePhrases) { return .writeCode }
        return .none
    }

    private static func matches(_ haystack: String, _ needles: [String]) -> Bool {
        // Match complete phrases, not "explain" inside "explained". Reject a
        // negated or reported action in its own clause, while allowing a later
        // correction such as "don't run it; explain the failure instead".
        let clauses = haystack.components(separatedBy: CharacterSet(charactersIn: ".!?;,"))
        return clauses.contains { clause in
            let padded = " " + clause.trimmingCharacters(in: .whitespaces) + " "
            guard ![" don't ", " do not ", " no need to ", " already ",
                    " asked me to ", " asked you to ", " said to ",
                    " don't need ", " not asking ", " shouldn't ", " should not "]
                .contains(where: { padded.contains($0) }) else { return false }
            return needles.contains { phrase in
                guard padded.contains(" " + phrase + " ") else { return false }
                if phrase == "explain" {
                    return ["explain ", "please explain ", "can you explain ",
                            "could you explain ", "would you explain ", "help me explain "]
                        .contains(where: clause.trimmingCharacters(in: .whitespaces).hasPrefix)
                }
                return true
            }
        }
    }

    /// Whether a clause opens by announcing the speaker's own next action.
    ///
    /// Not a rejection on its own. "Let me implement the sum function" is
    /// genuinely ambiguous — it is either "I am about to do this" or "let's get
    /// to it, show me" — and a recorded session exists where treating it as
    /// narration meant the candidate asked for code and got silence. So this
    /// only decides whether the request may *interrupt*: the director lets an
    /// announcement defer to the pacing guards instead of jumping them, and the
    /// evidence that settles it is whether the candidate is actually typing.
    ///
    /// Checked per clause, so "I'll write the parser, can you show me the
    /// recursion?" still reaches the second half.
    public static func announcesOwnWork(_ text: String) -> Bool {
        // Normalized here rather than assumed: the openings below are lowercase
        // with straight apostrophes, and a caller passing raw speech would have
        // matched none of them while appearing to work.
        let clauses = normalized(text).components(separatedBy: CharacterSet(charactersIn: ".!?;,"))
        let announcing = clauses.contains { clause in
            let value = clause.trimmingCharacters(in: .whitespaces)
            // Discourse markers first: "so, let me write…" is the same sentence.
            let words = value.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
            let opening = words.drop { Statement.discourseMarkers.contains($0) }
                .prefix(4).joined(separator: " ")
            return announcementOpenings.contains { opening.hasPrefix($0) }
        }
        guard announcing else { return false }
        // An announcement that also asks is still a request.
        return !clauses.contains { clause in
            let value = clause.trimmingCharacters(in: .whitespaces)
            return value.contains("?") || invitesResponse(value)
        }
    }

    /// First person, about to act. Deliberately not "I think" or "I would",
    /// which prefix opinions rather than actions.
    private static let announcementOpenings = [
        "let me", "let's", "lets", "i'll", "ill ", "i will",
        "i'm going to", "im going to", "i am going to",
        "i'm gonna", "im gonna", "now i", "next i", "i'm about to", "im about to",
        "first i", "then i", "so i'll", "i'm just going to",
    ]

    static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Coding uses a stricter fallback than the general call detector. Reported
    /// speech and negation must not undo the intent classifier's rejection.
    public static func invitesResponse(_ text: String) -> Bool {
        let value = normalized(text)
        let padded = " " + value + " "
        if [" asked me to ", " asked you to ", " already ", " said to "]
            .contains(where: padded.contains) { return false }
        let words = value.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        let opening = words.drop { Statement.discourseMarkers.contains($0) }
        let head = opening.prefix(3).joined(separator: " ")
        if ["do not", "don't", "should not", "shouldn't", "no need"]
            .contains(where: head.hasPrefix) { return false }
        if value.contains("?") { return true }
        guard let first = opening.first else { return false }
        if Statement.interrogatives.contains(first) { return true }
        if Statement.auxiliaries.contains(first), opening.count > 1 { return true }
        let request = opening.joined(separator: " ")
        return Statement.requestPhrases.contains { request == $0 || request.hasPrefix($0 + " ") }
    }

    /// Asking for something to be executed, or for the command that would do it.
    private static let runPhrases = [
        "command to run", "command that runs", "how do i run", "how do we run",
        "how to run", "what's the command", "whats the command", "what is the command",
        "run this", "run the app", "run the application", "run the tests",
        "run the test", "start the app", "start this", "launch this", "launch the",
        "build this", "build the project", "spin this up", "fire this up",
        "let me run", "lets run", "let's run", "i'll run", "ill run",
        "execute this", "kick it off", "try running"
    ]

    /// Asking for code.
    ///
    /// Narrowed deliberately to a *gap* or the *start of a piece of work*.
    /// The first list also held "i'll add", "let me add" and "handle the case",
    /// which fire on ordinary narration — "now I'll add the second branch for
    /// the empty case" is a candidate who already knows what they are doing and
    /// wants to be left alone. Catching that turns the understudy into a
    /// commentator, which is the failure this whole design exists to avoid.
    private static let writePhrases = [
        "let me implement", "let's implement", "lets implement", "i'll implement",
        "let me write", "let's write", "lets write",
        "implement the", "implementation of",
        "write the function", "write a function",
        "let me code", "start coding", "start writing",
        "i need a function", "need to write", "not sure how to write",
        "how do i implement", "how would i implement",
        "can you implement", "could you implement", "implement a", "implement this",
        "write code", "write a test", "add a test", "fix this", "fix the bug"
    ]

    /// Asking to understand.
    private static let explainPhrases = [
        "why is", "why does", "why did", "what does this", "what's happening",
        "whats happening", "what is happening", "what went wrong", "explain",
        "what does that mean", "how come", "walk me through", "help me understand",
        "what's this error", "whats this error", "what is this error",
        "what about", "how about", "why not", "what if", "what's the time complexity",
        "what is the time complexity", "what's the space complexity",
        "what is the space complexity", "can you clarify", "can you expand"
    ]

    /// Asking for shape before substance.
    private static let designPhrases = [
        "how should i structure", "how should we structure", "how do i model",
        "what's the best way", "whats the best way", "what is the best way",
        "should i use", "should we use", "what approach", "which approach",
        "how would you design", "what are the trade-offs", "what are the tradeoffs",
        "which data structure", "what data structure", "what's the complexity", "whats the complexity",
        "can we improve", "can you improve", "can we optimize", "can you optimize",
        "could we optimize", "could you optimize", "make it faster", "reduce memory"
    ]
}

/// Speech acts that change the problem even when nobody asks a question.
/// These are routing hints, not assertions that the underlying words are true.
public enum CodingInterviewerSignal: String, Sendable {
    case correction, constraint, hint

    public static func detect(_ text: String) -> Self? {
        let value = CodingIntentClassifier.normalized(text)
        if ["actually", "instead", "correction", "i meant", "let's change", "let us change"]
            .contains(where: { value == $0 || value.hasPrefix($0 + " ") || value.hasPrefix($0 + ",") }) {
            return .correction
        }
        if ["assume ", "you must ", "you cannot ", "you can't ", "do not use ",
            "don't use ", "no sorting", "without sorting", "the input ",
            "inputs ", "duplicates ", "negative numbers ", "we need ", "it must "]
            .contains(where: value.hasPrefix) {
            return .constraint
        }
        if ["consider ", "think about ", "try using ", "have you considered "]
            .contains(where: value.hasPrefix) {
            return .hint
        }
        return nil
    }
}
