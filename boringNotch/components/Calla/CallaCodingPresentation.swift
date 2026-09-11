import CallaContracts
import Foundation

/// One drawn line of a step.
public struct CodingPatchRow: Equatable, Sendable, Identifiable {
    public var id: Int
    public var kind: CodingPatchLineKind
    /// The line's number in the reader's own file, or `nil` for a line that is
    /// not in the file yet.
    public var number: Int?
    public var text: String
    /// The note anchored here, if one is.
    public var note: Int?

    public init(id: Int, kind: CodingPatchLineKind, number: Int?, text: String, note: Int? = nil) {
        self.id = id; self.kind = kind; self.number = number; self.text = text; self.note = note
    }
}

/// A step, laid out.
public struct CodingPatchDisplay: Equatable, Sendable {
    public var rows: [CodingPatchRow]
    public var notes: [CodingPatchNote]
    public var language: String?
    /// How many lines sit above the first row in the real file, or `nil` when
    /// the step is not anchored anywhere.
    public var linesAbove: Int?
    /// Whether anything is being added or removed. A step that is all context —
    /// a legacy `code` blob, or an explanation — has nothing to contrast
    /// against, so it should not be drawn dimmed.
    public var hasChanges: Bool
    public var addedCount: Int
    public var removedCount: Int

    public var isEmpty: Bool { rows.isEmpty }
}

public enum CodingPatchPresentation {
    /// Lays a patch out for drawing.
    ///
    /// Numbering is the decision worth stating: context and removed lines carry
    /// their number in the file as it stands *now*, because the reader is
    /// looking at their editor and has to find them. Added lines carry none —
    /// they are not in the file yet, and inventing a number for them would be a
    /// coordinate that does not exist. `CodingCodeFormatter`, which this
    /// replaces, numbered every line from 1, which is the one numbering that
    /// matches nothing on the reader's screen.
    public static func display(for patch: CodingPatch, anchor: CodingFileAnchor? = nil) -> CodingPatchDisplay {
        let normalised = CodingPatchLimits.normalised(patch)
        let start = normalised.startLine ?? anchor?.line
        var next = start
        var rows: [CodingPatchRow] = []

        for (index, line) in normalised.lines.enumerated() {
            switch line.kind {
            case .context, .remove:
                rows.append(CodingPatchRow(id: index, kind: line.kind, number: next,
                                           text: line.text, note: line.note))
                if let value = next { next = value + 1 }
            case .add:
                rows.append(CodingPatchRow(id: index, kind: .add, number: nil,
                                           text: line.text, note: line.note))
            }
        }

        return CodingPatchDisplay(
            rows: rows,
            notes: normalised.notes,
            language: normalised.language,
            linesAbove: start.map { max(0, $0 - 1) },
            hasChanges: normalised.changesAnything,
            addedCount: rows.filter { $0.kind == .add }.count,
            removedCount: rows.filter { $0.kind == .remove }.count)
    }

    /// A step published before patches existed, or by a model that ignored the
    /// shape. Every line is context: nothing is claimed about what is new,
    /// because nothing is known.
    public static func display(forPlainCode code: String, anchor: CodingFileAnchor? = nil) -> CodingPatchDisplay {
        let lines = code.components(separatedBy: .newlines)
        return display(for: CodingPatch(
            startLine: anchor?.line,
            lines: lines.map { CodingPatchLine(kind: .context, text: $0) }), anchor: anchor)
    }

    /// The display for whatever the move actually carries, or `nil` when it
    /// carries no code at all.
    public static func display(for move: CodingMove) -> CodingPatchDisplay? {
        if let patch = move.patch, !patch.lines.isEmpty {
            return display(for: patch, anchor: move.file)
        }
        if let code = move.code, !code.isEmpty {
            return display(forPlainCode: code, anchor: move.file)
        }
        return nil
    }

    /// What copying the step puts on the pasteboard: the file as the step
    /// leaves it, without the lines it takes out.
    public static func copyableText(for move: CodingMove) -> String? {
        if let patch = move.patch, !patch.lines.isEmpty { return patch.copyableText }
        return move.code
    }

    /// `path · symbol · line`, trimmed to what is known.
    /// The reasoning field, split into the points it is made of.
    ///
    /// `publishFlowPointer` builds a step's `why` by joining the pointers after
    /// the headline with newlines, so this field is a list that arrived as one
    /// string — and drawn as one paragraph it has to be read rather than
    /// scanned, which is the wrong cost for the one pane somebody looks at
    /// between sentences.
    ///
    /// Newlines only. Splitting on sentence boundaries as well would break
    /// `sheet.formula.parse` and `2018-01-01` apart, and the engine already
    /// puts one point on each line. A model that wrote its own bullet gets it
    /// stripped rather than drawn twice.
    public static func reasoningLines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline)
            .map { line -> String in
                var text = line.trimmingCharacters(in: .whitespaces)
                for marker in ["- ", "* ", "• ", "\u{2022}"] where text.hasPrefix(marker) {
                    text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
                return text
            }
            .filter { !$0.isEmpty }
    }

    public static func placement(for anchor: CodingFileAnchor?, short: Bool = false) -> String? {
        guard let anchor else { return nil }
        let file = short ? (anchor.path as NSString).lastPathComponent : anchor.path
        var parts = [file]
        if let symbol = anchor.symbol { parts.append(symbol) }
        if let line = anchor.line { parts.append(String(line)) }
        return parts.joined(separator: " · ")
    }
}

