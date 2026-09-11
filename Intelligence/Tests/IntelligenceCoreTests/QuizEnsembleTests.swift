import XCTest
@testable import IntelligenceCore
import CallaContracts

final class QuizEnsembleTests: XCTestCase {
    func testParserUnwrapsNestedProviderEnvelope() throws {
        let nested = #"{"answer":"{\"answer\":\"C — All arborescence are DAGs\",\"confidence\":100}","confidence":92}"#
        let parsed = try QuizWorkerOutputParser.parse(Data(nested.utf8))
        XCTAssertEqual(parsed.answer, "C — All arborescence are DAGs")
        XCTAssertEqual(parsed.confidence, 92)
    }

    func testTwoNotAQuestionVotesReturnToWatchingDecision() {
        let notQuestion = QuizWorkerOutput(answer: "__NOT_A_QUESTION__", confidence: 0)
        let strayAnswer = QuizWorkerOutput(answer: "A — Maybe", confidence: 40)
        XCTAssertEqual(
            QuizEnsembleResolver.decide(
                votes: [notQuestion, notQuestion, strayAnswer], kind: .unknown),
            .notAQuestion)
    }

    private struct Fixture: Decodable {
        let questionKind: String
        let expectedAnswer: String
    }

    private func freeCodeCampFixture() throws -> Fixture {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("TestFixtures/Quiz").path) {
            root.deleteLastPathComponent()
        }
        let data = try Data(contentsOf: root.appendingPathComponent(
            "TestFixtures/Quiz/freecodecamp-arborescence-question-2.json"))
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    func testStrictParserRejectsExtraKeysAndNonIntegerConfidence() throws {
        XCTAssertThrowsError(try QuizWorkerOutputParser.parse(
            Data(#"{"answer":"B","confidence":90,"reason":"hidden"}"#.utf8)))
        XCTAssertThrowsError(try QuizWorkerOutputParser.parse(
            Data(#"{"answer":"B","confidence":90.5}"#.utf8)))
        XCTAssertEqual(try QuizWorkerOutputParser.parse(
            Data(#"{"answer":"B","confidence":90}"#.utf8)),
            QuizWorkerOutput(answer: "B", confidence: 90))
    }

    // MARK: - Viewport OCR

    func testScrollOverlapIsNotFedToTheModelTwice() {
        let first = "question 2\nwhich statement is true\na all trees are dags"
        let second = "a all trees are dags\nb no dag is a tree\nc all arborescences are dags"
        let merged = QuizViewportOCR.merged([first, second])
        XCTAssertEqual(merged.components(separatedBy: "a all trees are dags").count - 1, 1,
                       "the overlapping line must appear once")
        XCTAssertTrue(merged.contains("c all arborescences are dags"))
        XCTAssertTrue(merged.contains("question 2"))
    }

    func testFirstViewportIsKeptWholeEvenWhenItRepeatsItself() {
        // Repetition inside one frame is what the screen actually said.
        let only = "pick one\npick one"
        XCTAssertEqual(QuizViewportOCR.merged([only]), "pick one\npick one")
    }

    func testAFullyRepeatedViewportContributesNothing() {
        let merged = QuizViewportOCR.merged(["a\nb", "b\na"])
        XCTAssertEqual(merged, "a\nb")
    }

    func testSingleViewportIsUnchanged() {
        XCTAssertEqual(QuizViewportOCR.merged(["only line"]), "only line")
        XCTAssertEqual(QuizViewportOCR.merged([]), "")
    }

    // MARK: - Canonicalisation
    //
    // Every case below used to canonicalise to a different string from at least
    // one of its siblings, which turned voter agreement into an arbiter round.

    func testChoiceLabelSurvivesAnySeparator() {
        let written = ["B", "B — Paris", "B – Paris", "B - Paris", "B) Paris",
                       "B. Paris", "(B) Paris", "[B] Paris", "b — paris"]
        let canonical = Set(written.map {
            QuizAnswerCanonicalizer.canonical($0, kind: .singleChoice)
        })
        XCTAssertEqual(canonical, ["B"])
    }

    func testUnanimousChoiceWithMixedSeparatorsPublishes() {
        let votes = [QuizWorkerOutput(answer: "C) All arborescences are DAGs", confidence: 95),
                     QuizWorkerOutput(answer: "C — All arborescences are DAGs", confidence: 91),
                     QuizWorkerOutput(answer: "C", confidence: 88)]
        XCTAssertEqual(QuizEnsembleResolver.decide(votes: votes, kind: .singleChoice),
                       .publish(answer: "C) All arborescences are DAGs", confidence: 88))
    }

    func testProseAnswerIsNotTruncatedAtItsFirstPunctuation() {
        // "Paris" is six characters, so it is prose, not a label: the whole
        // string has to compare or two different sentences sharing a first word
        // would read as agreement.
        XCTAssertNotEqual(
            QuizAnswerCanonicalizer.canonical("Paris - the capital", kind: .singleChoice),
            QuizAnswerCanonicalizer.canonical("Paris - the largest city", kind: .singleChoice))
    }

    func testMultipleChoiceIgnoresOrderAndSpelling() {
        let written = ["A, C", "C, A", "A and C", "AC", "C;A", "A / C",
                       "A, C — both are valid"]
        let canonical = Set(written.map {
            QuizAnswerCanonicalizer.canonical($0, kind: .multipleChoice)
        })
        XCTAssertEqual(canonical, ["A,C"])
    }

    func testNumericTrailingZerosAndGroupingAgree() {
        let written = ["3", "3.0", "3.00", "03", "+3"]
        let canonical = Set(written.map {
            QuizAnswerCanonicalizer.canonical($0, kind: .numeric)
        })
        XCTAssertEqual(canonical, ["3"])
        XCTAssertEqual(QuizAnswerCanonicalizer.canonical("1,000", kind: .numeric),
                       QuizAnswerCanonicalizer.canonical("1000", kind: .numeric))
    }

    func testNumericKeepsUnitsAndDistinguishesValues() {
        XCTAssertEqual(QuizAnswerCanonicalizer.canonical("42%", kind: .numeric), "42%")
        XCTAssertEqual(QuizAnswerCanonicalizer.canonical("\u{2212}7.50", kind: .numeric), "-7.5")
        XCTAssertNotEqual(QuizAnswerCanonicalizer.canonical("3.1", kind: .numeric),
                          QuizAnswerCanonicalizer.canonical("3.10001", kind: .numeric))
    }

    func testUnanimousNumericWithDifferentFormattingPublishes() {
        let votes = [QuizWorkerOutput(answer: "3.0", confidence: 96),
                     QuizWorkerOutput(answer: "3", confidence: 93),
                     QuizWorkerOutput(answer: "3.00", confidence: 90)]
        XCTAssertEqual(QuizEnsembleResolver.decide(votes: votes, kind: .numeric),
                       .publish(answer: "3.0", confidence: 90))
    }

    func testUnanimousObjectiveVotePublishesMinimumConfidence() {
        let votes = [QuizWorkerOutput(answer: "B — Photosynthesis", confidence: 94),
                     QuizWorkerOutput(answer: "B", confidence: 91),
                     QuizWorkerOutput(answer: "B — photosynthesis", confidence: 88)]
        XCTAssertEqual(QuizEnsembleResolver.decide(votes: votes, kind: .singleChoice),
                       .publish(answer: "B — Photosynthesis", confidence: 88))
    }

    func testTwoOfThreeNeverPublishesWithoutArbiter() {
        let votes = [QuizWorkerOutput(answer: "True", confidence: 99),
                     QuizWorkerOutput(answer: "True", confidence: 98),
                     QuizWorkerOutput(answer: "False", confidence: 70)]
        XCTAssertEqual(QuizEnsembleResolver.decide(votes: votes, kind: .boolean), .arbitrate)
    }

    func testSemanticAnswerAlwaysUsesArbiter() {
        let votes = Array(repeating: QuizWorkerOutput(answer: "Mitochondria", confidence: 90), count: 3)
        XCTAssertEqual(QuizEnsembleResolver.decide(votes: votes, kind: .text), .arbitrate)
    }

    func testTwoScrollSentinelsProducePrompt() {
        let votes: [QuizWorkerOutput?] = [
            .init(answer: "__NEEDS_SCROLL_DOWN__", confidence: 0),
            .init(answer: "__NEEDS_SCROLL_DOWN__", confidence: 0),
            .init(answer: "B", confidence: 50),
        ]
        XCTAssertEqual(QuizEnsembleResolver.decide(votes: votes, kind: .singleChoice),
                       .scroll(.needsScrollDown))
    }

    func testNovelArbiterAnswerIsCappedAtFifty() {
        let votes: [QuizWorkerOutput?] = [
            .init(answer: "A", confidence: 80), .init(answer: "B", confidence: 80),
            .init(answer: "C", confidence: 80),
        ]
        let result = QuizEnsembleResolver.resolveArbiter(
            .init(answer: "D", confidence: 97), votes: votes, kind: .singleChoice)
        XCTAssertEqual(result?.1, 50)
    }

    func testCalibrationNeverOverstatesMeasuredBucketAccuracy() {
        let calibration = QuizConfidenceCalibration(
            buckets: [.init(kind: .boolean, lowerBound: 90, measuredAccuracy: 0.82, sampleCount: 25)],
            overallAccuracyByKind: [.boolean: 0.75])
        XCTAssertEqual(calibration.display(raw: 96, kind: .boolean), 82)
    }

    func testFreeCodeCampFixtureUnanimousChoicePublishesExpectedAnswer() throws {
        let fixture = try freeCodeCampFixture()
        XCTAssertEqual(fixture.questionKind, QuizQuestionKind.singleChoice.rawValue)
        let votes = [96, 92, 94].map {
            QuizWorkerOutput(answer: fixture.expectedAnswer, confidence: $0)
        }
        XCTAssertEqual(
            QuizEnsembleResolver.decide(votes: votes, kind: .singleChoice),
            .publish(answer: fixture.expectedAnswer, confidence: 92))
    }
}
