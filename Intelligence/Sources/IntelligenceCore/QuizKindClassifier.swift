import CallaContracts
import Foundation

/// Decides what shape of answer a question wants.
///
/// This drives three things at once: which canonicaliser compares the votes,
/// whether voter unanimity is even allowed to settle the question without the
/// arbiter, and the `Expected kind:` line the council is prompted with. Getting
/// it wrong is therefore both an accuracy and a latency fault.
///
/// The heuristic it replaces was an ordered list of substring tests, and the
/// order did most of the damage: `implement` and `function` were checked before
/// any option detection, so a multiple-choice question *about* functions became
/// `.code`; `image` matched the word anywhere, so "which image shows…" became
/// `.diagram`; and a single weak regex was the only route to `.singleChoice`. A
/// misclassified choice question can never short-circuit, so it always paid for
/// a fourth model call.
///
/// Structure is a far stronger signal than phrasing, so the option block is
/// looked for first. Note the OCR arriving here has already been through
/// `QuizFrameObservation.normalizeOCR`: lower-cased, punctuation flattened to
/// spaces, newlines kept. So `B) Paris` reads as `b paris`.
public enum QuizKindClassifier {
    public static func classify(ocr: String) -> QuizQuestionKind {
        let text = ocr.lowercased()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing readable: a screenshot-only question, not prose.
            return .image
        }

        // Being *about* code does not make a question open-ended. A question on
        // time complexity with four lettered options is a multiple choice, and
        // routing it to the Open council costs a deep bench and a refinement pass
        // to pick one of four letters.
        //
        // The ordering here is the whole subtlety. Coding signals used to be
        // checked first, because `Example 1` / `Example 2` / `Example 3` on a
        // LeetCode page is a perfectly good ascending *numbered* run: the option
        // detector found it, the page was told "Expected kind: singleChoice",
        // every voter answered `__NOT_A_QUESTION__` — a majority — and the panel
        // cleared. So the two are separated by label shape. A **lettered** run
        // beats the coding signals, because prose furniture does not produce
        // `a` `b` `c` `d` in order with a short phrase after each. A **numbered**
        // run still loses to them, which is exactly the LeetCode case.
        let options = optionBlock(text)
        let coding = codingProblemSignals(text)
        if options.labels.count >= 2, options.lettered || coding < 2 {
            // Options that *are* true and false want boolean canonicalisation,
            // or a voter answering "True" and one answering "A" disagree.
            let bodies = Set(options.labels.values.map { $0.trimmingCharacters(in: .whitespaces) })
            if bodies == ["true", "false"] { return .boolean }
            return wantsMultiple(text) ? .multipleChoice : .singleChoice
        }
        if coding >= 2 { return .code }

