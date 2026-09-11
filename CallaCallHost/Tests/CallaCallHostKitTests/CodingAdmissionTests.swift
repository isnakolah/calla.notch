import CallaContracts
import Foundation
import IntelligenceCore
import XCTest
@testable import CallaCallHostKit

final class CodingAdmissionTests: XCTestCase {
    func testCodeOwnsAutomaticQuestionsWhileCallStillRecordsStatements() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coding-call-admission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WaveCallContext(callID: "call-test", generation: 7,
            revision: .init(session: "code-test", source: "saved"), task: "Duplicates", decisions: [], sourceExcerpt: "")
        try JSONEncoder().encode(context).write(to: root.appendingPathComponent("wave-call-test.json"))
        let advisor = CopilotAdvisor(config: .init(callID: "call-test", generation: 7, persona: "generic", profile: nil,
            preferred: .local, fallbackToGateway: false, liveTier: .fast, summaryModel: nil, runtimeRoot: root))
        let unexpected = expectation(description: "Call must not automatically answer a Code-owned question")
        unexpected.isInverted = true
        await advisor.setHandlers(onQuestion: { _ in unexpected.fulfill() }, onSuggestion: { _, _ in }, onProviderChange: { _, _ in })
        await advisor.ingest(turn: .init(seq: 1, source: .them, t0: 0, t1: 2, text: "Can you explain why this uses linear extra memory?", confidence: 1))
        await advisor.ingest(turn: .init(seq: 2, source: .me, t0: 5, t1: 8, text: "I will talk through the space used by each collection.", confidence: 1))
        let statements = await advisor.statementsEmitted
        XCTAssertGreaterThan(statements, 0)
        await fulfillment(of: [unexpected], timeout: 0.05)
    }
    func testGatewayPushCannotBypassCodeOwnerAndOldGenerationDoesNotDisableCall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coding-gateway-admission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let advisor = CopilotAdvisor(config: .init(callID: "call-test", generation: 7, persona: "generic", profile: nil,
            preferred: .gateway, fallbackToGateway: false, liveTier: .fast, summaryModel: nil, runtimeRoot: root))
        var context = WaveCallContext(callID: "call-test", generation: 6,
            revision: .init(session: "code-test", source: "saved"), task: "Duplicates", decisions: [], sourceExcerpt: "")
        let file = root.appendingPathComponent("wave-call-test.json")
        try JSONEncoder().encode(context).write(to: file)
        var accepts = await advisor.acceptsGatewaySuggestion(); XCTAssertTrue(accepts)
        context.generation = 7
        try JSONEncoder().encode(context).write(to: file)
        accepts = await advisor.acceptsGatewaySuggestion(); XCTAssertFalse(accepts)
        try FileManager.default.removeItem(at: file)
        accepts = await advisor.acceptsGatewaySuggestion(); XCTAssertTrue(accepts)
    }
}
