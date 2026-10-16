import Foundation
import IntelligenceCore
import IntelligenceProviders
import os.log

private let namerLog = Logger(subsystem: "theboringteam.boringnotch.callhost", category: "speakers")

/// Guesses who the unnamed voices on a call were, from what was said.
///
/// The evidence is conversational: "thanks, Sarah" just before a voice speaks,
/// "this is Tom from billing", an attendee list that leaves one name over. The
/// model may only answer with a calendar attendee or a name that was actually
/// spoken, and only above a confidence floor; anything else stays "Speaker N".
/// A guess is shown with a question mark until the user confirms it, and only
/// a confirmed name ever teaches the voiceprint store.
public enum SpeakerNamer {
    public static let task = IntelligenceTask(
        id: "copilot.speakers",
        defaultTier: .balanced,
        contract: .json(keys: ["speakers"]),
        latencyBudget: 90,
        conversation: .oneShot,
        batching: .manual,
        allowedProviders: [.localAgy]
    )

    /// Below this a guess is not shown at all.
    public static let minimumConfidence = 0.6
    /// Rough cap on the transcript excerpt, in characters.
    static let excerptBudget = 12_000

    static let system = """
    You identify the speakers in a meeting transcript. Voices were separated \
    automatically and labelled S1, S2, …; "me" is the person who recorded the call.

    For each unlabelled speaker you are asked about, give their name only when the \
    transcript supports it: they introduce themselves, someone addresses them by \
    name right before they speak, or someone refers to them in a way that leaves \
    exactly one attendee. Prefer the attendee's full name as written in the \
    attendee list. Never name "me", never give two speakers the same name, and \
    leave a speaker out when you are unsure — a wrong name is worse than none.

    Reply with JSON only:
    {"speakers": [{"speaker": "S2", "name": "Full Name", "confidence": 0.0-1.0, \
    "evidence": "the words that show it"}]}
    """

    /// A namer bound to the user's local provider. Nil when the user runs
    /// without one: the pass then simply leaves voices as "Speaker N".
    public static func local(runtimeRoot: URL, exactModel: String?) -> SpeakerPass.Namer {
        { request in
            let provider = AgyProvider(configuration: .init(runtimeRoot: runtimeRoot))
            let router = IntelligenceRouter(
                providers: [provider],
                policy: .init(preferred: [task.id: .localAgy], fallbackEnabled: false))
            defer { Task { await provider.shutdown() } }
            do {
                let response = try await router.respond(to: IntelligenceRequest(
                    task: task,
                    system: PromptBlocks(base: system),
                    input: prompt(for: request),
                    tier: .balanced,
                    exactModel: exactModel,
                    priority: .offline,
                    queuePolicy: .fifo))
                guard let payload = response.payload else { return [:] }
                return accept(try parse(payload), for: request)
            } catch {
                namerLog.error("speaker naming failed: \(String(describing: error), privacy: .public)")
                return [:]
            }
        }
    }

    // MARK: - Prompt

    static func prompt(for request: SpeakerNamingRequest) -> String {
        var sections: [String] = []
        sections.append(request.attendees.isEmpty
            ? "Attendees: unknown."
            : "Attendees (from the calendar; may include \"me\"):\n" + request.attendees.map { "- \($0)" }.joined(separator: "\n"))
        if !request.knownNames.isEmpty {
            sections.append("Already identified by voice: " + request.knownNames.joined(separator: ", ") + ".")
        }
        sections.append("Name these speakers if you can: " + request.unnamed.joined(separator: ", ") + ".")
        sections.append("Transcript:\n" + excerpt(request).joined(separator: "\n"))
        return sections.joined(separator: "\n\n")
    }

