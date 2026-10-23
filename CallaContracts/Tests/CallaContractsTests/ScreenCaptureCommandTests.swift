import XCTest
@testable import CallaContracts

final class ScreenCaptureCommandTests: XCTestCase {
    func testChosenDisplaySurvivesHostCommandEncoding() throws {
        let command = CallHostCommand(callID: "call", generation: 2, kind: .capture,
                                      displayID: 42)
        let decoded = try JSONDecoder().decode(CallHostCommand.self,
                                               from: JSONEncoder().encode(command))
        XCTAssertEqual(decoded.displayID, 42)
    }

    func testOlderCaptureCommandStillUsesDefaultDisplay() throws {
        let older = Data(#"{"contractVersion":3,"callID":"call","generation":2,"kind":"capture"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CallHostCommand.self, from: older).displayID)
    }
}
