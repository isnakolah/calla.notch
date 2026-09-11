import XCTest
@testable import CallaContracts

final class CodingCallLifecycleTests: XCTestCase {
    func testActualCaptureReleasesReadyCodingWithoutAnyUISubscriber() throws {
        // Shape and identity from the failed 5 September attempt, with transcript omitted.
        let data = Data(#"{"contractVersion":3,"callID":"call-3b570b07-2bcb-4f","generation":1,"state":"capturing","updatedAt":"2026-09-05T10:36:19Z","capture":{"microphone":true,"systemAudio":true}}"#.utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let call = try decoder.decode(CallLifecycleSnapshot.self, from: data)
        let coding = CodingSessionSnapshot(sessionID: "code-regression", callID: call.callID, generation: 1, lifecycle: .ready)
        XCTAssertEqual(CodingCallReconciliation.action(coding: coding, call: call), .capturing)
    }

    func testDifferentCallOrGenerationCannotPromoteCoding() {
        let coding = CodingSessionSnapshot(callID: "call-current", generation: 2, lifecycle: .ready)
        for (id, generation) in [("call-current", 1), ("call-old", 2)] {
            let call = CallLifecycleSnapshot(callID: id, generation: generation, state: .capturing,
                capture: .init(microphone: true, systemAudio: true))
            XCTAssertEqual(CodingCallReconciliation.action(coding: coding, call: call), .none)
        }
    }

    func testCaptureStageBeforeMicrophoneStartsIsStillWaiting() {
        let coding = CodingSessionSnapshot(callID: "call-current", generation: 1, lifecycle: .ready)
        let call = CallLifecycleSnapshot(callID: "call-current", generation: 1, state: .capturing)
        XCTAssertEqual(CodingCallReconciliation.action(coding: coding, call: call), .none)
    }

    func testNormalEndAndFailedCaptureAreDistinct() {
        let coding = CodingSessionSnapshot(callID: "call-current", generation: 1, lifecycle: .capturing)
        for state in [CallLifecycleState.stopping, .processingRecap, .finished] {
            XCTAssertEqual(CodingCallReconciliation.action(coding: coding,
                call: .init(callID: "call-current", generation: 1, state: state)), .finished)
        }
        XCTAssertEqual(CodingCallReconciliation.action(coding: coding,
            call: .init(callID: "call-current", generation: 1, state: .failed)), .interrupted)
    }
}
