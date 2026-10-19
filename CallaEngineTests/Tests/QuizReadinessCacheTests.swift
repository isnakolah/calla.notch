import XCTest
@testable import CallaEngineValidation

/// What Quiz remembers about the machine between engine restarts.
///
/// Both facts here cost a whole `agy` process to establish, and one of them
/// costs a real model round-trip on top. They were held in memory only, so every
/// deploy — which restarts the engine — made a reader wait for both again.
final class QuizReadinessCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quiz-readiness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testARecordSurvivesARestart() {
        let cache = QuizReadinessCache(directory: directory)
        var record = QuizReadiness()
        record.binaryPath = "/Users/someone/.local/bin/agy"
        record.models = ["gemini-3.7-flash-low", "claude-sonnet-4-6"]
        record.modelsCheckedAt = Date()
        record.authenticated = true
        record.authCheckedAt = Date()
        cache.save(record)

        // A different instance is the point: this is read by the engine that
        // starts after the one that wrote it.
        let reloaded = QuizReadinessCache(directory: directory).load()
        XCTAssertEqual(reloaded.binaryPath, record.binaryPath)
        XCTAssertEqual(reloaded.models, record.models)
        XCTAssertTrue(reloaded.authenticated)
        // Timestamps are ISO 8601 on disk, so they come back rounded to the
        // second. Nothing here is timed more finely than that.
        XCTAssertEqual(reloaded.modelsCheckedAt?.timeIntervalSinceReferenceDate ?? 0,
                       record.modelsCheckedAt?.timeIntervalSinceReferenceDate ?? 0,
                       accuracy: 1)
        XCTAssertTrue(reloaded.modelsAreFresh())
        XCTAssertTrue(reloaded.authIsFresh())
    }

    func testNothingWrittenMeansNothingKnown() {
        let empty = QuizReadinessCache(directory: directory).load()
        XCTAssertTrue(empty.models.isEmpty)
        XCTAssertFalse(empty.authenticated)
        XCTAssertFalse(empty.modelsAreFresh())
        XCTAssertFalse(empty.authIsFresh())
    }

    func testCorruptOnDiskReadsAsNothingKnownRatherThanThrowing() throws {
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("readiness.json"))
        let record = QuizReadinessCache(directory: directory).load()
        XCTAssertEqual(record, QuizReadiness())
    }

    func testTheAuthVerdictGoesStaleLongBeforeTheCatalogue() {
        // The catalogue changes when AGY ships models. The auth verdict is the
        // one that proves the refresh token still reaches AGY, so a revoked
        // credential must not stay believed for a day.
        var record = QuizReadiness()
        record.models = ["gemini-3.7-flash-low"]
        record.authenticated = true
        let anHourAgo = Date().addingTimeInterval(-3_600)
        record.modelsCheckedAt = anHourAgo
        record.authCheckedAt = anHourAgo
        XCTAssertTrue(record.modelsAreFresh())
        XCTAssertFalse(record.authIsFresh())
    }

    func testAnEmptyCatalogueIsNeverFresh() {
        var record = QuizReadiness()
        record.modelsCheckedAt = Date()
        XCTAssertFalse(record.modelsAreFresh())
    }

    func testANegativeAuthVerdictIsNeverFresh() {
        // "We checked and it failed" must send the next start to check again,
        // not skip the check.
        var record = QuizReadiness()
        record.authenticated = false
        record.authCheckedAt = Date()
        XCTAssertFalse(record.authIsFresh())
    }

    func testARecordForADifferentBinaryDoesNotCount() {
        // Two installs is not hypothetical — a Homebrew cask beside a
        // self-installed one is what `AgyLocator` exists to sort out — and one
        // binary's catalogue says nothing about another's.
        var record = QuizReadiness()
        record.binaryPath = "/opt/homebrew/bin/agy"
        XCTAssertTrue(record.matches(binary: "/opt/homebrew/bin/agy"))
        XCTAssertFalse(record.matches(binary: "/Users/someone/.local/bin/agy"))
    }
}
