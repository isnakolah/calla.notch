import CallaContracts
import Foundation

/// What the Quiz panel draws, decided outside SwiftUI so it can be tested.
///
/// The view this replaces made two structural mistakes. It checked
/// `answer != nil` before any lifecycle state, which made `.stopping`,
/// `.paused` and every failure message unreachable the moment an answer had
/// been shown — including the Resume button, the only way back from a pause.
/// And it had no branch for `.failed`, so a failed session rendered as
/// "Watching for next question…".
///
/// Lifecycle is resolved first here, and the answer is content within a stage
/// rather than a branch above it.
enum CallaQuizPresentation {
    enum Stage: Equatable {
        /// Session is coming up; the string says how far along.
        case starting(String)
        case watching
        /// A viewport is missing and the user has to scroll the target.
        case collecting(QuizCommandKind?)
        /// The council is working; the string names the phase.
        case working(String)
        case answered
        case paused(String?)
        case stopping
        case failed(String)
    }

    static func stage(for quiz: QuizSessionSnapshot) -> Stage {
        switch quiz.state {
        case .failed:
            return .failed(message(quiz.failure) ?? "Quiz stopped unexpectedly")
        case .stopping:
            return .stopping
        case .paused:
            return .paused(message(quiz.failure))
        case .starting:
            return .starting("Starting Quiz…")
        case .preparingWorkers:
            return .starting("Preparing reasoners…")
        case .solving:
            return .working("Reasoning…")
        case .arbitrating:
            return .working("Verifying…")
        case .retrying:
            return .working("Retrying a reasoner…")
        case .collecting:
            return .collecting(quiz.scrollPrompt)
        case .answered:
            return .answered
        case .watching, .finished:
            return quiz.answer == nil ? .watching : .answered
        }
    }

    /// The short state word in the card header.
    static func stateLine(for quiz: QuizSessionSnapshot) -> String {
        switch quiz.state {
        case .preparingWorkers: "Preparing"
        case .watching: "Watching"
        case .collecting: "Collecting"
        case .solving: "Reasoning"
        case .arbitrating: "Verifying"
        case .retrying: "Retrying"
        case .answered: "Answered"
        case .paused: "Paused"
        case .starting: "Starting"
        case .stopping: "Stopping"
        case .finished: "Finished"
        case .failed: "Failed"
        }
    }

