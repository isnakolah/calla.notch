import CallaContracts
import Foundation

/// What one call's readable folder contains, worked out from the call's own
/// records. Pure: no file system, no clock, no store — the engine gathers the
/// inputs and writes the result, and this is what the tests exercise.
///
/// The folder mirrors the private call directory and the store; it is never
/// read back. Editing `summary.md` changes nothing the app relies on.
public enum CallFolderExport {
    public struct Turn: Equatable, Sendable {
        public var seq: Int
        public var isMe: Bool
        public var t0: Double
        public var text: String
        /// The diarized speaker's name ("Sarah Chen", "Speaker 2") once the
        /// after-call speaker pass has run; nil falls back to Me/Them.
        public var speaker: String?
        public init(seq: Int, isMe: Bool, t0: Double, text: String, speaker: String? = nil) {
            self.seq = seq; self.isMe = isMe; self.t0 = t0; self.text = text; self.speaker = speaker
        }

        var who: String { isMe ? "Me" : (speaker ?? "Them") }
    }

    public struct Answer: Equatable, Sendable {
        public var afterSeq: Int
        public var headline: String
        public var angles: [String]
        public var confirm: [String]
        public init(afterSeq: Int, headline: String, angles: [String] = [], confirm: [String] = []) {
            self.afterSeq = afterSeq; self.headline = headline; self.angles = angles; self.confirm = confirm
        }
    }

    public struct Note: Equatable, Sendable {
        public var title: String
        public var body: String
        public init(title: String, body: String) { self.title = title; self.body = body }
    }

    /// A screenshot taken during the call, already copied beside the call.
    public struct Capture: Equatable, Sendable {
        /// File name inside the call directory's `captures/`.
        public var file: String
        /// Seconds since the call started.
        public var offset: Double
        /// What could be read in it, for the summary and for search.
        public var text: String
        public init(file: String, offset: Double, text: String) {
            self.file = file; self.offset = offset; self.text = text
        }
    }

    public struct Meeting: Equatable, Sendable {
        public var title: String?
        public var attendees: [String]
        public var location: String?
        public var notes: String?
        public init(title: String? = nil, attendees: [String] = [], location: String? = nil, notes: String? = nil) {
            self.title = title; self.attendees = attendees; self.location = location; self.notes = notes
        }
    }

    public struct Input: Sendable {
        public var callID: String
        public var persona: String
        public var startedAt: Date
        public var endedAt: Date?
        public var interrupted: Bool
        public var meeting: Meeting
        public var recap: CallRecapDraft?
        public var turns: [Turn]
        /// True when `turns` came from the after-call pass.
        public var accurateTranscript: Bool
        public var answers: [Answer]
        public var notes: [Note]
        public var captures: [Capture]
        public init(callID: String, persona: String, startedAt: Date, endedAt: Date? = nil,
                    interrupted: Bool = false, meeting: Meeting = Meeting(), recap: CallRecapDraft? = nil,
                    turns: [Turn] = [], accurateTranscript: Bool = false, answers: [Answer] = [],
                    notes: [Note] = [], captures: [Capture] = []) {
            self.callID = callID; self.persona = persona; self.startedAt = startedAt; self.endedAt = endedAt
            self.interrupted = interrupted; self.meeting = meeting; self.recap = recap; self.turns = turns
            self.accurateTranscript = accurateTranscript; self.answers = answers; self.notes = notes
            self.captures = captures
        }
    }

    // MARK: - Naming

    /// What the call is called. A ceremony is named after its meeting — every
    /// standup is a standup — while any other call is named by what it was
    /// about, which is what makes a folder of them browsable.
    public static func title(for input: Input) -> String {
        let event = clean(input.meeting.title)
        let generated = clean(input.recap?.title)
        let kind = CallaPersonaCatalog.title(input.persona)
        let chosen = CallaPersonaCatalog.isCeremony(input.persona)
            ? (event ?? kind)
            : (generated ?? event ?? (input.persona == "generic" ? "Call" : kind))
        return input.interrupted ? chosen + " (interrupted)" : chosen
    }

    /// `<Type>/<yyyy-MM-dd HHmm> <title>`, relative to the Calls root.
    public static func folderPath(for input: Input, timeZone: TimeZone = .current) -> String {
        let type = sanitize(CallaPersonaCatalog.folderName(input.persona), limit: 40)
        let stamp = format(input.startedAt, "yyyy-MM-dd HHmm", timeZone)
        let name = sanitize("\(stamp) \(title(for: input))", limit: 90)
        return "\(type)/\(name)"
    }

