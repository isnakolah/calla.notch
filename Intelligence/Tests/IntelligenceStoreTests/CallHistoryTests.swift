import XCTest
import CallaContracts
@testable import IntelligenceStore

final class CallHistoryTests: XCTestCase {
    private func makeStore() throws -> (CallaStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        return (try CallaStore(path: root.appendingPathComponent("calla.sqlite")), root)
    }

    private func finishedCall(_ store: CallaStore, id: String, persona: String, startedAt: Date, overview: String) async throws {
        try await store.beginCall(CallRecord(id: id, persona: persona, startedAt: startedAt))
        try await store.endCall(id: id, at: startedAt.addingTimeInterval(600))
        try await store.save(recapDraft: CallRecapDraft(
            callID: id, overview: overview,
            items: [.init(id: "a", kind: .actionItem, text: "Ben: fix login", fromSeq: 1, toSeq: 1)],
            title: "Title for \(id)"))
    }

    func testRecentRecapsAreSamePersonaNewestFirstWithTitle() async throws {
        let (store, root) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        try await finishedCall(store, id: "call-standup-0001", persona: "standup", startedAt: base, overview: "First")
        try await finishedCall(store, id: "call-standup-0002", persona: "standup", startedAt: base + 86_400, overview: "Second")
        try await finishedCall(store, id: "call-retro-000001", persona: "retro", startedAt: base + 3_600, overview: "Retro")
        try await store.beginCall(CallRecord(id: "call-standup-0003", persona: "standup", startedAt: base + 172_800))

        let recaps = try await store.recentRecaps(persona: "standup", limit: 3)
        XCTAssertEqual(recaps.map(\.call.id), ["call-standup-0002", "call-standup-0001"])
        XCTAssertEqual(recaps.first?.draft.title, "Title for call-standup-0002")
        let before = try await store.recentRecaps(persona: "standup", limit: 3, before: base + 3_600)
        XCTAssertEqual(before.map(\.call.id), ["call-standup-0001"])
    }

    func testHistoryIsSearchableButNeverListed() async throws {
        let (store, root) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        try await store.beginCall(CallRecord(id: "call-standup-0001", persona: "standup"))
        try await store.indexCallHistory(
            callID: "call-standup-0001", scope: .persona("standup"), title: "Standup — 15 Oct",
            summary: "The billing migration is blocked on the vendor contract.",
            transcript: "Them: billing migration blocked\nMe: I will chase the vendor", at: Date())
        _ = try await store.upsert(KnowledgeNote(title: "Team charter", body: "We ship on Fridays.", scope: .persona("standup")))

        let listed = try await store.notes(in: .persona("standup"))
        XCTAssertEqual(listed.map(\.title), ["Team charter"])
        let all = try await store.notes()
        XCTAssertFalse(all.contains { $0.source == .callHistory })
        XCTAssertFalse(KnowledgeSource.callHistory.isPacked)

        let hits = await store.search(query: "billing migration vendor", scopes: [.persona("standup")], limit: 3,
                                      sources: [.callHistory])
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.source == .callHistory })
        let isIndexed = try await store.isCallHistoryIndexed(callID: "call-standup-0001")
        XCTAssertTrue(isIndexed)

        try await store.deleteCall(id: "call-standup-0001")
        let afterDelete = await store.search(query: "billing migration vendor", scopes: [.persona("standup")],
                                             limit: 3, sources: [.callHistory])
        XCTAssertTrue(afterDelete.isEmpty)
    }
}
