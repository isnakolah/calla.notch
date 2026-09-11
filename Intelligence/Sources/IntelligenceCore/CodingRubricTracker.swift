import CallaContracts
import Foundation

/// What the brief asked for, and how much of it has actually happened.
///
/// This is the single largest source of directive advice the copilot has. "You
/// have not stated the complexity and there are nine minutes left" is worth more
/// than any observation about the code, and none of it needs a model — it is a
/// checklist, in the aviation sense, kept against evidence.
///
/// Coverage moves in one direction only. An item that was spoken stays spoken
/// even if the candidate never mentions it again; the interviewer heard it.
public struct CodingRubricTracker: Sendable, Equatable {
    public private(set) var states: [CodingRubricState]

    public init(brief: InterviewBrief?) {
        states = (brief?.items ?? []).map {
            CodingRubricState(id: $0.id, kind: $0.kind, text: $0.text, status: .open)
        }
    }

    /// Items still worth spending time on, most valuable first.
    ///
    /// Deprioritised items are excluded even when open: the brief said not to
    /// spend time there, and nagging about them is how a copilot burns the clock
    /// it is supposed to be protecting.
    public var open: [CodingRubricState] {
        states.filter { $0.status != .verified && $0.kind != .deprioritised }
            .sorted { Self.weight($0.kind) < Self.weight($1.kind) }
    }

    public var verifiedFraction: Double {
        let scored = states.filter { $0.kind != .deprioritised }
        guard !scored.isEmpty else { return 1 }
        let done = scored.filter { $0.status == .implemented || $0.status == .verified }
        return Double(done.count) / Double(scored.count)
    }

    /// The candidate said something. Match it against the open items.
    ///
    /// Keyword overlap rather than a model call, and biased toward *not*
    /// matching: a false "spoken" silently removes the one prompt that would
    /// have made the candidate say it out loud, which is the expensive mistake
    /// here. A false miss only costs a redundant nudge.
    public mutating func noteSpoken(_ text: String) {
        let said = Self.significantWords(text)
        guard said.count >= 2 else { return }
        for index in states.indices where states[index].status == .open {
            let wanted = Self.significantWords(states[index].text)
            guard wanted.count >= 2 else { continue }
            let hits = wanted.filter { word in said.contains { $0.hasPrefix(word) || word.hasPrefix($0) } }
            // Two thirds of the item's own words, and never on a single hit.
            if hits.count >= 2, Double(hits.count) / Double(wanted.count) >= 0.6 {
                states[index].status = .spoken
                states[index].evidence = "said"
            }
        }
    }

    /// Files changed. Anything an item names by path or symbol is implemented.
    public mutating func noteImplemented(paths: [String], revision: String) {
        guard !paths.isEmpty else { return }
        let haystack = paths.joined(separator: " ").lowercased()
        for index in states.indices where states[index].status == .open || states[index].status == .spoken {
            let wanted = Self.significantWords(states[index].text)
            guard wanted.contains(where: { haystack.contains($0) }) else { continue }
            states[index].status = .implemented
            states[index].evidence = String(revision.prefix(12))
        }
    }

    /// A check proved something. Only a satisfied verdict promotes.
    public mutating func noteVerified(expected: String?, verdict: CodingVerdict, runID: String) {
        guard verdict == .satisfied else { return }
        for index in states.indices where states[index].status != .verified {
            guard states[index].status == .implemented || states[index].status == .spoken else { continue }
            if let expected, !expected.isEmpty,
               !CodingRunVerdictJudge.matches(states[index].text, in: expected),
               !CodingRunVerdictJudge.matches(expected, in: states[index].text) { continue }
            states[index].status = .verified
            states[index].evidence = "run \(String(runID.prefix(8)))"
        }
    }

    /// Ordering for what to raise first. A constraint the candidate is about to
    /// violate matters more than an unspoken nicety.
    private static func weight(_ kind: CodingBriefItemKind) -> Int {
        switch kind {
        case .constraint: 0
        case .rubric: 1
        case .suppliedInterface: 2
        case .task: 3
        case .deprioritised: 4
        }
    }

    static func significantWords(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopWords.contains($0) })
    }

    private static let stopWords: Set<String> = [
        "the", "and", "that", "with", "from", "this", "have", "been", "will",
        "your", "must", "should", "when", "then", "than", "into", "each", "some",
        "make", "sure", "using", "used", "also", "very", "more", "most", "case"
    ]
}