    /// Safe as one path component on APFS and in Finder. Strips separators and
    /// control characters, collapses whitespace, and never returns empty or a
    /// dot-name that would hide the folder.
    public static func sanitize(_ raw: String, limit: Int = 90) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.newlines)
        let replaced = raw.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        var words = replaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while words.hasPrefix(".") { words.removeFirst() }
        if words.count > limit { words = String(words.prefix(limit)).trimmingCharacters(in: .whitespaces) }
        return words.isEmpty ? "Call" : words
    }

    /// A free name next to `taken`: "Retro", "Retro 2", "Retro 3"…
    public static func unique(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        var index = 2
        while taken.contains("\(name) \(index)") { index += 1 }
        return "\(name) \(index)"
    }

    // MARK: - Files

    public static func files(for input: Input, timeZone: TimeZone = .current) -> [String: String] {
        var files = [
            "summary.md": summary(input, timeZone: timeZone),
            "transcript.md": transcript(input),
        ]
        if input.answers.contains(where: { !$0.headline.isEmpty || !$0.angles.isEmpty }) {
            files["answers.md"] = answers(input)
        }
        if let invite = clean(input.meeting.notes) {
            files["notes/meeting-invite.md"] = "# \(input.meeting.title ?? "Meeting invite")\n\n\(invite)\n"
        }
        for capture in input.captures {
            let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let base = (capture.file as NSString).deletingPathExtension
            files["screenshots/\(base).txt"] = text + "\n"
        }
        var taken = Set<String>()
        for note in input.notes {
            let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let name = unique(sanitize(note.title.isEmpty ? "Note" : note.title, limit: 60), taken: taken)
            taken.insert(name)
            files["notes/\(name).md"] = "# \(note.title.isEmpty ? "Note" : note.title)\n\n\(body)\n"
        }
        return files
    }

    public static func summary(_ input: Input, timeZone: TimeZone = .current) -> String {
        var lines = ["# \(title(for: input))", ""]
        var facts = ["**When:** \(format(input.startedAt, "EEEE d MMMM yyyy, HH:mm", timeZone))"
            + (input.endedAt.map { "–\(format($0, "HH:mm", timeZone))" } ?? "")]
        if let end = input.endedAt {
            facts.append("**Length:** \(duration(end.timeIntervalSince(input.startedAt)))")
        }
        facts.append("**Type:** \(CallaPersonaCatalog.title(input.persona))")
        if let event = clean(input.meeting.title), event != title(for: input) {
            facts.append("**Meeting:** \(event)")
        }
        if !input.meeting.attendees.isEmpty {
            facts.append("**With:** \(input.meeting.attendees.joined(separator: ", "))")
        }
        lines.append(facts.joined(separator: "  \n"))
        lines.append("")

        guard let recap = input.recap,
              !(recap.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && recap.items.isEmpty)
        else {
            lines.append("_No summary was produced for this call. The transcript is complete._")
            appendCaptures(input, to: &lines)
            return lines.joined(separator: "\n") + "\n"
        }
        let overview = recap.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overview.isEmpty { lines += ["## Overview", "", overview, ""] }
        section("Decisions", recap.items.filter { $0.kind == .decision }.map { "- \($0.text)" }, into: &lines)
        section("Action items", recap.items.filter { $0.kind == .actionItem || $0.kind == .commitment }
            .map { "- [\($0.resolved ? "x" : " ")] \($0.text)" }, into: &lines)
        section("Open questions", recap.items.filter { $0.kind == .openQuestion }.map { "- \($0.text)" }, into: &lines)
        appendCaptures(input, to: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func transcript(_ input: Input) -> String {
        var lines = ["# Transcript — \(title(for: input))", ""]
        lines.append(input.accurateTranscript
            ? "_Accurate after-call transcription._"
            : "_Live transcription. Replaced by the more accurate after-call pass when it finishes._")
        lines.append("")
        if input.turns.isEmpty { lines.append("_Nothing was transcribed._") }
        var captures = input.captures.sorted { $0.offset < $1.offset }[...]
        for turn in input.turns.sorted(by: { $0.seq < $1.seq }) {
            while let next = captures.first, next.offset <= turn.t0 {
                lines.append("![Screenshot at \(clock(next.offset))](screenshots/\(next.file))")
                lines.append("")
                captures = captures.dropFirst()
            }
            lines.append("**[\(clock(turn.t0))] \(turn.who):** \(turn.text)")
            lines.append("")
        }
        for capture in captures {
            lines.append("![Screenshot at \(clock(capture.offset))](screenshots/\(capture.file))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// What the copilot said, each next to the turn it answered — the advice is
    /// only interpretable beside what prompted it.
    public static func answers(_ input: Input) -> String {
        var lines = ["# Copilot answers — \(title(for: input))", ""]
        let turns = Dictionary(input.turns.map { ($0.seq, $0) }, uniquingKeysWith: { first, _ in first })
        for answer in input.answers.sorted(by: { $0.afterSeq < $1.afterSeq }) {
            guard !answer.headline.isEmpty || !answer.angles.isEmpty else { continue }
            if let turn = turns[answer.afterSeq] {
                lines.append("> **[\(clock(turn.t0))] \(turn.who):** \(turn.text)")
                lines.append("")
            }
            if !answer.headline.isEmpty { lines.append("**\(answer.headline)**") }
            lines += answer.angles.map { "- \($0)" }
            lines += answer.confirm.map { "- _Check:_ \($0)" }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The previous calls of one kind, as a block of prompt context.
    public static func continuity(persona: String, entries: [(startedAt: Date?, draft: CallRecapDraft)],
                                  limit: Int, timeZone: TimeZone = .current) -> String? {
        guard !entries.isEmpty else { return nil }
        let kind = CallaPersonaCatalog.title(persona)
        var block = "Previous \(kind.lowercased()) meetings, newest first:"
        for entry in entries {
            var part = "\n\n" + (entry.startedAt.map { format($0, "EEE d MMM", timeZone) } ?? "Earlier") + ":"
            let overview = entry.draft.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !overview.isEmpty { part += " " + overview }
            let open = entry.draft.items.filter { !$0.resolved && $0.kind != .decision }
            if !open.isEmpty { part += "\nStill open: " + open.map(\.text).joined(separator: "; ") }
            guard block.count + part.count <= limit else { break }
            block += part
        }
        return block
    }

    // MARK: - Helpers

    private static func appendCaptures(_ input: Input, to lines: inout [String]) {
        guard !input.captures.isEmpty else { return }
        lines += ["## Screenshots", ""]
        // Pictures only: the words read from a screen are mostly menu bars
        // and tabs. They sit beside each image as a .txt, for search.
        for capture in input.captures.sorted(by: { $0.offset < $1.offset }) {
            lines.append("![Screenshot at \(clock(capture.offset))](screenshots/\(capture.file))")
            lines.append("")
        }
    }

    private static func section(_ title: String, _ items: [String], into lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines += ["## \(title)", ""] + items + [""]
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
