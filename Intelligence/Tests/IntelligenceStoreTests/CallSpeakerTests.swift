import CallaContracts
import XCTest
@testable import IntelligenceStore

/// Speakers, their names, and the voices remembered across calls.
final class CallSpeakerTests: XCTestCase {
    private var directory: URL!
    private var store: CallaStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try CallaStore(path: directory.appendingPathComponent("calla.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func seedCall(_ callID: String = "call-a") async throws {
        try await store.beginCall(CallRecord(id: callID, persona: "generic", startedAt: Date()))
        let turns = [
            StoredTurn(seq: 0, source: "me", t0: 0, t1: 1, text: "Hi all", revision: StoredTurn.archiveRevision),
            StoredTurn(seq: 1, source: "them", t0: 1, t1: 2, text: "Hi, Sarah here", revision: StoredTurn.archiveRevision),
            StoredTurn(seq: 2, source: "them", t0: 2, t1: 3, text: "And Tom", revision: StoredTurn.archiveRevision),
        ]
        try await store.replace(turns: turns, callID: callID, revision: StoredTurn.archiveRevision)
    }

    func testTurnsCarryTheirAssignedSpeaker() async throws {
        try await seedCall()
        try await store.assignTurnSpeakers([0: "me", 1: "S1", 2: "S2"], callID: "call-a",
                                           revision: StoredTurn.archiveRevision)
        let turns = try await store.turns(forCall: "call-a")
        XCTAssertEqual(turns.map(\.speakerID), ["me", "S1", "S2"])
    }

    func testAttendeesRoundTrip() async throws {
        try await seedCall()
        try await store.setAttendees(["Sarah Chen", "Tom Ruiz"], callID: "call-a")
        let attendees = try await store.attendees(forCall: "call-a")
        XCTAssertEqual(attendees, ["Sarah Chen", "Tom Ruiz"])
    }

    func testNamingAndFallbackLabels() async throws {
        try await seedCall()
        try await store.replaceSpeakers([
            CallSpeaker(speakerID: "me"),
            CallSpeaker(speakerID: "S1", speechSeconds: 10, embedding: [1, 0]),
            CallSpeaker(speakerID: "S2", speechSeconds: 5, embedding: [0, 1]),
        ], callID: "call-a")
        var speakers = try await store.speakers(forCall: "call-a")
        XCTAssertEqual(speakers.map(\.displayName), ["You", "Speaker 1", "Speaker 2"])
        XCTAssertEqual(speakers[1].embedding, [1, 0])

        try await store.nameSpeaker(callID: "call-a", speakerID: "S2", name: "  Tom Ruiz ")
        speakers = try await store.speakers(forCall: "call-a")
        XCTAssertEqual(speakers[2].displayName, "Tom Ruiz")
        XCTAssertEqual(speakers[2].personID, "tom ruiz")
        XCTAssertEqual(speakers[2].nameSource, .user)
    }

    func testMergingMovesTurnsAndDropsTheSourceSpeaker() async throws {
        try await seedCall()
        try await store.assignTurnSpeakers([0: "me", 1: "S1", 2: "S2"], callID: "call-a",
                                           revision: StoredTurn.archiveRevision)
        try await store.replaceSpeakers([
            CallSpeaker(speakerID: "S1", speechSeconds: 10, embedding: [1, 0]),
            CallSpeaker(speakerID: "S2", speechSeconds: 10, embedding: [0, 1]),
        ], callID: "call-a")
        try await store.mergeSpeaker(callID: "call-a", from: "S2", into: "S1")

        let turns = try await store.turns(forCall: "call-a")
        XCTAssertEqual(turns.map(\.speakerID), ["me", "S1", "S1"])
        let speakers = try await store.speakers(forCall: "call-a")
        XCTAssertEqual(speakers.map(\.speakerID), ["S1"])
        XCTAssertEqual(speakers[0].speechSeconds, 20)
        let merged = try XCTUnwrap(speakers[0].embedding)
        XCTAssertEqual(merged[0], merged[1], accuracy: 0.0001)
    }

    func testEnrollmentBuildsARunningMeanAndCanBeForgotten() async throws {
        let first = CallSpeaker(speakerID: "S1", label: "Sarah Chen", personID: "sarah chen",
                                nameSource: .user, speechSeconds: 30, embedding: [1, 0])
        try await store.enroll(speaker: first)
        var prints = try await store.voiceprints()
        XCTAssertEqual(prints.count, 1)
        XCTAssertEqual(prints[0].embedding, [1, 0])

        var second = first
        second.embedding = [0, 1]
        try await store.enroll(speaker: second)
        prints = try await store.voiceprints()
        XCTAssertEqual(prints[0].speechSeconds, 60)
        XCTAssertEqual(prints[0].embedding[0], prints[0].embedding[1], accuracy: 0.0001)

        try await store.deleteAllVoiceprints()
        let afterForget = try await store.voiceprints()
        XCTAssertTrue(afterForget.isEmpty)
    }

    func testAnUnnamedSpeakerIsNeverEnrolled() async throws {
        let enrolled = try await store.enroll(speaker: CallSpeaker(speakerID: "S1", embedding: [1, 0]))
        XCTAssertNil(enrolled)
    }

    func testPersonIDFoldsCaseAccentsAndSpacing() {
        XCTAssertEqual(CallSpeaker.personID(for: "  José   Álvarez "), "jose alvarez")
    }
}
