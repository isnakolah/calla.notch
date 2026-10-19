import CallaContracts
import Foundation
import IntelligenceCore
import XCTest
@testable import CallaEngineValidation

/// Opt-in provider proof. This does not claim installed audio/UI acceptance.
final class CodingDialogueLiveTests: XCTestCase {
    func testReadOnlyWorkerReturnsAnchoredDialogueWithoutChangingSource() async throws {
        guard ProcessInfo.processInfo.environment["CODING_DIALOGUE_LIVE"] == "1" else {
            throw XCTSkip("Set CODING_DIALOGUE_LIVE=1 for the authenticated provider check")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coding-dialogue-live-" + UUID().uuidString)
        let space = CodingWorkspace(root: root)
        try FileManager.default.createDirectory(at: space.workURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("def unique(values):\n    pass\n".utf8).write(to: space.workURL.appendingPathComponent("main.py"))
        try space.seed(brief: .init(source: .text, title: "Return unique values in first-seen order"), persona: "generic", pack: PromptPack(), readOnly: true)
        let before = try CodingShadowProject.inspect(source: space.workURL)
        var flow = CodingInterviewFlowState(sessionID: "live-test", generation: 1, sourceRevision: before.revision)
        let statement = Statement(fromSeq: 1, toSeq: 1, speaker: .remote, text: "Duplicates are allowed; retain their first occurrence.", span: 2, truncated: false)
        CodingInterviewFlow.record(statement, in: &flow)
        let worker = try CodingAgyWorker(workspace: space, isolatedHome: root.appendingPathComponent("agy-home"), selection: .init(modelID: "gemini-3.7-flash-low"), readOnly: true, dialogue: true)
        do {
            let draft = try await worker.respond(frame: CodingInterviewFlow.frame(state: flow, statement: statement), timeoutSeconds: 45)
            let update = try XCTUnwrap(draft.dialogue)
            XCTAssertTrue(CodingInterviewFlow.apply(update, to: &flow), String(decoding: (try? JSONEncoder().encode(update)) ?? Data(), as: UTF8.self))
            let after = try CodingShadowProject.inspect(source: space.workURL)
            XCTAssertEqual(after.entries, before.entries, "Private saved-source entries changed")
            XCTAssertEqual(after.revision, before.revision, "Manifest digest changed")
            XCTAssertNil(flow.authorizedStage)
            XCTAssertFalse(flow.pointers.isEmpty)
            let candidate = Statement(fromSeq: 2, toSeq: 2, speaker: .local,
                text: "For example, one, one, two should return one, two in that order.", span: 3, truncated: false)
            CodingInterviewFlow.record(candidate, in: &flow)
            let started = Date()
            let next = try await worker.respond(frame: CodingInterviewFlow.frame(state: flow, statement: candidate))
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            print("LIVE DIALOGUE warm response: \(elapsed) ms (provider only, no audio/UI)")
            XCTAssertTrue(CodingInterviewFlow.apply(try XCTUnwrap(next.dialogue), to: &flow))
            XCTAssertNotNil(flow.discussed[.example], String(decoding: (try? JSONEncoder().encode(next)) ?? Data(), as: UTF8.self))
            let pool = WaveWorkerPool(root: root.appendingPathComponent("proposals"))
            let revision = WaveRevision(session: flow.sessionID, source: flow.sourceRevision, requirements: flow.requirementRevision)
            let preparation = Task {
                try await pool.respond(role: .coder, revision: revision, source: space.workURL,
                    context: space.contextURL, selection: CodingModelProfile.standard.edit,
                    prompt: "Implement unique(values) in work/main.py to return unique values in first-seen order. Only this basic behavior, at most 12 lines. Use a set and list. Return the complete block in code with file path main.py and symbol unique. Make the edit in your private work copy. Do not execute any commands.")
            }
            let approach = Statement(fromSeq: 3, toSeq: 3, speaker: .local,
                text: "I'll scan once, track seen values in a set, and append each first occurrence to a result list.", span: 3, truncated: false)
            CodingInterviewFlow.record(approach, in: &flow)
            let loadedStart = Date()
            let loaded = try await worker.respond(frame: CodingInterviewFlow.frame(state: flow, statement: approach))
            print("LIVE DIALOGUE response with private coder active: \(Int(Date().timeIntervalSince(loadedStart) * 1000)) ms (provider only)")
            XCTAssertTrue(CodingInterviewFlow.apply(try XCTUnwrap(loaded.dialogue), to: &flow))
            let proposal = try await preparation.value
            await pool.cancel()
            XCTAssertNotNil(proposal.draft.code)
            XCTAssertEqual(try CodingShadowProject.inspect(source: space.workURL).revision, before.revision)
            XCTAssertNotEqual(try CodingShadowProject.inspect(source: proposal.work).revision, before.revision)
            var move = CodingMove(ordinal: 1, sourceRevision: flow.sourceRevision, kind: .implementation, code: proposal.draft.code)
            move.implementationStage = .simple
            XCTAssertNil(CodingInterviewPublication.screen(move, flow: flow).code)
            await worker.stop()
        } catch { await worker.stop(); throw error }
    }
}
