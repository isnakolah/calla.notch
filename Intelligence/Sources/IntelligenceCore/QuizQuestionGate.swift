import Foundation

public enum QuizQuestionGateDecision: Sendable, Equatable {
    case question
    case notQuestion
    /// Sparse OCR can be a diagram or image-only question. It must reach the
    /// council rather than being dropped by a brittle text-only guess.
    case uncertain
}

/// Fast, local first-pass gate. No network, model, or persisted frame needed.
///
/// It is a **cost** optimisation, not a correctness one, and the balance of the
/// two mistakes it can make is badly lopsided. Letting a non-question through
/// costs a few model calls, and the council catches it anyway — the voters have
/// `__NOT_A_QUESTION__` for exactly this. Stopping a real question here costs
/// the reader the answer, silently, with nothing on screen to say why.
///
/// It used to be written the other way round: a screen needed an interrogative,
/// a prompt phrase or a question anchor to pass, and anything else with eight or
/// more words was prose. Plenty of real questions have none of those —
///
///     Historical temperatures of Earth's atmosphere can be inferred from the
///     analysis of
///       ○ tree rings   ○ microwave radiation   ○ ice cores   ○ volcanic activity
///
/// — a declarative stem whose options carry the question, and whose radio
/// buttons OCR as nothing at all. That screen was dropped without a model ever
/// seeing it. So the default is now "ask", and only a screen that positively
/// looks like something else is refused.
public enum QuizQuestionGate {
    public static func classify(ocr: String, anchors: [String]) -> QuizQuestionGateDecision {
        let text = normalized(ocr)
        let normalizedAnchors = anchors.map(normalized).filter { !$0.isEmpty }

        if normalizedAnchors.contains(where: questionAnchor) { return .question }
        if text.isEmpty { return .uncertain }

        let padded = " \(text) "
        let interrogatives = [" what ", " which ", " who ", " whose ", " where ",
                              " when ", " why ", " how "]
        if interrogatives.contains(where: padded.contains) { return .question }

        let directPrompts = [
            "question ", "true or false", "choose all", "choose one", "select all",
            "select the correct", "calculate ", "compute ", "solve ", "determine ",
            "identify ", "evaluate ", "write code", "implement ", "complete the",
            "fill in", "match the", "arrange the", "pick the correct",
        ]
        if directPrompts.contains(where: text.contains) { return .question }

        // A block of labelled options is a question whatever the stem says.
        // "The time complexity of the loop below is" carries no interrogative and
        // matches no prompt phrase, so it used to be read as prose and dropped
        // here — the reader watched a perfectly ordinary multiple choice go
        // unanswered.
        if QuizKindClassifier.hasOptionBlock(text) { return .question }

        // Screens that are recognisably something else. Deliberately a short
        // list of things a quiz app actually shows between questions, matched on
        // the phrases those pages lead with rather than on words that could
        // appear inside a question about them.
        if notQuestionSignals.contains(where: padded.contains) { return .notQuestion }

        return .uncertain
    }

    /// Pages worth not spending a council on.
    private static let notQuestionSignals = [
        " your score ", " quiz complete ", " lesson complete ", " review your answers ",
        " correct answers ", " you scored ", " try again later ", " sign in ", " sign out ",
        " create an account ", " privacy policy ", " terms of service ", " cookie ",
        " settings ", " preferences ", " page not found ",
    ]

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func questionAnchor(_ value: String) -> Bool {
        value == "question" || value.hasPrefix("question ")
            || value.hasPrefix("choose ") || value.hasPrefix("select ")
            || value.range(of: #"^\d+\s"#, options: .regularExpression) != nil
    }
}
