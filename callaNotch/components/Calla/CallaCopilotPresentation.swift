import Foundation

/// What the copilot puts in the notch's fixed ~488x130pt slab.
///
/// Pure and separately tested, like `CallaNotchPresentation`. During a live call
/// this surface is read in the half-second before the user has to speak, so the
/// decision of what earns that space is worth being exact about rather than
/// scattering conditionals through SwiftUI.
enum CallaCopilotPresentation {
    enum Mode: String, Equatable {
        /// A call is running and a pointer is on screen.
        case suggesting
        /// A call is running with nothing worth saying yet.
        case listening
        /// A call is running but only our own side is being captured.
        case halfDeaf
        /// Installed and idle.
        case ready
        /// The capture host is missing.
        case unavailable
    }

    enum Tone: String, Equatable {
        case active
        case ready
        case warning
    }

    struct Pill: Equatable {
        let text: String
        let tone: Tone
    }

    static func mode(
        available: Bool,
        running: Bool,
        systemAudioActive: Bool,
        hasSuggestion: Bool
    ) -> Mode {
        guard available else { return .unavailable }
        guard running else { return .ready }
        // Say it plainly when the other party is not being heard: the pointers
        // are built almost entirely from what *they* said, so a mic-only call
        // silently produces near-useless output.
        if !systemAudioActive { return .halfDeaf }
        return hasSuggestion ? .suggesting : .listening
    }

    static func pill(for mode: Mode) -> Pill {
        switch mode {
        // What is being *heard*, not what is connected. "Live" and "Listening"
        // were the same claim twice over and neither said whether the other
        // side was on the recording, which is the thing that silently ruins a
        // call. Only `suggesting` names the copilot's own state, because an
        // answer waiting is worth the word.
        case .suggesting: return Pill(text: "Answer ready", tone: .active)
        case .listening: return Pill(text: "Hearing both sides", tone: .active)
        case .halfDeaf: return Pill(text: "Only you", tone: .warning)
        case .ready: return Pill(text: "Ready", tone: .ready)
        case .unavailable: return Pill(text: "Not installed", tone: .warning)
        }
    }

    /// A short label for which brain answered, or nil when there is nothing worth
    /// saying.
    ///
    /// Shown only when the copilot is *not* on the brain the user chose — that is
    /// the case worth two characters of the slab. Announcing "This Mac" during a
    /// perfectly ordinary local call would spend the space on nothing, but a
    /// silent handover to the gateway looks exactly like a copilot that has gone
    /// vague, and the user would have no way to tell the difference.
    static func providerBadge(active: String?, preferred: String, running: Bool) -> Pill? {
        guard running, let active, active != preferred else { return nil }
        switch active {
        case "gateway": return Pill(text: "Gateway", tone: .warning)
        case "local": return Pill(text: "Agy · Google remote", tone: .active)
        default: return nil
        }
    }

    static func primaryActionTitle(running: Bool) -> String {
        running ? "End call" : "Start call"
    }