    static func targetLabel(for target: QuizWindowTarget?) -> String {
        guard let target else { return "No target window" }
        let title = target.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return target.applicationName }
        return "\(target.applicationName) — \(title)"
    }

    /// A failure string worth a line of a ~100pt surface.
    private static func message(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Code answers

    /// A code answer, unwrapped.
    ///
    /// The council is told to return "answer-only fenced code", so a code answer
    /// arrives wrapped in ``` with the language on the opening line. The panel
    /// used to draw that verbatim — the reader saw the backticks, and the copy
    /// button put them on the pasteboard, so pasting into an editor produced
    /// something that would not run.
    struct CodeAnswer: Equatable {
        /// As the model labelled it, when it did.
        let language: String?
        /// The code itself, fences gone.
        let body: String

        var lines: [String] { body.components(separatedBy: "\n") }
        var isEmpty: Bool { body.isEmpty }
    }

    /// Whether this answer should be drawn as code.
    ///
    /// Keying off `QuizQuestionKind.code` alone was not enough: a LeetCode page
    /// classifies as `.text`, because its prose gives no "write a function"
    /// phrasing to match on. So the answer came back as fenced Python and was
    /// drawn as a paragraph — proportional, bold, fences and all. What the answer
    /// *is* settles this better than what the question was thought to be.
    static func looksLikeCode(_ answer: String) -> Bool {
        if answer.contains("```") { return true }
        let lines = answer.components(separatedBy: "\n")
        guard lines.count > 1 else { return false }
        let signals = ["def ", "class ", "func ", "function ", "return ", "import ",
                       "#include", "let ", "var ", "const ", "public ", "private ",
                       "for ", "while ", "if ", "=>", "};"]
        let hits = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            if trimmed.hasSuffix("{") || trimmed.hasSuffix(":") || trimmed.hasSuffix(";") {
                return true
            }
            return signals.contains { trimmed.hasPrefix($0) }
        }.count
        // Prose does not open a third of its lines with `return` or end them in a
        // brace.
        return hits >= 2 && Double(hits) / Double(lines.count) >= 0.25
    }

    static func code(from answer: String) -> CodeAnswer {
        let text = answer.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")

        // Drop blank lines at either end before looking for a fence, because a
        // model that adds a leading newline is otherwise treated as unfenced.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }

        var language: String?
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("```") {
            let tag = first.dropFirst(3).trimmingCharacters(in: .whitespaces)
            language = tag.isEmpty ? nil : tag.lowercased()
            lines.removeFirst()
            // A closing fence, if the model wrote one. An unterminated block is
            // still worth showing rather than discarding.
            if let last = lines.last?.trimmingCharacters(in: .whitespaces), last.hasPrefix("```") {
                lines.removeLast()
            }
        }

        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return CodeAnswer(language: language, body: lines.joined(separator: "\n"))
    }

    /// What to put on the pasteboard: the code, never the fences.
    static func copyableText(for answer: QuizFinalAnswer) -> String {
        guard answer.kind == .code || looksLikeCode(answer.answer) else { return answer.answer }
        let code = code(from: answer.answer)
        return code.isEmpty ? answer.answer : code.body
    }

    /// What a run of code characters is, for colouring.
    enum CodeTokenRole: Equatable {
        case plain, keyword, string, comment, number
    }

    struct CodeToken: Equatable {
        let text: String
        let role: CodeTokenRole
    }

    /// Keywords worth colouring across the languages a coding question is
    /// actually set in. One shared set rather than a grammar per language: the
    /// point is to make structure visible at a glance, not to parse.
    private static let codeKeywords: Set<String> = [
        "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not",
        "and", "or", "import", "from", "as", "with", "try", "except", "finally",
        "raise", "yield", "lambda", "pass", "break", "continue", "global", "assert",
        "None", "True", "False", "self",
        "func", "let", "var", "guard", "struct", "enum", "protocol", "extension",
        "public", "private", "static", "throws", "throw", "init", "nil", "true",
        "false", "switch", "case", "default", "where", "some", "any",
        "function", "const", "new", "typeof", "await", "async", "null", "undefined",
        "int", "long", "double", "float", "bool", "boolean", "char", "void", "string",
        "vector", "auto", "const", "final", "type", "range", "len", "print",
    ]

    /// One line, split into coloured runs.
    ///
    /// Deliberately line-local and stateless: a block that spans lines — a Python
    /// docstring, a C comment — is coloured only where it opens. Getting that
    /// fully right needs a parser per language, and the reader is looking at
    /// twenty lines in a notch, not editing them.
    static func tokenize(_ line: String) -> [CodeToken] {
        var tokens: [CodeToken] = []
        var current = ""
        var index = line.startIndex

        func flush(_ role: CodeTokenRole = .plain) {
            guard !current.isEmpty else { return }
            tokens.append(CodeToken(text: current, role: role))
            current = ""
        }

        func flushWord() {
            guard !current.isEmpty else { return }
            let role: CodeTokenRole
            if codeKeywords.contains(current) {
                role = .keyword
            } else if current.first?.isNumber == true,
                      current.allSatisfy({ $0.isNumber || $0 == "." || $0 == "_" }) {
                role = .number
            } else {
                role = .plain
            }
            tokens.append(CodeToken(text: current, role: role))
            current = ""
        }

        while index < line.endIndex {
            let character = line[index]
            let rest = line[index...]

            // Comment to end of line.
            if character == "#" || rest.hasPrefix("//") {
                flushWord()
                tokens.append(CodeToken(text: String(rest), role: .comment))
                return tokens
            }

            // String literal, including a triple quote that opens a docstring.
            if character == "\"" || character == "'" {
                flushWord()
                let quote = character
                let triple = rest.hasPrefix(String(repeating: String(quote), count: 3))
                let marker = triple ? String(repeating: String(quote), count: 3) : String(quote)
                var literal = marker
                var cursor = line.index(index, offsetBy: marker.count)
                while cursor < line.endIndex {
                    let remaining = line[cursor...]
                    if remaining.hasPrefix(marker) {
                        literal += marker
                        cursor = line.index(cursor, offsetBy: marker.count)
                        break
                    }
                    literal.append(line[cursor])
                    cursor = line.index(after: cursor)
                }
                tokens.append(CodeToken(text: literal, role: .string))
                index = cursor
                continue
            }

            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else {
                flushWord()
                current.append(character)
                flush()
            }
            index = line.index(after: index)
        }
        flushWord()
        return tokens
    }

    // MARK: - Answer history

    /// Where the reader is in the session's answers.
    ///
    /// Identified by answer id rather than index, because the history is capped
    /// and trims from the front: an index quietly starts pointing at a different
    /// answer once that happens.
    struct Cursor: Equatable {
        /// `nil` pins the panel to the newest answer.
        var answerID: String?

        static let latest = Cursor(answerID: nil)

        var isFollowingLatest: Bool { answerID == nil }
    }

    /// The answer to draw, and where it sits.
    struct Position: Equatable {
        let answer: QuizFinalAnswer?
        let index: Int
        let count: Int
        /// True when the reader has stepped back and newer answers exist. The
        /// panel offers a way forward rather than jumping on its own.
        let hasNewer: Bool

        /// `nil` while there is nothing worth numbering.
        var label: String? { count > 1 ? "\(index + 1) / \(count)" : nil }
        var isFollowingLatest: Bool { count == 0 || index == count - 1 }
        var canGoBack: Bool { index > 0 }
        var canGoForward: Bool { count > 0 && index < count - 1 }
    }

    static func position(_ cursor: Cursor, history: [QuizFinalAnswer]) -> Position {
        guard !history.isEmpty else {
            return Position(answer: nil, index: 0, count: 0, hasNewer: false)
        }
        let index = cursor.answerID
            .flatMap { id in history.firstIndex { $0.id == id } }
            ?? history.count - 1
        return Position(answer: history[index], index: index, count: history.count,
                        hasNewer: index < history.count - 1)
    }

    static func back(_ cursor: Cursor, history: [QuizFinalAnswer]) -> Cursor {
        let current = position(cursor, history: history)
        guard current.canGoBack else { return cursor }
        return Cursor(answerID: history[current.index - 1].id)
    }

    static func forward(_ cursor: Cursor, history: [QuizFinalAnswer]) -> Cursor {
        let current = position(cursor, history: history)
        guard current.canGoForward else { return cursor }
        let next = current.index + 1
        // Reaching the end resumes following, so the next answer to arrive is
        // shown without the reader asking again.
        return next == history.count - 1 ? .latest : Cursor(answerID: history[next].id)
    }

    /// Keeps a cursor valid as the history changes.
    ///
    /// A cursor pointing at an answer that has since been trimmed would
    /// otherwise silently resolve to the newest one, which reads as the panel
    /// jumping. Snapping explicitly makes that a single, deliberate move.
    static func reconcile(_ cursor: Cursor, history: [QuizFinalAnswer]) -> Cursor {
        guard let id = cursor.answerID else { return .latest }
        guard history.contains(where: { $0.id == id }) else { return .latest }
        return cursor
    }
}
