import XCTest
@testable import IntelligenceProviders
import IntelligenceCore
import CallaContracts

/// Bringing a council up, and the two ways that used to go wrong.
final class QuizAgyWarmPrepareTests: XCTestCase {
    private actor SpawnLog {
        private(set) var count = 0
        private let delay: Duration
        init(delay: Duration) { self.delay = delay }
        func record() async -> Int {
            count += 1
            try? await Task.sleep(for: delay)
            return count
        }
    }

    private final class InertChild: QuizAgyChild, @unchecked Sendable {
        func run(_ request: QuizAgyRequest, timeout: TimeInterval) async throws -> QuizAgyWorkerResult {
            throw QuizAgyFailure.processEnded
        }
        func cancel() async {}
    }

    func testConcurrentPrepareSpawnsOneChild() async throws {
        // A warm bench handed to a starting session is prepared twice: once by
        // the preflight, once by `start()` covering any slot the first attempt
        // missed. The guard at the top of `prepare()` is checked before the
        // await, so both callers used to pass it and both used to spawn — one
        // ~190 MB `agy` child then had nothing holding it.
        let log = SpawnLog(delay: .milliseconds(50))
        let supervisor = QuizAgySupervisor(
            slot: 0, role: .voter, selection: QuizModelSelection(modelID: "model"),
            factory: { _, _, _ in
                _ = await log.record()
                return InertChild()
            })

        async let first: Void = supervisor.prepare()
        async let second: Void = supervisor.prepare()
        _ = try await (first, second)

        let spawned = await log.count
        XCTAssertEqual(spawned, 1)
        let ready = await supervisor.isReady
        XCTAssertTrue(ready)
    }

    func testPreparingAnAlreadyReadySlotIsFree() async throws {
        let log = SpawnLog(delay: .zero)
        let supervisor = QuizAgySupervisor(
            slot: 0, role: .voter, selection: QuizModelSelection(modelID: "model"),
            factory: { _, _, _ in
                _ = await log.record()
                return InertChild()
            })
        try await supervisor.prepare()
        try await supervisor.prepare()
        let spawned = await log.count
        XCTAssertEqual(spawned, 1)
    }

    func testAFailedPrepareStillReportsAndCanBeRetried() async throws {
        let attempts = SpawnLog(delay: .zero)
        let supervisor = QuizAgySupervisor(
            slot: 0, role: .voter, selection: QuizModelSelection(modelID: "model"),
            factory: { _, _, _ in
                let attempt = await attempts.record()
                if attempt == 1 { throw QuizAgyFailure.spawn("no") }
                return InertChild()
            })
        do {
            try await supervisor.prepare()
            XCTFail("the first prepare should have thrown")
        } catch {}
        // The retry is the session's second attempt on a slot the preflight's
        // warm-up could not fill; it must not be blocked by the first failure.
        try await supervisor.prepare()
        let ready = await supervisor.isReady
        XCTAssertTrue(ready)
    }
}