/// Inline code inside a sentence.
///
/// The panel's prose is full of things that are not prose — `self._raw`,
/// `render()`, `A1`, `'12.00'`, `2018-01-01` — and drawing them in the same
/// proportional face as the words around them makes a sentence like
/// "Raw text is stored verbatim in self._raw: '=A1' at B1, '12' at A1" read as
/// one undifferentiated run. A reader glancing up mid-sentence has to parse it
/// before they can use it.
///
/// Split here rather than in the view so the rule is testable and the same in
/// every place prose is drawn, and coloured with the roles the code block
/// already uses so the notch has one palette rather than two.
public enum CodingProseSpan {
    public enum Role: Equatable, Sendable {
        /// Ordinary words.
        case text
        /// A symbol, a call, or a cell reference.
        case identifier
        /// A quoted literal, kept with its quotes.
        case string
        /// A number or an ISO date.
        case number
    }

    public struct Span: Equatable, Sendable {
        public let text: String
        public let role: Role
        public init(text: String, role: Role) { self.text = text; self.role = role }
        public var isCode: Bool { role != .text }
    }

    /// Ordered: the first alternative that matches at a position wins, so a
    /// quoted literal is taken whole before anything inside it is considered.
    ///
    /// Deliberately conservative about what counts as a symbol. A bare English
    /// word never matches — an identifier has to carry an underscore, a dot or
    /// a call, and a cell reference has to be letters followed by digits. The
    /// failure worth avoiding is highlighting half the sentence, which would
    /// cost the distinction it is meant to create.
    private static let pattern: NSRegularExpression? = {
        let alternatives = [
            "'[^'\n]{0,60}'",
            "\"[^\"\n]{0,60}\"",
            "`[^`\n]{0,60}`",
            // A call: `render()`, `self._evaluate(B1)`, `sheet.formula.parse(x)`.
            "\\b[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*\\s*\\([^()\n]{0,40}\\)",
            // A dotted path: `sheet.models.Range`, `self._raw`.
            "\\b[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)+",
            // snake_case, which in this project is always a symbol.
            "\\b[A-Za-z]*_[A-Za-z0-9_]+\\b",
            // A cell reference or a range: A1, BB10, A1:B3.
            "\\b[A-Za-z]{1,3}[0-9]{1,4}(?::[A-Za-z]{1,3}[0-9]{1,4})?\\b",
            // An ISO date, before the number rule can take the year.
            "\\b[0-9]{4}-[0-9]{2}-[0-9]{2}\\b",
            "\\b[0-9]+(?:\\.[0-9]+)?(?:[eE][-+]?[0-9]+)?\\b",
        ]
        return try? NSRegularExpression(pattern: alternatives.joined(separator: "|"))
    }()

    public static func spans(in sentence: String) -> [Span] {
        guard let pattern, !sentence.isEmpty else {
            return sentence.isEmpty ? [] : [Span(text: sentence, role: .text)]
        }
        let value = sentence as NSString
        var spans: [Span] = []
        var cursor = 0
        func appendText(upTo end: Int) {
            guard end > cursor else { return }
            spans.append(Span(text: value.substring(with: NSRange(location: cursor, length: end - cursor)),
                              role: .text))
        }
        pattern.enumerateMatches(in: sentence, range: NSRange(location: 0, length: value.length)) { match, _, _ in
            guard let match else { return }
            appendText(upTo: match.range.location)
            let text = value.substring(with: match.range)
            spans.append(Span(text: text, role: role(of: text)))
            cursor = match.range.location + match.range.length
        }
        appendText(upTo: value.length)
        return spans
    }

    private static func role(of text: String) -> Role {
        guard let first = text.first else { return .text }
        if first == "'" || first == "\"" { return .string }
        if first == "`" { return .identifier }
        // A leading digit means a number or a date; anything else is a symbol.
        return first.isNumber ? .number : .identifier
    }

    /// Whether a sentence has any code in it at all, so a caller can skip the
    /// styled path entirely for ordinary prose.
    public static func containsCode(_ sentence: String) -> Bool {
        spans(in: sentence).contains { $0.isCode }
    }
}
