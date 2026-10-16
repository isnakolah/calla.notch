import Foundation
import IntelligenceStore
import os.log

private let speakerLog = Logger(subsystem: "theboringteam.boringnotch.callhost", category: "speakers")

/// Works out who said what once a call is over.
///
/// Diarizes system audio, hands each remote turn to the voice that was talking,
/// recognises remembered voices, and asks the naming pass about the rest. Runs
/// after the archive re-transcription so it labels the transcript History
/// actually shows, and labels the live revision too so both views agree.
///
/// Best-effort throughout: any failure leaves the transcript as You/Them, which
/// is exactly what it was before this pass existed.
public enum SpeakerPass {
    public struct Outcome: Sendable, Equatable {
        public var remoteSpeakers: Int
        public var recognised: Int
        public var guessed: Int
    }

    /// Guesses names for unrecognised voices from what was said. Returns
    /// `label → guess`; a label left out keeps its "Speaker N" name.
    public typealias Namer = @Sendable (SpeakerNamingRequest) async -> [String: SpeakerNameGuess]

    public static func run(
        callDirectory: URL,
        store: CallaStore,
        namer: Namer? = nil
    ) async throws -> Outcome? {
        let callID = callDirectory.lastPathComponent
        let systemAudio = callDirectory.appendingPathComponent("system.wav")
        let size = (try? FileManager.default.attributesOfItem(atPath: systemAudio.path)[.size] as? NSNumber)??.intValue ?? 0
        // Header only: nobody else was heard.
        guard size > 8192, ArchiveDiarizer.isSupported else { return nil }

        let diarized = try await ArchiveDiarizer.diarize(systemAudio: systemAudio)
        guard !diarized.spans.isEmpty else { return nil }

        let best = try await store.bestRevision(forCall: callID)
        let bestTurns = try await store.turns(forCall: callID, revision: best)
        let assignment = SpeakerAttribution.assign(
            turns: bestTurns.map { ($0.seq, $0.source == SpeakerAttribution.localSpeakerID, $0.t0, $0.t1) },
            spans: diarized.spans)
        try await store.assignTurnSpeakers(assignment.turns, callID: callID, revision: best)

        // The live revision has its own seq numbering and coarser turns, but the
        // same clock, so the same voices map onto it directly.
        if best != StoredTurn.liveRevision {
            let liveTurns = try await store.turns(forCall: callID, revision: StoredTurn.liveRevision)
            var live: [Int: String] = [:]
            for turn in liveTurns {
                if turn.source == SpeakerAttribution.localSpeakerID {
                    live[turn.seq] = SpeakerAttribution.localSpeakerID
                } else if let id = SpeakerAttribution.speaker(forTurnFrom: turn.t0, to: turn.t1, in: diarized.spans),
                          let label = assignment.labels[id] {
                    live[turn.seq] = label
                }
            }
            try await store.assignTurnSpeakers(live, callID: callID, revision: StoredTurn.liveRevision)
        }

        let seconds = SpeakerAttribution.speechSeconds(diarized.spans)
        var speakers: [String: CallSpeaker] = [:]
        for (diarizerID, label) in assignment.labels {
            speakers[label] = CallSpeaker(
                speakerID: label,
                speechSeconds: seconds[diarizerID] ?? 0,
                embedding: diarized.embeddings[diarizerID].map(VoiceVector.normalised))
        }

        // A rerun over the same audio clusters the same way, so a name the user
        // gave by hand is carried over rather than lost to "Speaker N".
        let previous = try await store.speakers(forCall: callID)
        for old in previous where old.nameSource == .user && speakers[old.speakerID] != nil {
            speakers[old.speakerID]?.label = old.label
            speakers[old.speakerID]?.personID = old.personID
            speakers[old.speakerID]?.nameSource = .user
            speakers[old.speakerID]?.confidence = old.confidence
        }

        let clusters = speakers.filter { $0.value.label == nil }.compactMapValues(\.embedding)
        let named = Set(speakers.values.compactMap(\.personID))
        let matches = VoiceprintMatcher.match(
            clusters: clusters,
            voiceprints: try await store.voiceprints().filter { !named.contains($0.personID) })
        for match in matches {
            speakers[match.label]?.label = match.displayName
            speakers[match.label]?.personID = match.personID
            speakers[match.label]?.nameSource = .voiceprint
            speakers[match.label]?.confidence = Double(match.score)
        }

        var guessed = 0
        let unnamed = speakers.values.filter { $0.label == nil }.map(\.speakerID).sorted(by: labelOrder)
        if let namer, !unnamed.isEmpty {
            let request = SpeakerNamingRequest(
                attendees: try await store.attendees(forCall: callID),
                knownNames: speakers.values.compactMap(\.label).sorted(),
                unnamed: unnamed,
                turns: bestTurns.compactMap { turn in
                    let speaker = assignment.turns[turn.seq]
                        ?? (turn.source == SpeakerAttribution.localSpeakerID ? SpeakerAttribution.localSpeakerID : nil)
                    guard let speaker else { return nil }
                    let name = speakers[speaker]?.label
                    return SpeakerNamingRequest.Line(speakerID: speaker, knownName: name, t0: turn.t0, text: turn.text)
                })
            let guesses = await namer(request)
            let taken = Set(speakers.values.compactMap(\.personID))
            var claimed = taken
            for label in unnamed {
                guard let guess = guesses[label] else { continue }
                let personID = CallSpeaker.personID(for: guess.name)
                guard !personID.isEmpty, !claimed.contains(personID) else { continue }
                claimed.insert(personID)
                speakers[label]?.label = guess.name
                speakers[label]?.personID = personID
                speakers[label]?.nameSource = .auto
                speakers[label]?.confidence = guess.confidence
                guessed += 1
            }
        }

        let mySeconds = bestTurns
            .filter { $0.source == SpeakerAttribution.localSpeakerID }
            .reduce(0) { $0 + max(0, $1.t1 - $1.t0) }
        let rows = [CallSpeaker(speakerID: CallSpeaker.localID, speechSeconds: mySeconds)]
            + speakers.values.sorted { labelOrder($0.speakerID, $1.speakerID) }
        try await store.replaceSpeakers(rows, callID: callID)

        let outcome = Outcome(remoteSpeakers: speakers.count, recognised: matches.count, guessed: guessed)
        speakerLog.notice("speakers for \(callID, privacy: .public): \(outcome.remoteSpeakers, privacy: .public) remote, \(outcome.recognised, privacy: .public) recognised, \(outcome.guessed, privacy: .public) guessed")
        return outcome
    }

    /// `S2` before `S10`.
    static func labelOrder(_ a: String, _ b: String) -> Bool {
        let na = Int(a.dropFirst()) ?? .max, nb = Int(b.dropFirst()) ?? .max
        return na == nb ? a < b : na < nb
    }
}

/// What the naming pass gets to look at.
public struct SpeakerNamingRequest: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public var speakerID: String
        /// Set when this voice is already known, so its lines read as a name.
        public var knownName: String?
        public var t0: Double
        public var text: String
    }

    /// Calendar attendees. May include the user, who is always `me`.
    public var attendees: [String]
    /// Names already given to voices on this call by their voiceprint.
    public var knownNames: [String]
    /// The labels still waiting for a name.
    public var unnamed: [String]
    public var turns: [Line]
}

public struct SpeakerNameGuess: Sendable, Equatable, Codable {
    public var name: String
    public var confidence: Double
    public var evidence: String?

    public init(name: String, confidence: Double, evidence: String? = nil) {
        self.name = name
        self.confidence = confidence
        self.evidence = evidence
    }
}
