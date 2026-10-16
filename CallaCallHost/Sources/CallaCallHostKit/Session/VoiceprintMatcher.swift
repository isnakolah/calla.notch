import Foundation
import IntelligenceStore

/// Recognises remembered voices on a new call.
///
/// One-to-one and greedy by score: the strongest cluster–person pair is fixed
/// first, then neither can be used again, so two voices on one call can never
/// both become "Sarah". A match must clear an absolute floor and beat that
/// cluster's runner-up by a margin; a near tie is left for the naming pass
/// rather than guessed.
public enum VoiceprintMatcher {
    public struct Match: Equatable, Sendable {
        public var label: String
        public var personID: String
        public var displayName: String
        public var score: Float
    }

    /// Cosine similarity a WeSpeaker embedding must reach. Conservative: a wrong
    /// name the user did not choose is worse than "Speaker 2".
    public static let minimumScore: Float = 0.65
    /// How far the best person must lead the next best for the same voice.
    public static let minimumMargin: Float = 0.05

    public static func match(clusters: [String: [Float]], voiceprints: [Voiceprint]) -> [Match] {
        guard !clusters.isEmpty, !voiceprints.isEmpty else { return [] }

        var eligible: [Match] = []
        for (label, embedding) in clusters {
            let scored = voiceprints
                .map { (print: $0, score: VoiceVector.cosine(embedding, $0.embedding)) }
                .sorted { $0.score > $1.score }
            guard let best = scored.first, best.score >= minimumScore else { continue }
            if scored.count > 1, best.score - scored[1].score < minimumMargin { continue }
            eligible.append(Match(label: label, personID: best.print.personID,
                                  displayName: best.print.displayName, score: best.score))
        }

        var usedLabels = Set<String>()
        var usedPeople = Set<String>()
        var matches: [Match] = []
        for candidate in eligible.sorted(by: { $0.score > $1.score }) {
            guard !usedLabels.contains(candidate.label), !usedPeople.contains(candidate.personID) else { continue }
            usedLabels.insert(candidate.label)
            usedPeople.insert(candidate.personID)
            matches.append(candidate)
        }
        return matches.sorted { $0.label < $1.label }
    }
}
