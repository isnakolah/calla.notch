import CallaContracts
import Foundation

/// A few words naming the question an answer belongs to.
///
/// Stepping back through a session's answers gives a list of code blocks and
/// letters with nothing to tell them apart. This is the line above each one that
/// says what was being asked — taken from the OCR the council already saw, so it
/// costs nothing and needs no model.
public enum QuizQuestionSummary {
    /// Roughly one line in the notch.
    public static let limit = 72

    /// Page furniture: chrome, badges, and the scaffolding around a question.
    /// None of it names what is being asked.
    private static let furniture: Set<String> = [
        "description", "editorial", "solutions", "submissions", "code", "testcase",
        "test result", "saved", "premium", "topics", "companies", "hint", "easy",
        "medium", "hard", "submit", "run", "auto", "python", "java", "javascript",
        "c++", "swift", "go", "constraints", "explanation", "follow up", "example",
        "input", "output", "daily question", "online", "accepted",
    ]

    /// - Parameters:
    ///   - headlines: OCR lines as written, best first.
    ///   - fallback: normalised OCR, used only when nothing better exists. It is
    ///     lower-cased and stripped of punctuation, so it reads poorly and is a
    ///     last resort rather than the plan.
    public static func summarize(headlines: [String]?, fallback: String,
                                 kind: QuizQuestionKind) -> String? {
        let candidates = (headlines ?? []).map(clean).filter(isMeaningful)

        // A question sentence names the question better than a title does — but
        // only if it survived OCR. A mangled line is worse than a clean title,
        // because the reader cannot tell whether it is the right question or the
        // wrong one badly read.
        let asking = candidates.filter(isAsking)
        if let best = asking.max(by: { legibility($0) < legibility($1) }),
           legibility(best) >= minimumLegibility {
            return trim(best)
        }
        // Otherwise the most legible line that is not chrome — on a problem page
        // that is the title, which is what a reader recognises it by.
        if let best = candidates.max(by: { legibility($0) < legibility($1) }),
           legibility(best) >= minimumLegibility {
            return trim(best)
        }
        // Everything on offer is mangled. A poorly read question is still a
        // better label than none, so take the best of a bad set rather than
        // silently showing nothing.
        if let salvage = asking.first ?? candidates.first {
            return trim(salvage)
        }
        // Nothing usable was carried, so fall back to the normalised text.
        let words = fallback.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        let joined = words.prefix(14).joined(separator: " ")
        return trim(joined.isEmpty ? nil : joined)
    }

    private static func clean(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Worth showing: long enough to mean something, not a bare number, not a
    /// tab label or a difficulty badge.
    private static func isMeaningful(_ line: String) -> Bool {
        guard line.count >= 8 else { return false }
        let lower = line.lowercased()
        // A leading problem number is part of a title, so strip it before testing
        // whether what remains is just furniture.
        let withoutNumber = lower.replacingOccurrences(
            of: #"^\d+\s*[.)]\s*"#, with: "", options: .regularExpression)
        guard !furniture.contains(withoutNumber) else { return false }
        guard furniture.first(where: { withoutNumber == $0 || withoutNumber.hasPrefix($0 + " ") })
            == nil || withoutNumber.split(separator: " ").count > 3 else { return false }
        // Needs at least two words of actual language.
        return withoutNumber.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: \.isLetter) }.count >= 2
    }

    /// Below this, a line reads as noise rather than language.
    private static let minimumLegibility = 0.62

    /// Exposed for tests, which assert the threshold actually separates prose
    /// from noise rather than trusting the constant.
    static var minimumLegibilityForTests: Double { minimumLegibility }

    /// Roughly, how much of this line reads like words.
    ///
    /// OCR on a small or low-contrast region returns text with the right shape
    /// and the wrong letters — "inese are resurts or umed quizzes". There is no
    /// way to repair that here, but there is a way to prefer a cleaner candidate
    /// over it: real prose is mostly letters, in words of more than a character
    /// or two.
    static func legibility(_ line: String) -> Double {
        let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return 0 }
        let characters = Array(line)
        guard !characters.isEmpty else { return 0 }

        let letters = Double(characters.filter { $0.isLetter || $0.isNumber }.count)
        let letterRatio = letters / Double(characters.count)

        // A pile of one- and two-character tokens is the signature of a badly
        // read line, or of a table of numbers.
        let stubby = Double(words.filter { $0.count <= 2 }.count) / Double(words.count)

        // Vowels are what mangled text tends to lose.
        let alphabetic = characters.filter(\.isLetter)
        let vowelRatio = alphabetic.isEmpty ? 0 : Double(
            alphabetic.filter { "aeiouAEIOU".contains($0) }.count) / Double(alphabetic.count)
        let vowelScore = vowelRatio < 0.15 ? 0.0 : 1.0

        return (letterRatio * 0.45) + ((1 - stubby) * 0.35) + (vowelScore * 0.20)
    }

    private static func isAsking(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("?") { return true }
        let openers = ["which ", "what ", "who ", "when ", "where ", "why ", "how ",
                       "select ", "choose ", "return ", "given ", "find ", "true or false"]
        return openers.contains { lower.hasPrefix($0) || lower.contains(" " + $0) }
    }

    private static func trim(_ line: String?) -> String? {
        guard let line else { return nil }
        let value = clean(line)
        guard !value.isEmpty else { return nil }
        guard value.count > limit else { return value }
        // Cut on a word boundary rather than mid-word.
        let cut = value.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 24 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }
}
