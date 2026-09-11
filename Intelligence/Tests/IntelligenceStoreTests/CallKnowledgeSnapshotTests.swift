import Foundation
import XCTest
import CallaContracts
@testable import IntelligenceStore

final class CallKnowledgeSnapshotTests: XCTestCase {
    private func makeStore() throws -> (CallaStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("call-pack-\(UUID().uuidString)", isDirectory: true)
        return (try CallaStore(path: root.appendingPathComponent("calla.sqlite")), root)
    }

    private func begin(_ store: CallaStore, id: String = "call-1") async throws {
        try await store.beginCall(CallRecord(id: id, persona: "generic", startedAt: Date()))
    }

    func testSnapshotCopiesExactRevisionAndStaysImmutable() async throws {
        let (store, root) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        try await begin(store)
        var note = KnowledgeNote(id: "n1", title: "Account", body: "Renewal is March 14.")
        note.updatedAt = Date(timeIntervalSince1970: 100)
        try await store.upsert(note)
        let frozen = try await store.freezeKnowledge(callID: "call-1", generation: 3, noteIDs: ["n1"])
        try await store.upsert(KnowledgeNote(id: "n1", title: "Account", body: "Renewal moved to April."))

        let loaded = try await store.knowledgeSnapshot(forCall: "call-1")
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded, frozen)
        XCTAssertTrue(reloaded.chunks.contains { $0.text.contains("March 14") })
        XCTAssertFalse(reloaded.chunks.contains { $0.text.contains("April") })
        do {
            _ = try await store.freezeKnowledge(callID: "call-1", generation: 3, noteIDs: ["n1"])
            XCTFail("running-call snapshot must not be rewritten")
        } catch let error as CallKnowledgeSnapshotError {
            XCTAssertEqual(error, .alreadyFrozen)
        }
    }

    func testPageLocatorSurvivesIndexAndSnapshot() async throws {
        let (store, root) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        try await begin(store)
        let note = KnowledgeNote(id: "pdf", title: "terms.pdf",
                                 body: "[[CALLA_PAGE:1]]\n\nCover text.\n\n[[CALLA_PAGE:2]]\n\nLiability cap is ten dollars.",
                                 source: .document, originName: "terms.pdf", originKind: "pdf", pageCount: 2)
        try await store.upsert(note)
        let snapshot = try await store.freezeKnowledge(callID: "call-1", generation: 1, noteIDs: ["pdf"])
        XCTAssertEqual(snapshot.chunks.first(where: { $0.text.contains("Liability") })?.citation.page, 2)
    }

    func testSnapshotContainsOnlySelectedSourcesAndRejectsMissingSelection() async throws {
        let (store, root) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        try await begin(store)
        try await store.upsert(KnowledgeNote(id: "selected", title: "Selected", body: "Chosen fact."))
        try await store.upsert(KnowledgeNote(id: "outside", title: "Outside", body: "Unselected secret."))

        let snapshot = try await store.freezeKnowledge(
            callID: "call-1", generation: 1, noteIDs: ["selected"])
        XCTAssertEqual(Set(snapshot.sourceRevisions.keys), Set(["selected"]))
        XCTAssertFalse(snapshot.chunks.contains { $0.text.contains("Unselected secret") })

        try await begin(store, id: "call-2")
        do {
            _ = try await store.freezeKnowledge(callID: "call-2", generation: 1, noteIDs: ["missing"])
            XCTFail("missing selected source must block Call start")
        } catch let error as CallKnowledgeSnapshotError {
            XCTAssertEqual(error, .sourceMissing("missing"))
        }
    }

    func testSnapshotSearchUsesNoHitDiversityAndPromptCap() async throws {
        let (store, root) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        try await begin(store)
        try await store.upsert(KnowledgeNote(id: "a", title: "alpha.pdf",
            body: String(repeating: "Renewal price is 40 dollars. ", count: 80), source: .document))
        try await store.upsert(KnowledgeNote(id: "b", title: "beta.txt",
            body: "Renewal owner is Dana. Renewal date is March."))
        _ = try await store.freezeKnowledge(callID: "call-1", generation: 1, noteIDs: ["a", "b"])

        let hits = try await store.searchSnapshot(query: "What is renewal price owner date?", callID: "call-1")
        XCTAssertLessThanOrEqual(hits.count, 4)
        XCTAssertLessThanOrEqual(hits.map(\.text.count).reduce(0, +), 1_800)
        XCTAssertLessThanOrEqual(hits.filter { $0.citation.sourceID == "a" }.count, 2)
        XCTAssertTrue(hits.contains { $0.citation.sourceID == "b" })
        let noHits = try await store.searchSnapshot(query: "quantum aardvark", callID: "call-1")
        XCTAssertTrue(noHits.isEmpty)
    }

    func testDeletingCallCascadesSnapshotAndFeed() async throws {
        let (store, root) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        try await begin(store)
        try await store.upsert(KnowledgeNote(id: "n", title: "Note", body: "Known fact here."))
        _ = try await store.freezeKnowledge(callID: "call-1", generation: 2, noteIDs: ["n"])
        let question = CallQuestion(fromSeq: 1, toSeq: 1, prompt: "Known fact?", kind: .direct,
                                    confidence: 0.9, callID: "call-1", generation: 2)
        try await store.record(question: question)
        try await store.record(answer: CallAnswer(callID: "call-1", generation: 2,
            questionID: question.id, question: question.prompt, main: "Known fact here.",
            grounding: .callPack, provider: "Agy", model: "gemini"))
        try await store.deleteCall(id: "call-1")

        let snapshot = try await store.knowledgeSnapshot(forCall: "call-1")
        let questions = try await store.questions(forCall: "call-1")
        let answers = try await store.answers(forCall: "call-1")
        XCTAssertNil(snapshot)
        XCTAssertTrue(questions.isEmpty)
        XCTAssertTrue(answers.isEmpty)
    }
}