    /// The transcript lines worth reading, within budget.
    ///
    /// Short calls go whole. Long ones keep each unnamed voice's first lines,
    /// every line that mentions a name or an introduction, and the line either
    /// side of those — which is where "over to you, Priya" and the reply sit.
    static func excerpt(_ request: SpeakerNamingRequest) -> [String] {
        let lines = request.turns.map(render)
        if lines.reduce(0, { $0 + $1.count + 1 }) <= excerptBudget { return lines }

        let nameTokens = Set(request.attendees.flatMap(nameTokens))
        var keep = Set<Int>()
        var firstLines: [String: Int] = [:]
        for (index, turn) in request.turns.enumerated() {
            if request.unnamed.contains(turn.speakerID), firstLines[turn.speakerID, default: 0] < 3 {
                firstLines[turn.speakerID, default: 0] += 1
                keep.insert(index)
            }
            let lowered = turn.text.lowercased()
            let words = Set(lowered.split(whereSeparator: { !$0.isLetter }).map(String.init))
            if !words.isDisjoint(with: nameTokens) || introductions.contains(where: lowered.contains) {
                keep.formUnion([index - 1, index, index + 1])
            }
        }
        var out: [String] = []
        var used = 0
        var previous = -2
        for index in keep.sorted() where lines.indices.contains(index) {
            let line = lines[index]
            guard used + line.count < excerptBudget else { break }
            if index != previous + 1, !out.isEmpty { out.append("…") }
            out.append(line)
            used += line.count + 1
            previous = index
        }
        return out
    }

    static let introductions = ["i'm ", "i am ", "this is ", "my name", "here from", "speaking", "joining"]

    static func render(_ line: SpeakerNamingRequest.Line) -> String {
        let total = max(0, Int(line.t0))
        let who = line.knownName.map { "\(line.speakerID) (\($0))" } ?? line.speakerID
        return String(format: "[%d:%02d] ", total / 60, total % 60) + "\(who): \(line.text)"
    }

    static func nameTokens(_ name: String) -> [String] {
        let local = name.split(separator: "@").first.map(String.init) ?? name
        return local.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    // MARK: - Reply

    private struct Payload: Decodable {
        struct Entry: Decodable {
            var speaker: String
            var name: String?
            var confidence: Double?
            var evidence: String?
        }
        var speakers: [Entry]
    }

    static func parse(_ payload: Data) throws -> [String: SpeakerNameGuess] {
        let decoded = try JSONDecoder().decode(Payload.self, from: payload)
        var out: [String: SpeakerNameGuess] = [:]
        for entry in decoded.speakers {
            guard let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            out[entry.speaker] = SpeakerNameGuess(name: name, confidence: entry.confidence ?? 0, evidence: entry.evidence)
        }
        return out
    }

    /// Keeps only guesses the transcript and calendar can back.
    ///
    /// A name must be an attendee — matched on full name, or on a first name
    /// only one attendee has, and then written the way the calendar writes it —
    /// or a name that was actually said on the call. Only labels the pass asked
    /// about, and only above the confidence floor.
    static func accept(_ guesses: [String: SpeakerNameGuess], for request: SpeakerNamingRequest) -> [String: SpeakerNameGuess] {
        let spoken = Set(request.turns.flatMap { turn in
            turn.text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        })
        var out: [String: SpeakerNameGuess] = [:]
        for (label, guess) in guesses where request.unnamed.contains(label) && guess.confidence >= minimumConfidence {
            if let attendee = attendee(matching: guess.name, in: request.attendees) {
                out[label] = SpeakerNameGuess(name: attendee, confidence: guess.confidence, evidence: guess.evidence)
            } else {
                let tokens = nameTokens(guess.name)
                guard !tokens.isEmpty, tokens.allSatisfy(spoken.contains) else { continue }
                out[label] = guess
            }
        }
        return out
    }

    static func attendee(matching name: String, in attendees: [String]) -> String? {
        let wanted = nameTokens(name)
        guard !wanted.isEmpty else { return nil }
        if let exact = attendees.first(where: { nameTokens($0) == wanted }) { return display(exact) }
        let byFirst = attendees.filter { nameTokens($0).first == wanted.first }
        return byFirst.count == 1 ? display(byFirst[0]) : nil
    }

    /// An attendee as a person's name: "sarah.chen@acme.com" reads "Sarah Chen".
    static func display(_ attendee: String) -> String {
        guard attendee.contains("@") else { return attendee }
        let local = attendee.split(separator: "@").first.map(String.init) ?? attendee
        return local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
