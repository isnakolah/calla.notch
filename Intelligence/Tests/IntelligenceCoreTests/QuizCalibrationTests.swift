import CallaContracts
@testable import IntelligenceCore
import XCTest

final class QuizCalibrationTests: XCTestCase {
    private func samples(kind: QuizQuestionKind, confidence: Int,
                         correct: Int, wrong: Int) -> [QuizCalibrationSample] {
        (0 ..< correct).map { _ in
            QuizCalibrationSample(kind: kind, displayedConfidence: confidence, correct: true)
        } + (0 ..< wrong).map { _ in
            QuizCalibrationSample(kind: kind, displayedConfidence: confidence, correct: false)
        }
    }

    func testNoGradedAnswersLeavesConfidenceUntouched() {
        // Which is exactly what the product did before — but by never having been
        // wired up, rather than by measurement.
        let calibration = QuizCalibrationBuilder.build(from: [])
        XCTAssertEqual(calibration.display(raw: 97, kind: .singleChoice), 97)
    }

    func testAnOverconfidentBandIsCappedAtWhatItEarned() {
        // 30 answers in the 90s, 21 right: the band is worth 70%, not 95%.
        let calibration = QuizCalibrationBuilder.build(
            from: samples(kind: .singleChoice, confidence: 95, correct: 21, wrong: 9))
        XCTAssertEqual(calibration.display(raw: 95, kind: .singleChoice), 70)
    }

    func testAWellCalibratedBandIsNotPenalised() {
        let calibration = QuizCalibrationBuilder.build(
            from: samples(kind: .boolean, confidence: 80, correct: 25, wrong: 0))
        XCTAssertEqual(calibration.display(raw: 80, kind: .boolean), 80)
    }

    func testAThinBandFallsBackToTheKindsOverallAccuracy() {
        // Three samples cannot be trusted on their own, so the kind's overall
        // record decides instead.
        var all = samples(kind: .numeric, confidence: 95, correct: 1, wrong: 2)
        all += samples(kind: .numeric, confidence: 55, correct: 12, wrong: 13)
        let calibration = QuizCalibrationBuilder.build(from: all)
        let overall = Double(13) / Double(28)
        XCTAssertEqual(calibration.display(raw: 95, kind: .numeric), Int(floor(overall * 100)))
    }

    func testCalibrationIsPerKind() {
        var all = samples(kind: .singleChoice, confidence: 95, correct: 30, wrong: 0)
        all += samples(kind: .text, confidence: 95, correct: 6, wrong: 24)
        let calibration = QuizCalibrationBuilder.build(from: all)
        XCTAssertEqual(calibration.display(raw: 95, kind: .singleChoice), 95)
        XCTAssertEqual(calibration.display(raw: 95, kind: .text), 20)
    }

    func testCalibrationNeverRaisesAConfidence() {
        let calibration = QuizCalibrationBuilder.build(
            from: samples(kind: .boolean, confidence: 15, correct: 25, wrong: 0))
        // A band that outperforms its own claim still reports the claim.
        XCTAssertEqual(calibration.display(raw: 15, kind: .boolean), 15)
    }
}
