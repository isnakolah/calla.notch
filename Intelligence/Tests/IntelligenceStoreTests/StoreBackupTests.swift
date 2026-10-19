import CallaContracts
import XCTest
@testable import IntelligenceStore

/// Backing a store up row by row and rebuilding a fresh one from it: the path
/// a reinstalled Mac takes to get its history back from the calla backend.
final class StoreBackupTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(_ name: String) throws -> CallaStore {
        try CallaStore(path: directory.appendingPathComponent("\(name).sqlite"))
    }

    private func seed(_ store: CallaStore, callID: String) async throws {
        try await store.beginCall(CallRecord(id: callID, persona: "standup", startedAt: Date(timeIntervalSince1970: 1_790_000_000)))
        try await store.replace(turns: [
            StoredTurn(seq: 0, source: "me", t0: 0, t1: 1, text: "Morning", revision: StoredTurn.liveRevision),
            StoredTurn(seq: 1, source: "them", t0: 1, t1: 2.5, text: "Shipped the build", revision: StoredTurn.liveRevision),
        ], callID: callID, revision: StoredTurn.liveRevision)
        try await store.replace(turns: [
            StoredTurn(seq: 0, source: "me", t0: 0, t1: 1, text: "Good morning", revision: StoredTurn.archiveRevision),
            StoredTurn(seq: 1, source: "them", t0: 1, t1: 2.5, text: "We shipped the build", revision: StoredTurn.archiveRevision),
        ], callID: callID, revision: StoredTurn.archiveRevision)
        try await store.replaceSpeakers([
            CallSpeaker(speakerID: "S1", speechSeconds: 1.5, embedding: [0.25, -1, 3]),
        ], callID: callID)
        try await store.assignTurnSpeakers([1: "S1"], callID: callID, revision: StoredTurn.archiveRevision)
        try await store.nameSpeaker(callID: callID, speakerID: "S1", name: "Tom Ruiz")
    }

    func testCallRowsRoundTripIntoAFreshStore() async throws {
        let source = try makeStore("source")
        try await seed(source, callID: "call-backup-a")
        try await seed(source, callID: "call-backup-b")

        let backup = try await source.backupRows(forCall: "call-backup-a")
        XCTAssertNotNil(backup.tables["call"])
        XCTAssertNotNil(backup.tables["call_turn"])
        XCTAssertNotNil(backup.tables["call_speaker"])
        let turnLines = String(decoding: try XCTUnwrap(backup.tables["call_turn"]), as: UTF8.self)
            .split(separator: "\n")
        XCTAssertEqual(turnLines.count, 4, "both revisions, and only this call's rows")
        XCTAssertFalse(turnLines.contains { $0.contains("call-backup-b") })

        let target = try makeStore("target")
        let inserted = try await target.restoreRows(backup)
        XCTAssertEqual(inserted["call_turn"], 4)

        let archive = try await target.turns(forCall: "call-backup-a", revision: StoredTurn.archiveRevision)
        XCTAssertEqual(archive.map(\.text), ["Good morning", "We shipped the build"])
        XCTAssertEqual(archive.map(\.speakerID), [nil, "S1"])
        let speakers = try await target.speakers(forCall: "call-backup-a")
        XCTAssertEqual(speakers.first?.displayName, "Tom Ruiz")
        XCTAssertEqual(speakers.first?.embedding, [0.25, -1, 3], "BLOBs survive base64")
        let call = try await target.call(id: "call-backup-a")
        XCTAssertEqual(call?.persona, "standup")
        XCTAssertEqual(call?.startedAt, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testRestoreNeverOverwritesLocalRows() async throws {
        let source = try makeStore("source")
        try await seed(source, callID: "call-backup-a")
        let backup = try await source.backupRows(forCall: "call-backup-a")

        let target = try makeStore("target")
        try await seed(target, callID: "call-backup-a")
        try await target.nameSpeaker(callID: "call-backup-a", speakerID: "S1", name: "Thomas")
        let inserted = try await target.restoreRows(backup)
        XCTAssertEqual(inserted.values.reduce(0, +), 0)
        let speakers = try await target.speakers(forCall: "call-backup-a")
        XCTAssertEqual(speakers.first?.displayName, "Thomas")
    }

    func testDeviceRowsCarryKnowledgeAndKeepSearchWorking() async throws {
        let source = try makeStore("source")
        try await seed(source, callID: "call-backup-a")
        _ = try await source.upsert(KnowledgeNote(title: "Billing", body: "We migrated off Stripe in Q2."))
        let device = try await source.backupDeviceRows()
        XCTAssertNil(device.tables["call_turn"], "call tables travel with their call")
        XCTAssertNil(device.tables["knowledge_fts_data"], "FTS shadow tables are never dumped")
        XCTAssertNil(device.tables["knowledge_fts"], "an external-content index is rebuilt, not copied")
        XCTAssertNotNil(device.tables["knowledge_note"])
        XCTAssertNotNil(device.tables["knowledge_chunk"])

        let target = try makeStore("target")
        try await target.restoreRows(device)
        let notes = try await target.notes()
        XCTAssertEqual(notes.map(\.title), ["Billing"])
        let hits = await target.search(query: "Stripe", scopes: [.always], limit: 3)
        XCTAssertFalse(hits.isEmpty, "the FTS index was rebuilt over the restored chunks")
    }

    func testNewerBackupIsRefused() async throws {
        let target = try makeStore("target")
        let backup = StoreBackupTables(tables: [:], schemaVersion: Schema.current + 1)
        do {
            try await target.restoreRows(backup)
            XCTFail("restored a backup from a newer schema")
        } catch let error as StoreBackupError {
            XCTAssertEqual(error, .newerSchema(Schema.current + 1, local: Schema.current))
        }
    }
}
