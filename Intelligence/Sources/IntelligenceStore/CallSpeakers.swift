import Foundation

/// One voice on a call: the user, or a remote voice the diarizer separated out
/// of system audio.
public struct CallSpeaker: Codable, Sendable, Equatable, Identifiable {
    /// How a speaker came by its name. Only `user` and `voiceprint` are trusted
    /// enough to teach the voiceprint store; an `auto` guess is shown with a
    /// question mark until someone confirms it.
    public enum NameSource: String, Codable, Sendable {
        case none
        case auto
        case voiceprint
        case user
    }

    public static let localID = "me"

    /// `me`, or `S1`, `S2`, … numbered in order of first appearance.
    public var speakerID: String
    public var label: String?
    public var personID: String?
    public var nameSource: NameSource
    public var confidence: Double?
    public var speechSeconds: Double
    /// The voice's L2-normalised embedding. Nil for `me`.
    public var embedding: [Float]?

    public var id: String { speakerID }

    public init(
        speakerID: String,
        label: String? = nil,
        personID: String? = nil,
        nameSource: NameSource = .none,
        confidence: Double? = nil,
        speechSeconds: Double = 0,
        embedding: [Float]? = nil
    ) {
        self.speakerID = speakerID
        self.label = label
        self.personID = personID
        self.nameSource = nameSource
        self.confidence = confidence
        self.speechSeconds = speechSeconds
        self.embedding = embedding
    }

    /// What the transcript shows: the name when there is one, else "You" or
    /// "Speaker N".
    public var displayName: String {
        if let label, !label.isEmpty { return label }
        return Self.fallbackName(for: speakerID)
    }

    public static func fallbackName(for speakerID: String) -> String {
        if speakerID == localID { return "You" }
        if speakerID.hasPrefix("S"), let number = Int(speakerID.dropFirst()) { return "Speaker \(number)" }
        return "Them"
    }

