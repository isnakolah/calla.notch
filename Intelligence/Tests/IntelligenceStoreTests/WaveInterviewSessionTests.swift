import Foundation
import XCTest
@testable import IntelligenceStore

/// A store in a fresh temporary directory, torn down with the test.
private func makeWaveStore() throws -> (CallaStore, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wave-session-tests-\(UUID().uuidString)", isDirectory: true)
    return (try CallaStore(path: root.appendingPathComponent("calla.sqlite")), root)
}

/// The identity the app pins. Duplicated as literals on purpose: these are the
/// values written into every call row and every knowledge note, and a test that
/// read them from the same constant the code does would pass through a rename
/// that orphaned a month of history.
private let waveSeriesID = "wave-interview"
private let waveEventID = "wave-interview-2026-09-07"
private let waveRehearsalEventID = "wave-interview-rehearsal"

private func waveMeeting() -> MeetingContext {
    MeetingContext(eventID: waveEventID, seriesID: waveSeriesID, title: "Wave interview")
}

/// Different sessions, one meeting.
final class WaveInterviewSessionTests: XCTestCase {
    /// The point of pinning the meeting: a rehearsal run against a scratch
    /// folder and the real sitting are two rows under one series.
    func testSessionsAgainstDifferentProjectsShareTheMeeting() async throws {
        let (store, root) = try makeWaveStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = waveMeeting()

        // The project folder is expected to change between them; it is not part
        // of the meeting's identity and must not reach these rows at all.
        for (index, startedAt) in [Date(timeIntervalSince1970: 1_000),
                                   Date(timeIntervalSince1970: 2_000)].enumerated() {
            try await store.beginCall(CallRecord(
                id: "call-session-\(index)", eventID: meeting.eventID, seriesID: meeting.seriesID,
                eventTitle: meeting.title, persona: "interview", startedAt: startedAt))
        }

        let sessions = try await store.calls(forEvent: meeting.eventID, seriesID: meeting.seriesID)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.seriesID)), [waveSeriesID])
        // Newest first, which is what History numbers the sessions from.
        XCTAssertEqual(sessions.map(\.id), ["call-session-1", "call-session-0"])
    }

    /// Every session retrieves what was prepared for the interview, whichever
    /// sitting it belongs to.
    func testEverySessionRetrievesTheInterviewsKnowledge() async throws {
        let (store, root) = try makeWaveStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await store.upsert(KnowledgeNote(
            id: "note-wave-brief",
            title: "Part 1 submission notes",
            body: "The evaluator lives in sheet/engine.py and returns typed values.",
            source: .manual,
            scope: .series(waveSeriesID)))

        let scopes = waveMeeting().scopes(persona: "interview")
        XCTAssertTrue(scopes.contains(.series(waveSeriesID)))
        XCTAssertTrue(scopes.contains(.event(waveEventID)))
        // `always` and the persona are in every call's scope; the meeting adds
        // to them rather than replacing them.
        XCTAssertTrue(scopes.contains(.always))
        XCTAssertTrue(scopes.contains(.persona("interview")))

        let hits = await store.search(query: "where does the evaluator live",
                                      scopes: scopes, limit: 3)
        XCTAssertTrue(hits.contains { $0.noteID == "note-wave-brief" },
                      "material filed against the interview must reach a session of it")
    }

    /// Sessions stay independent. Attaching a meeting is exactly what would
    /// switch carry-forward on, so this is the guard against getting it by
    /// accident: ending a call records the account, and indexes nothing.
    func testEndingASessionDoesNotTeachTheNextOne() async throws {
        let (store, root) = try makeWaveStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = waveMeeting()

        try await store.beginCall(CallRecord(
            id: "call-rehearsal", eventID: meeting.eventID, seriesID: meeting.seriesID,
            eventTitle: meeting.title, persona: "interview", startedAt: Date()))
        try await store.endCall(id: "call-rehearsal")

        // The live end-of-call path deliberately files no knowledge; only an
        // approved recap does. A session that ended must therefore leave the
        // index exactly as it found it.
        let notes = try await store.notes(in: .series(waveSeriesID))
        XCTAssertTrue(notes.isEmpty,
                      "a finished session must not index its own account for the next one")
        let hits = await store.search(query: "rehearsal",
                                      scopes: meeting.scopes(persona: "interview"), limit: 3)
        XCTAssertTrue(hits.isEmpty)
    }

    /// And when the user does approve a recap, it is filed against the
    /// interview rather than nowhere — the opt-in has to actually work.
    func testAnApprovedRecapIsFiledAgainstTheInterview() async throws {
        let (store, root) = try makeWaveStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = waveMeeting()

        try await store.beginCall(CallRecord(
            id: "call-approved", eventID: meeting.eventID, seriesID: meeting.seriesID,
            eventTitle: meeting.title, persona: "interview", startedAt: Date()))
        let summary = CallSummary(
            callID: "call-approved",
            standing: "Angel confirmed blanks inside a sum range are skipped.",
            points: ["Repeated references are summed twice."],
            openQuestions: [])
        let note = try await store.finish(summary: summary, meeting: meeting)

        XCTAssertEqual(note?.scope, .series(waveSeriesID),
                       "series, so it reaches every session rather than one sitting")
        XCTAssertEqual(note?.source, .callSummary)
    }

    /// A rehearsal shares everything prepared for the interview.
    func testARehearsalRetrievesTheSameMaterial() async throws {
        let (store, root) = try makeWaveStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await store.upsert(KnowledgeNote(
            id: "note-wave-brief",
            title: "Part 1 submission notes",
            body: "The evaluator lives in sheet/engine.py and returns typed values.",
            source: .manual,
            scope: .series(waveSeriesID)))

        // Same series, different occurrence — which is the whole design: a
        // rehearsal is a full run of the real thing.
        let rehearsal = MeetingContext(eventID: waveRehearsalEventID, seriesID: waveSeriesID,
                                       title: "Wave rehearsal")
        let hits = await store.search(query: "where does the evaluator live",
                                      scopes: rehearsal.scopes(persona: "interview"), limit: 3)
        XCTAssertTrue(hits.contains { $0.noteID == "note-wave-brief" })
    }

    /// And a rehearsal and the sitting sit in one History group.
    func testARehearsalAndTheSittingAreOneGroup() async throws {
        let (store, root) = try makeWaveStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.beginCall(CallRecord(
            id: "call-rehearsal", eventID: waveRehearsalEventID, seriesID: waveSeriesID,
            eventTitle: "Wave rehearsal", persona: "interview",
            startedAt: Date(timeIntervalSince1970: 1_000)))
        try await store.beginCall(CallRecord(
            id: "call-sitting", eventID: waveEventID, seriesID: waveSeriesID,
            eventTitle: "Wave interview", persona: "interview",
            startedAt: Date(timeIntervalSince1970: 2_000)))

        let sessions = try await store.calls(forEvent: waveEventID, seriesID: waveSeriesID)
        XCTAssertEqual(sessions.map(\.id), ["call-sitting", "call-rehearsal"])
        // The event id is what tells them apart afterwards.
        XCTAssertEqual(sessions.first { $0.id == "call-rehearsal" }?.eventID,
                       waveRehearsalEventID)
    }

    /// What a rehearsal concluded must not be retrieved during the interview.
    ///
    /// Approving is still allowed — the rehearsal's own occurrence keeps it, so
    /// the button is not silently a no-op — but the series is where the sitting
    /// reads from, and a practice conclusion has no business there.
    func testAnApprovedRehearsalRecapCannotReachTheSitting() async throws {
        let (store, root) = try makeWaveStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.beginCall(CallRecord(
            id: "call-rehearsal", eventID: waveRehearsalEventID, seriesID: waveSeriesID,
            eventTitle: "Wave rehearsal", persona: "interview", startedAt: Date()))

        // The engine drops the series for a rehearsal row before filing.
        let scopedForFiling = MeetingContext(eventID: waveRehearsalEventID, seriesID: nil,
                                             title: "Wave rehearsal")
        let note = try await store.finish(
            summary: CallSummary(callID: "call-rehearsal",
                                 standing: "Practised against a scratch copy; sum skipped blanks.",
                                 points: [], openQuestions: []),
            meeting: scopedForFiling)
        XCTAssertEqual(note?.scope, .event(waveRehearsalEventID))

        // The sitting retrieves from the series and its own occurrence.
        let sitting = MeetingContext(eventID: waveEventID, seriesID: waveSeriesID)
        let hits = await store.search(query: "did sum skip blanks",
                                      scopes: sitting.scopes(persona: "interview"), limit: 5)
        XCTAssertFalse(hits.contains { $0.noteID == note?.id },
                       "a rehearsal's conclusion must not surface during the interview")
    }

    /// A call with no meeting has nothing to file under, which is what every
    /// call looked like before the app pinned one.
    func testACallWithNoMeetingStillFilesNothing() async throws {
        let (store, root) = try makeWaveStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.beginCall(CallRecord(id: "call-loose", persona: "generic",
                                             startedAt: Date()))
        let note = try await store.finish(
            summary: CallSummary(callID: "call-loose", standing: "Something was said.",
                                 points: [], openQuestions: []),
            meeting: nil)
        XCTAssertNil(note)
    }
}