    /// Elapsed call time as `m:ss`, or `h:mm:ss` once it earns the hour.
    static func elapsed(since start: Date?, now: Date) -> String? {
        guard let start else { return nil }
        let total = Int(max(0, now.timeIntervalSince(start)))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// What the panel is showing, named once — in the notch's header band rather
    /// than inside the panel.
    ///
    /// The heading used to sit at the top of the answer column, which spent a
    /// line of a short panel on a two-word label while the band above it had
    /// room to spare. Both surfaces read it, so it is computed here rather than
    /// twice.
    static func panelHeading(
        surface: String,
        hasAnswer: Bool,
        hasSummary: Bool,
        mode: Mode,
        working: String?
    ) -> String {
        if let working, !working.isEmpty {
            // The working states outrank the label: four seconds of silence with
            // nothing said about it reads as a panel that has stopped.
            return working
        }
        if mode == .halfDeaf, !hasAnswer { return "Only you" }
        if surface == "question" {
            // The heading names the lane the reader chose, answer or not. It
            // used to fall through to "So far" when there was no answer — so
            // pressing Answers left both the heading and the body claiming to
            // be the recap, and the chip looked like it had done nothing.
            return hasAnswer ? "Answer" : "No answer yet"
        }
        if hasSummary { return "So far" }
        return "Listening"
    }

    /// One status line under the headline.
    static func subtitle(turnCount: Int, elapsed: String?, gatewayConnected: Bool) -> String {
        var parts: [String] = []
        if let elapsed { parts.append(elapsed) }
        if turnCount > 0 { parts.append("\(turnCount) turn\(turnCount == 1 ? "" : "s")") }
        if !gatewayConnected { parts.append("gateway offline") }
        return parts.joined(separator: " · ")
    }

    /// The headline is the question the user has to answer *right now*, so it
    /// gets one line and never wraps the slab open.
    static func headlineLine(_ value: String?, limit: Int = 90) -> String? {
        guard let flattened = flatten(value), !flattened.isEmpty else { return nil }
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Angles that fit the slab. Two at most in the notch — a third is real
    /// content, but reading it costs more time than it saves mid-sentence, so
    /// it lives in the window instead.
    static func angleLines(_ angles: [String], limit: Int = 2, characters: Int = 78) -> [String] {
        angles
            .compactMap { flatten($0) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { $0.count > characters ? String($0.prefix(characters)).trimmingCharacters(in: .whitespaces) + "…" : $0 }
    }

    /// Newlines would grow the slab past the notch shape, so they collapse.
    private static func flatten(_ value: String?) -> String? {
        guard let value else { return nil }
        return value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}

// MARK: - The closed notch, in words

extension CallaCopilotPresentation {
    /// What the closed notch says during a call: a few words left of the
    /// camera, one figure right of it, and the one line a hover adds below.
    ///
    /// The wings used to carry only a glyph and a clock. A glyph has to be
    /// learnt; "Listening" and "Only you" do not, and they are the two facts a
    /// reader in a call actually needs from a glance.
    struct ClosedLine: Equatable {
        let lead: String
        let trail: String
        let tone: Tone
        /// The peek: the line worth reading, and what a click will do.
        let peek: String
        let peekHint: String
    }

    static func closedLine(
        mode: Mode,
        floating: Bool,
        elapsed: String?,
        latestStanding: String?,
        answerHeadline: String?,
        catchingUp: Bool
    ) -> ClosedLine {
        let trail = floating ? "Floating" : (elapsed ?? "0:00")
        let hint = floating ? "Click to bring it back into the notch" : "Click to open"
        switch mode {
        case .suggesting:
            let answer = headlineLine(answerHeadline, limit: 70)
            return ClosedLine(lead: "Answer ready", trail: trail, tone: .warning,
                              peek: answer ?? "An answer is ready",
                              peekHint: floating ? hint : "Click for the full answer")
        case .halfDeaf:
            return ClosedLine(lead: "Only you", trail: trail, tone: .warning,
                              peek: "Their side isn’t coming through",
                              peekHint: "Click to fix it")
        case .listening:
            let standing = headlineLine(latestStanding, limit: 70)
            return ClosedLine(lead: catchingUp ? "Catching up" : "Listening", trail: trail, tone: .active,
                              peek: standing ?? "Hearing you and them. Nothing to do.",
                              peekHint: standing == nil ? "A summary starts after the first minute" : hint)
        case .ready:
            return ClosedLine(lead: "Ready", trail: trail, tone: .ready, peek: "Ready to listen", peekHint: hint)
        case .unavailable:
            return ClosedLine(lead: "Not installed", trail: trail, tone: .warning,
                              peek: "The call host is missing", peekHint: "Click to see how to fix it")
        }
    }
}

// MARK: - Zen

/// What the call says while it rests in zen: the island under the camera when
/// the pointer is away.
///
/// Zen used to draw nothing under the notch until the first summary arrived,
/// minutes into a call, so for the start of every call it looked as though it
/// was not there at all. Now it always says something true, never shows the
/// transcript (that is for the fully open panel), and carries no labels: the
/// one word beside the dot says what is happening.
enum CallaZen {
    /// How much sits under the camera at rest.
    enum Level: String, CaseIterable, Equatable {
        /// The band beside the camera only.
        case dot
        /// The newest point, and the ones before it on one line.
        case brief
        /// Brief, plus what is still open.
        case more

        init(stored: String) {
            self = Level(rawValue: stored) ?? .brief
        }
    }

    /// A new point says "New" beside the dot for this long.
    static let highlightSeconds: TimeInterval = 6

    struct Content: Equatable {
        /// The one word beside the dot.
        let word: String
        let tone: CallaCopilotPresentation.Tone
        /// Up to two lines: the newest point, or before there is one, the meeting.
        let main: String?
        /// The main line is context rather than a point, so it is drawn quieter.
        let mainIsQuiet: Bool
        /// One line under it: the points before, or what is happening.
        let before: String?
        /// `more` only: what is still open.
        let open: String?
        /// Their side is missing; zen carries its one button.
        let needsFix: Bool

        var isEmpty: Bool { main == nil && before == nil && open == nil && !needsFix }
    }

    static func content(
        level: Level,
        halfDeaf: Bool,
        catchingUp: Bool,
        isNew: Bool,
        points: [String],
        openQuestions: [String],
        meetingTitle: String?,
        people: Int,
        heardAnything: Bool
    ) -> Content {
        if halfDeaf {
            // Shown at every level: a call that only hears you quietly produces
            // nothing useful, so this is the one thing zen interrupts for.
            return Content(word: "Only you", tone: .warning,
                           main: "Their side isn’t coming through. You are still being written down.",
                           mainIsQuiet: false, before: nil, open: nil, needsFix: true)
        }
        let points = points.map(flat).filter { !$0.isEmpty }
        let word = isNew && !points.isEmpty ? "New" : (catchingUp ? "Catching up" : "Listening")
        guard level != .dot else {
            return Content(word: word, tone: .active, main: nil, mainIsQuiet: false,
                           before: nil, open: nil, needsFix: false)
        }
        guard let newest = points.last else {
            let title = meetingTitle.map(flat).flatMap { $0.isEmpty ? nil : $0 }
            let crowd = people > 1 ? "\(people) people" : nil
            let main = [title, crowd].compactMap { $0 }.joined(separator: " · ")
            return Content(
                word: word, tone: .active,
                main: main.isEmpty ? nil : main, mainIsQuiet: true,
                before: heardAnything
                    ? "Hearing both sides. The first points come in about a minute."
                    : "Listening started. Nothing said yet.",
                open: nil, needsFix: false)
        }
        let earlier = points.dropLast().suffix(2)
        let open = openQuestions.map(flat).filter { !$0.isEmpty }.prefix(2)
        return Content(
            word: word, tone: .active,
            main: newest, mainIsQuiet: false,
            before: earlier.isEmpty ? nil : earlier.joined(separator: " · "),
            open: level == .more && !open.isEmpty ? open.joined(separator: ", ") : nil,
            needsFix: false)
    }

    private static func flat(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

// MARK: - A meeting getting close

/// How the closed notch treats a linked meeting as its start approaches.
///
/// Calm until it matters, louder one step at a time: a grey time a quarter of
/// an hour out, "Get ready" in blue for the last two minutes, a Join button at
/// the start, an orange reminder if the reader has not joined three minutes
/// in, and quiet again after ten — by then they skipped it on purpose.
enum MeetingApproach {
    enum Phase: String, Equatable {
        case quiet
        case getReady
        case starting
        case late
    }

    /// The grey time appears this far ahead.
    static let quietLead: TimeInterval = 15 * 60
    /// "Get ready". The same two minutes the calendar watch already uses.
    static let readyLead: TimeInterval = 120
    /// Past the start, "Join" turns into a reminder after this…
    static let lateAfter: TimeInterval = 3 * 60
    /// …and the notch lets it go after this.
    static let giveUpAfter: TimeInterval = 10 * 60

    /// The phase, or nil when the notch should say nothing about it.
    static func phase(start: Date, end: Date, now: Date, joined: Bool) -> Phase? {
        guard !joined, now < end else { return nil }
        let lead = start.timeIntervalSince(now)
        if lead > quietLead { return nil }
        if lead > readyLead { return .quiet }
        if lead > 0 { return .getReady }
        let since = -lead
        if since < lateAfter { return .starting }
        if since < giveUpAfter { return .late }
        return nil
    }

    struct Line: Equatable {
        let lead: String
        let trail: String
        let phase: Phase
        let peek: String
        let peekHint: String
        /// The trailing word is a button: clicking the notch joins.
        var joins: Bool { phase == .starting || phase == .late }
    }

    /// The words for a phase. `startTime` arrives formatted for the reader's
    /// locale, so this stays a plain function of its inputs.
    static func line(phase: Phase, title: String, start: Date, now: Date,
                     startTime: String, people: Int, notes: Int) -> Line {
        let short = shortTitle(title)
        let minutesAway = max(1, Int((start.timeIntervalSince(now) / 60).rounded(.up)))
        let minutesIn = max(1, Int((now.timeIntervalSince(start) / 60).rounded(.down)))
        let context = [people > 0 ? "\(people) \(people == 1 ? "person" : "people")" : nil,
                       notes > 0 ? "\(notes) \(notes == 1 ? "note" : "notes") ready" : nil]
            .compactMap { $0 }
        switch phase {
        case .quiet:
            return Line(lead: short, trail: startTime, phase: phase,
                        peek: "\(title) at \(startTime)",
                        peekHint: (["Starts in \(minutesAway) min"] + context).joined(separator: " · "))
        case .getReady:
            return Line(lead: "\(short) · \(minutesAway) min", trail: "Get ready", phase: phase,
                        peek: notes > 0 ? "Ready to listen · \(notes) \(notes == 1 ? "note" : "notes") ready"
                                        : "Ready to listen",
                        peekHint: "Click to see what Calla prepared")
        case .starting:
            return Line(lead: "\(short) · now", trail: "Join", phase: phase,
                        peek: "\(title) is starting",
                        peekHint: "Join opens the link and starts listening")
        case .late:
            return Line(lead: "Started \(minutesIn) min ago", trail: "Join", phase: phase,
                        peek: "\(title) is running without you",
                        peekHint: "Click to join, or wait and it goes quiet")
        }
    }

    /// Short enough for a wing beside the camera.
    static func shortTitle(_ title: String, limit: Int = 16) -> String {
        let flat = title.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard flat.count > limit else { return flat.isEmpty ? "Meeting" : flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Turns strict worker output into content shaped for the Quiz answer card.
///
/// Workers occasionally wrap their answer in a second JSON envelope even
/// though the outer response already followed the schema. That protocol detail
/// must never leak into the notch, including for answers restored from history.
struct QuizAnswerPresentation: Equatable {
    enum Style: Equatable {
        case choice
        case boolean
        case code
        case standard
    }

    let style: Style
    let badge: String?
    let body: String
    let codeLanguage: String?
    let copyText: String

    static func make(answer rawAnswer: String, kind: String) -> Self {
        let answer = unwrapWorkerEnvelope(rawAnswer)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if kind == "code", let fenced = fencedCode(answer) {
            return Self(style: .code, badge: nil, body: fenced.code,
                        codeLanguage: fenced.language, copyText: fenced.code)
        }

        if kind == "singleChoice" || kind == "multipleChoice",
           let choice = choiceParts(answer) {
            return Self(style: .choice, badge: choice.label, body: choice.body,
                        codeLanguage: nil, copyText: answer)
        }

        if kind == "boolean" {
            return Self(style: .boolean, badge: nil, body: answer,
                        codeLanguage: nil, copyText: answer)
        }

        return Self(style: .standard, badge: nil, body: answer,
                    codeLanguage: nil, copyText: answer)
    }

    private static func unwrapWorkerEnvelope(_ value: String) -> String {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```json"), candidate.hasSuffix("```") {
            candidate.removeFirst("```json".count)
            candidate.removeLast(3)
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["answer", "confidence"],
              object["confidence"] is NSNumber,
              let nested = object["answer"] as? String,
              !nested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return value
        }
        return nested
    }

    private static func choiceParts(_ answer: String) -> (label: String, body: String)? {
        let separators = [" — ", " – ", " - "]
        guard let separator = separators.first(where: { answer.contains($0) }),
              let range = answer.range(of: separator) else { return nil }
        let label = answer[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let body = answer[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz, ")
        guard !label.isEmpty, label.count <= 12, !body.isEmpty,
              label.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return (label.uppercased(), body)
    }

    private static func fencedCode(_ answer: String) -> (language: String?, code: String)? {
        guard answer.hasPrefix("```"), answer.hasSuffix("```") else { return nil }
        let withoutOpening = answer.dropFirst(3)
        guard let newline = withoutOpening.firstIndex(of: "\n") else { return nil }
        let languageText = withoutOpening[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
        let code = withoutOpening[withoutOpening.index(after: newline)...].dropLast(3)
            .trimmingCharacters(in: .newlines)
        guard !code.isEmpty else { return nil }
        return (languageText.isEmpty ? nil : languageText, String(code))
    }
}

// MARK: - The recap

/// What the recap panel shows after a call, sorted out of the host's items.
///
/// The host files every line as a decision, a commitment, an action item or an
/// open question. The panel reads them as three things a person acts on: what
/// was decided, what is still open, and what someone has to do.
enum CallaRecapPresentation {
    struct Item: Equatable {
        let kind: String
        let text: String
        let resolved: Bool
    }

    struct Sections: Equatable {
        var decided: [String] = []
        var open: [String] = []
        var todo: [String] = []

        var isEmpty: Bool { decided.isEmpty && open.isEmpty && todo.isEmpty }
    }

    /// The kind as the host spells it, in either casing it has used.
    private static func normalized(_ kind: String) -> String {
        kind.lowercased().replacingOccurrences(of: "_", with: "")
    }

    static func sections(_ items: [Item]) -> Sections {
        var sections = Sections()
        for item in items {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch normalized(item.kind) {
            case "decision": sections.decided.append(text)
            case "actionitem", "commitment": sections.todo.append(text)
            case "openquestion" where !item.resolved: sections.open.append(text)
            default: break
            }
        }
        return sections
    }

    /// "32 min" beside the state word, when the length is known.
    static func length(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// A follow-up the reader can paste into an email and edit. Only what the
    /// recap says, in its words; nothing is added that the call did not hold.
    static func followUpEmail(title: String?, overview: String, sections: Sections) -> String {
        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? "our call"
        var lines = ["Subject: Follow-up: \(name)", "", "Hi all,", "", "Thanks for the time today."]
        let summary = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { lines += ["", summary] }
        func list(_ heading: String, _ entries: [String]) {
            guard !entries.isEmpty else { return }
            lines += ["", heading] + entries.map { "- \($0)" }
        }
        list("What we decided", sections.decided)
        list("Next steps", sections.todo)
        list("Still open", sections.open)
        lines += ["", "Thanks,"]
        return lines.joined(separator: "\n")
    }
}

// MARK: - Screen sharing

/// Whether the screen looks like it is being shared, from the windows on it.
///
/// macOS has no API that says another app is sharing the screen, but every call
/// app puts up a window that says so — Zoom's share toolbar, the browser's
/// "is sharing your screen" bar under Meet, Teams' sharing control bar. Their
/// names are readable with the Screen Recording permission Calla already has to
/// hear the other side.
enum CallaScreenShareHeuristic {
    struct Window: Equatable {
        let owner: String
        let name: String
    }

    private static let phrases = [
        "is sharing your screen", "is sharing a window", "is sharing your", "is sharing this tab",
        "you are sharing", "you're sharing", "sharing control bar", "sharing toolbar",
        "share toolbar", "stop sharing", "stop share", "screen share"
    ]
    /// Apps whose own windows are named after sharing without anything being shared.
    private static let ignoredOwners = ["system settings", "system preferences", "screen sharing"]

    static func isSharing(_ windows: [Window]) -> Bool {
        windows.contains { window in
            let name = window.name.lowercased()
            guard !name.isEmpty, !ignoredOwners.contains(window.owner.lowercased()) else { return false }
            if window.owner.lowercased().hasPrefix("zoom"), name.contains("share") { return true }
            return phrases.contains { name.contains($0) }
        }
    }
}
