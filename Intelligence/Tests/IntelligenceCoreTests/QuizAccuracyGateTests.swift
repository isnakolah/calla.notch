import CallaContracts
import XCTest
@testable import IntelligenceCore

final class QuizAccuracyGateTests: XCTestCase {
    func testCompleteSyntheticCorpusPassesAllReleaseConditions() {
        var records: [QuizEvaluationRecord] = []
        for kind in QuizAccuracyGate.supportedKinds {
            for index in 0 ..< 20 {
                let workers = (0 ..< 3).map { slot in
                    QuizWorkerIdentity(slot: slot, modelID: "model-\(slot)", effort: "high",
                                       conversationID: "\(kind.rawValue)-\(index)-\(slot)",
                                       numberOfTurns: 1)
                }
                records.append(.init(
                    exampleID: "\(kind.rawValue)-\(index)", kind: kind,
                    voterCorrect: [index != 0, index > 1, index > 2], ensembleCorrect: true,
                    duration: 45, displayedConfidence: 90, workers: workers))
            }
        }
        XCTAssertTrue(QuizAccuracyGate.evaluate(records).passed)
    }

    func testGateRejectsOverstatedSparseConfidenceAndIsolationReuse() {
        let reused = QuizWorkerIdentity(slot: 0, modelID: "model", effort: "high",
                                        conversationID: "same-conversation", numberOfTurns: 1)
        let records = (0 ..< 20).map { index in
            QuizEvaluationRecord(
                exampleID: "choice-\(index)", kind: .singleChoice,
                voterCorrect: [true, false, false], ensembleCorrect: index < 10,
                duration: 121, displayedConfidence: 90,
                workers: [reused, reused, reused])
        }
        let report = QuizAccuracyGate.evaluate(records)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains { $0.contains("confidence overstates") })
        XCTAssertTrue(report.failures.contains { $0.contains("isolation") })
        XCTAssertTrue(report.failures.contains { $0.contains("120 seconds") })
    }
}
