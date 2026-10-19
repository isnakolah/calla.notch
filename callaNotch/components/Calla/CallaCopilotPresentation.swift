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
