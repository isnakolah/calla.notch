import XCTest
@testable import CallaContracts

/// Switching a note off mid-call travels to the host as its own command kind.
final class CallHostKnowledgeCommandTests: XCTestCase {
    func testKnowledgeCommandRoundTrips() throws {
        let command = CallHostCommand(callID: "call", generation: 4, kind: .knowledge, text: "note-a,note-b")
        let decoded = try JSONDecoder().decode(CallHostCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(decoded.kind, .knowledge)
        XCTAssertEqual(decoded.text, "note-a,note-b")
        XCTAssertEqual(decoded, command)
    }
}
