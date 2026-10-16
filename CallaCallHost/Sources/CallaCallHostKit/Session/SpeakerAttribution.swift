import Foundation

/// One stretch of system audio the diarizer attributed to a single voice, in
/// seconds on the call clock.
public struct DiarizedSpan: Codable, Hashable, Sendable {
    /// The diarizer's own cluster id. Stable within one call only.
    public var speakerID: String
    public var start: Double
    public var end: Double

    public init(speakerID: String, start: Double, end: Double) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

/// Maps transcript turns onto diarized speakers.
///
/// Overlap assignment, numbering and the nearest-span fallback are ported from
/// Muesli's `TranscriptFormatter` (MIT, github.com/pHequals7/muesli). The archive
/// pass gives whisper segment timestamps, so each turn is short enough that the
/// voice with the most overlap is the right answer far more often than not.
public enum SpeakerAttribution {
    /// The speaker id every mic turn carries. The mic leg is only ever the user.
    public static let localSpeakerID = "me"

    /// How far a turn may sit from any span and still borrow its speaker.
    /// whisper's segment edges drift by a few hundred milliseconds; beyond two
    /// seconds the nearest voice is a guess.
    public static let maxNearestGapSeconds = 2.0

    /// Diarizer ids renamed to `S1`, `S2`, … in order of first appearance, so the
    /// labels read top-down the way the call went.
    public static func numbering(_ spans: [DiarizedSpan]) -> [String: String] {
        var map: [String: String] = [:]
        var next = 1
        for span in spans.sorted(by: { $0.start < $1.start }) where map[span.speakerID] == nil {
            map[span.speakerID] = "S\(next)"
            next += 1
        }
        return map
    }

    /// The diarizer id for one remote turn, or nil when no voice is close enough.
    public static func speaker(forTurnFrom t0: Double, to t1: Double, in spans: [DiarizedSpan]) -> String? {
        let ids = Set(spans.map(\.speakerID))
        if ids.count == 1 { return ids.first }

        let start = t0
        let end = max(t1, t0 + 0.1)
        var best: (id: String, overlap: Double)?
        for span in spans {
            let overlap = min(end, span.end) - max(start, span.start)
            guard overlap > 0 else { continue }
            if overlap > (best?.overlap ?? 0) { best = (span.speakerID, overlap) }
        }
        if let best { return best.id }

        let midpoint = (start + end) / 2
        let nearest = spans.min { gap(midpoint, $0) < gap(midpoint, $1) }
        guard let nearest, gap(midpoint, nearest) <= maxNearestGapSeconds else { return nil }
        return nearest.speakerID
    }

    /// The outcome of attributing one transcript revision.
    public struct Assignment: Equatable, Sendable {
        /// `seq` → `me`, `S1`, `S2`, …; remote turns no voice matched are absent.
        public var turns: [Int: String]
        /// Diarizer id → the label it was given. Only voices that own at least one
        /// turn get a label, so the numbering has no gaps.
        public var labels: [String: String]
    }

    /// A speaker for every turn. Mic turns are always `me`; remote voices are
    /// numbered `S1`, `S2`, … in the order they first speak in the transcript.
    public static func assign(turns: [(seq: Int, isLocal: Bool, t0: Double, t1: Double)],
                              spans: [DiarizedSpan]) -> Assignment {
        var labels: [String: String] = [:]
        var result: [Int: String] = [:]
        for turn in turns.sorted(by: { $0.t0 < $1.t0 }) {
            if turn.isLocal {
                result[turn.seq] = localSpeakerID
                continue
            }
            guard let id = speaker(forTurnFrom: turn.t0, to: turn.t1, in: spans) else { continue }
            let label = labels[id] ?? {
                let next = "S\(labels.count + 1)"
                labels[id] = next
                return next
            }()
            result[turn.seq] = label
        }
        return Assignment(turns: result, labels: labels)
    }

    /// Seconds of speech per diarizer id.
    public static func speechSeconds(_ spans: [DiarizedSpan]) -> [String: Double] {
        spans.reduce(into: [:]) { $0[$1.speakerID, default: 0] += max(0, $1.end - $1.start) }
    }

    private static func gap(_ point: Double, _ span: DiarizedSpan) -> Double {
        if point < span.start { return span.start - point }
        if point > span.end { return point - span.end }
        return 0
    }
}