    /// A stable key for a person across calls. Attendees arrive as display
    /// names, so the name itself, folded, is the identity.
    public static func personID(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// A remembered voice. Built only from names a person confirmed.
public struct Voiceprint: Codable, Sendable, Equatable, Identifiable {
    public var personID: String
    public var displayName: String
    public var embedding: [Float]
    /// How much speech the running mean was built from. Weighs the next update.
    public var speechSeconds: Double
    public var updatedAt: Date

    public var id: String { personID }

    public init(personID: String, displayName: String, embedding: [Float], speechSeconds: Double, updatedAt: Date = Date()) {
        self.personID = personID
        self.displayName = displayName
        self.embedding = embedding
        self.speechSeconds = speechSeconds
        self.updatedAt = updatedAt
    }

    /// Folds one more call's embedding into the running mean, weighted by speech
    /// seconds and capped so a single long call cannot drown months of history.
    public func updated(with embedding: [Float], seconds: Double, at date: Date = Date()) -> Voiceprint {
        guard embedding.count == self.embedding.count, seconds > 0 else { return self }
        let cap = 600.0
        let oldWeight = Float(min(speechSeconds, cap))
        let newWeight = Float(min(seconds, cap))
        let mixed = zip(self.embedding, embedding).map { ($0 * oldWeight + $1 * newWeight) / (oldWeight + newWeight) }
        return Voiceprint(personID: personID, displayName: displayName,
                          embedding: VoiceVector.normalised(mixed),
                          speechSeconds: speechSeconds + seconds, updatedAt: date)
    }
}

public enum VoiceVector {
    public static func normalised(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            na += a[index] * a[index]
            nb += b[index] * b[index]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    static func pack(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func unpack(_ data: Data?) -> [Float]? {
        guard let data, !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

public extension CallaStore {
    // MARK: - Attendees

    /// The calendar's attendee names, kept so the post-call naming pass can run
    /// long after the meeting context is gone.
    func setAttendees(_ attendees: [String], callID: String) throws {
        let data = try JSONEncoder().encode(attendees)
        try run("UPDATE call SET attendees_json = ? WHERE id = ?",
                [.text(String(data: data, encoding: .utf8)), .text(callID)])
    }

    func attendees(forCall callID: String) throws -> [String] {
        let json = try query("SELECT attendees_json FROM call WHERE id = ?", [.text(callID)]) { $0.text(0) }
            .first ?? nil
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    // MARK: - Speakers

    /// Replaces a call's speakers wholesale. The speaker pass owns the whole set.
    func replaceSpeakers(_ speakers: [CallSpeaker], callID: String) throws {
        try run("DELETE FROM call_speaker WHERE call_id = ?", [.text(callID)])
        for speaker in speakers { try upsert(speaker: speaker, callID: callID) }
    }

    func upsert(speaker: CallSpeaker, callID: String) throws {
        try run(
            """
            INSERT INTO call_speaker(call_id, speaker_id, label, person_id, name_source, confidence, speech_seconds, embedding)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(call_id, speaker_id) DO UPDATE SET
              label = excluded.label, person_id = excluded.person_id,
              name_source = excluded.name_source, confidence = excluded.confidence,
              speech_seconds = excluded.speech_seconds, embedding = excluded.embedding
            """,
            [.text(callID), .text(speaker.speakerID), .text(speaker.label), .text(speaker.personID),
             .text(speaker.nameSource.rawValue), .double(speaker.confidence), .double(speaker.speechSeconds),
             .blob(speaker.embedding.map(VoiceVector.pack))])
    }

    func speakers(forCall callID: String) throws -> [CallSpeaker] {
        try query(
            """
            SELECT speaker_id, label, person_id, name_source, confidence, speech_seconds, embedding
            FROM call_speaker WHERE call_id = ?
            ORDER BY CASE speaker_id WHEN 'me' THEN 0 ELSE 1 END, LENGTH(speaker_id), speaker_id
            """,
            [.text(callID)]) { row in
                CallSpeaker(speakerID: row.string(0), label: row.text(1), personID: row.text(2),
                            nameSource: CallSpeaker.NameSource(rawValue: row.string(3)) ?? .none,
                            confidence: row.doubleIfPresent(4), speechSeconds: row.double(5),
                            embedding: VoiceVector.unpack(row.blob(6)))
            }
    }

    /// Stamps a speaker on each turn of one revision, keyed by `seq`.
    func assignTurnSpeakers(_ assignment: [Int: String], callID: String, revision: Int) throws {
        try run("UPDATE call_turn SET speaker_id = NULL WHERE call_id = ? AND revision = ?",
                [.text(callID), .int(revision)])
        for (seq, speakerID) in assignment {
            try run("UPDATE call_turn SET speaker_id = ? WHERE call_id = ? AND revision = ? AND seq = ?",
                    [.text(speakerID), .text(callID), .int(revision), .int(seq)])
        }
    }

    /// Names a speaker by hand. Returns the updated speaker, or nil when the call
    /// has no such speaker.
    @discardableResult
    func nameSpeaker(callID: String, speakerID: String, name: String, source: CallSpeaker.NameSource = .user) throws -> CallSpeaker? {
        guard var speaker = try speakers(forCall: callID).first(where: { $0.speakerID == speakerID }) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speaker.label = trimmed.isEmpty ? nil : trimmed
        speaker.personID = trimmed.isEmpty ? nil : CallSpeaker.personID(for: trimmed)
        speaker.nameSource = trimmed.isEmpty ? .none : source
        speaker.confidence = trimmed.isEmpty ? nil : 1
        try upsert(speaker: speaker, callID: callID)
        return speaker
    }

    /// Folds one speaker into another, for when the diarizer split a single
    /// voice in two. Every revision's turns move, and the two embeddings are
    /// averaged by speech time.
    func mergeSpeaker(callID: String, from source: String, into target: String) throws {
        guard source != target, source != CallSpeaker.localID, target != CallSpeaker.localID else { return }
        let all = try speakers(forCall: callID)
        guard let from = all.first(where: { $0.speakerID == source }),
              var into = all.first(where: { $0.speakerID == target }) else { return }
        try run("UPDATE call_turn SET speaker_id = ? WHERE call_id = ? AND speaker_id = ?",
                [.text(target), .text(callID), .text(source)])
        if let a = into.embedding, let b = from.embedding, a.count == b.count {
            let wa = Float(max(into.speechSeconds, 0.1)), wb = Float(max(from.speechSeconds, 0.1))
            into.embedding = VoiceVector.normalised(zip(a, b).map { ($0 * wa + $1 * wb) / (wa + wb) })
        } else if into.embedding == nil {
            into.embedding = from.embedding
        }
        into.speechSeconds += from.speechSeconds
        try upsert(speaker: into, callID: callID)
        try run("DELETE FROM call_speaker WHERE call_id = ? AND speaker_id = ?", [.text(callID), .text(source)])
    }

    // MARK: - Voiceprints

    func voiceprints() throws -> [Voiceprint] {
        try query(
            "SELECT person_id, display_name, embedding, speech_seconds, updated_at FROM person_voiceprint ORDER BY display_name",
            []) { row in
                guard let embedding = VoiceVector.unpack(row.blob(2)) else { return nil }
                return Voiceprint(personID: row.string(0), displayName: row.string(1), embedding: embedding,
                                  speechSeconds: row.double(3), updatedAt: row.date(4) ?? Date())
            }.compactMap { $0 }
    }

    func save(voiceprint: Voiceprint) throws {
        try run(
            """
            INSERT INTO person_voiceprint(person_id, display_name, embedding, speech_seconds, updated_at)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(person_id) DO UPDATE SET
              display_name = excluded.display_name, embedding = excluded.embedding,
              speech_seconds = excluded.speech_seconds, updated_at = excluded.updated_at
            """,
            [.text(voiceprint.personID), .text(voiceprint.displayName), .blob(VoiceVector.pack(voiceprint.embedding)),
             .double(voiceprint.speechSeconds), .date(voiceprint.updatedAt)])
    }

    /// Teaches the voiceprint store one confirmed speaker. A no-op for a speaker
    /// without a name or an embedding.
    @discardableResult
    func enroll(speaker: CallSpeaker) throws -> Voiceprint? {
        guard let personID = speaker.personID, let label = speaker.label,
              let embedding = speaker.embedding, !embedding.isEmpty else { return nil }
        let seconds = max(speaker.speechSeconds, 1)
        let existing = try voiceprints().first { $0.personID == personID }
        let next = existing.map { $0.updated(with: embedding, seconds: seconds) }
            ?? Voiceprint(personID: personID, displayName: label,
                          embedding: VoiceVector.normalised(embedding), speechSeconds: seconds)
        var renamed = next
        renamed.displayName = label
        try save(voiceprint: renamed)
        return renamed
    }

    func deleteVoiceprint(personID: String) throws {
        try run("DELETE FROM person_voiceprint WHERE person_id = ?", [.text(personID)])
    }

    func deleteAllVoiceprints() throws {
        try run("DELETE FROM person_voiceprint")
    }
}