        if text.contains("true or false") || text.contains(" true false ")
            || text.contains("true false") {
            return .boolean
        }
        if text.contains("write code") || text.contains("write a function")
            || text.contains("implement the") || text.contains("complete the function")
            || text.contains("write a program") {
            return .code
        }
        if text.contains("calculate") || text.contains("how many") || text.contains("how much")
            || text.contains("what is the value") || text.contains("round your answer")
            || text.contains("to the nearest") {
            return .numeric
        }
        // Only a question that points *at* a figure, rather than one that merely
        // says the word.
        if text.contains("in the diagram") || text.contains("in the figure")
            || text.contains("diagram above") || text.contains("figure above")
            || text.contains("diagram below") || text.contains("figure below")
            || text.contains("shown above") || text.contains("shown below") {
            return .diagram
        }
        return .text
    }

    /// How much this reads like a programming exercise.
    ///
    /// Deliberately landmark-based rather than phrase-based: these are the parts
    /// of the *page furniture* a coding site puts around a problem, which survive
    /// OCR and do not depend on how the prose is worded. Two is the bar, so a
    /// multiple-choice question that merely mentions a function does not qualify.
    private static func codingProblemSignals(_ text: String) -> Int {
        let landmarks = [
            "example 1", "constraints", "follow up", "class solution",
            "input nums", "expected output", "time complexity", "space complexity",
            "def ", "return the", "testcase", "test result", "submit",
            "0 indexed", "in place", "return true if", "return false if",
        ]
        return landmarks.filter { text.contains($0) }.count
    }

    /// Whether more than one option is being asked for.
    private static func wantsMultiple(_ text: String) -> Bool {
        let phrases = ["select all", "choose all", "all that apply", "select two",
                       "select three", "choose two", "choose three", "select each",
                       "mark all", "tick all", "more than one"]
        return phrases.contains { text.contains($0) }
    }

    /// The option labels and their text, when the screen holds a real option
    /// block.
    ///
    /// Works on a flat token stream rather than on lines, because by the time OCR
    /// reaches here it has none: `QuizFrameObservation.normalizeOCR` ends with
    /// `split(whereSeparator: \.isWhitespace)`, which treats a newline as
    /// whitespace and joins everything with spaces. A first version of this split
    /// on "\n" and so found an option block only in tests, never in production —
    /// every multiple choice was classified as prose.
    ///
    /// Matching single letters anywhere is not enough either: "given **a** 0-indexed
    /// array" is the same shape as an option label. What distinguishes a real block
    /// is a *run* — `a` then `b` then `c`, in order, each with text after it. Prose
    /// does not do that.
    /// Longest an option's text can be before it stops looking like an option.
    private static let maximumOptionWords = 16

    /// Whether the screen holds a real block of labelled options.
    ///
    /// Public because the gate needs it too: plenty of questions are phrased as
    /// a statement — "The time complexity of the loop below is" — with the
    /// question carried entirely by the options underneath. Those have no
    /// interrogative and no prompt phrase, so a gate reading only the prose
    /// rejects them, and the council is never asked.
    public static func hasOptionBlock(_ ocr: String) -> Bool {
        optionBlock(ocr.lowercased()).labels.count >= 2
    }

    /// An option block and how it was labelled. The shape matters: a lettered
    /// run is trusted over the coding-page signals, a numbered one is not.
    struct OptionBlock {
        var labels: [String: String] = [:]
        var lettered = false
    }

    private static func optionBlock(_ text: String) -> OptionBlock {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let run = labelledRun(tokens, from: "a", isMember: { $0.isLetter && $0 <= "h" }) {
            return OptionBlock(labels: run, lettered: true)
        }
        let numbered = labelledRun(tokens, from: "1", isMember: { ("1" ... "9").contains($0) })
        return OptionBlock(labels: numbered ?? [:], lettered: false)
    }

    /// The longest run of labels in order, preferring the one latest on screen —
    /// options come after the stem.
    private static func labelledRun(_ tokens: [String], from start: Character,
                                    isMember: (Character) -> Bool) -> [String: String]? {
        var positions: [Character: [Int]] = [:]
        for (index, token) in tokens.enumerated() {
            let cleaned = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard cleaned.count == 1, let character = cleaned.first, isMember(character) else {
                continue
            }
            positions[character, default: []].append(index)
        }
        guard let firstPositions = positions[start], !firstPositions.isEmpty else { return nil }

        var best: [(label: Character, index: Int)] = []
        for anchor in firstPositions {
            var run: [(label: Character, index: Int)] = [(start, anchor)]
            var next = UnicodeScalar(start.unicodeScalars.first!.value + 1)!
            var cursor = anchor
            while let candidates = positions[Character(next)],
                  let step = candidates.first(where: { $0 > cursor }) {
                run.append((Character(next), step))
                cursor = step
                guard let following = UnicodeScalar(next.value + 1) else { break }
                next = following
            }
            // Longest wins; a later start breaks a tie, since the options are
            // below the stem.
            if run.count > best.count || (run.count == best.count && anchor > (best.first?.index ?? -1)) {
                best = run
            }
        }
        guard best.count >= 2 else { return nil }

        var found: [String: String] = [:]
        for (offset, item) in best.enumerated() {
            let end = offset + 1 < best.count ? best[offset + 1].index : tokens.count
            let words = Array(tokens[(item.index + 1) ..< end])
            // A label with nothing after it is not an option.
            guard !words.isEmpty else { return nil }
            // An option is a phrase, not a passage. Without this, a LeetCode page
            // reads as a numbered option block: `Example 1`, `Example 2`,
            // `Example 3` is a perfectly good ascending run, and each "option"
            // swallows the paragraph beneath it.
            //
            // The last one is exempt, because it runs to the end of the screen and
            // picks up whatever chrome sits below the options.
            let isLast = offset + 1 == best.count
            guard isLast || words.count <= maximumOptionWords else { return nil }
            found[String(item.label)] = words.prefix(maximumOptionWords).joined(separator: " ")
        }
        return found
    }
}
