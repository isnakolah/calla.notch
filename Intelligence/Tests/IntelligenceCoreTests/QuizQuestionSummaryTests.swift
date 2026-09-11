import CallaContracts
@testable import IntelligenceCore
import XCTest

final class QuizQuestionSummaryTests: XCTestCase {
    private func summary(_ headlines: [String], fallback: String = "",
                         kind: QuizQuestionKind = .code) -> String? {
        QuizQuestionSummary.summarize(headlines: headlines, fallback: fallback, kind: kind)
    }

    func testALeetCodeTitleSurvivesAsWritten() {
        // The point of carrying raw lines: case and punctuation intact, rather
        // than "2091 removing minimum and maximum from array".
        let result = summary([
            "Daily Question",
            "Description", "Editorial", "Solutions", "Submissions",
            "2091. Removing Minimum and Maximum From Array",
            "Medium", "Topics", "Companies", "Hint",
        ])
        XCTAssertEqual(result, "2091. Removing Minimum and Maximum From Array")
    }

    func testAQuestionSentenceBeatsATitle() {
        let result = summary([
            "Question 2 of 10",
            "Which of the following statements is true?",
            "A) All trees are arborescences",
        ], kind: .singleChoice)
        XCTAssertEqual(result, "Which of the following statements is true?")
    }

    func testChromeAndBadgesAreNotASummary() {
        XCTAssertNil(summary(["Description", "Medium", "Code", "Saved", "Python", "Run"]))
    }

    func testShortAndNumericLinesAreSkipped() {
        let result = summary(["27", "Ln 1, Col 1", "Reverse the given linked list in place"])
        XCTAssertEqual(result, "Reverse the given linked list in place")
    }

    func testALongTitleIsCutOnAWordBoundary() {
        let long = "Return the minimum number of deletions it would take to remove both the minimum and maximum element"
        let result = summary([long])
        let value = try? XCTUnwrap(result)
        XCTAssertNotNil(value)
        XCTAssertLessThanOrEqual(result?.count ?? 0, QuizQuestionSummary.limit + 1)
        XCTAssertTrue(result?.hasSuffix("…") == true)
        // Cut between words, not through one.
        XCTAssertFalse(result?.dropLast().hasSuffix(" ") == true)
        XCTAssertTrue(long.hasPrefix(result?.dropLast().description ?? "nope"))
    }

    func testTheNormalisedTextIsTheLastResort() {
        // Ugly, but better than showing the reader nothing at all.
        let result = QuizQuestionSummary.summarize(
            headlines: nil,
            fallback: "which of the following statements is true a all trees are arborescences",
            kind: .singleChoice)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasPrefix("which of the following") == true)
    }

    func testACleanTitleBeatsAMangledQuestionLine() {
        // Real case: a low-contrast question line came back as
        // "inese are resurts or umed quizzes, very nara". It is the right
        // question, unreadably so — the clean title is the more useful label.
        let result = summary([
            "inese are resurts or umed quizzes, very nara",
            "2091. Removing Minimum and Maximum From Array",
        ])
        XCTAssertEqual(result, "2091. Removing Minimum and Maximum From Array")
    }

    func testAMangledLineIsStillBetterThanNothing() {
        let result = summary(["inese are resurts or umed quizzes, very nara"])
        XCTAssertEqual(result, "inese are resurts or umed quizzes, very nara")
    }

    func testLegibilityRanksProseAboveNoise() {
        let prose = QuizQuestionSummary.legibility("Which of the following statements is true?")
        let noise = QuizQuestionSummary.legibility("l1 n m 0 x q j 1 rn v")
        XCTAssertGreaterThan(prose, noise)
        XCTAssertGreaterThan(prose, QuizQuestionSummary.minimumLegibilityForTests)
        XCTAssertLessThan(noise, QuizQuestionSummary.minimumLegibilityForTests)
    }

    func testNothingAtAllSummarisesToNothing() {
        XCTAssertNil(QuizQuestionSummary.summarize(headlines: nil, fallback: "", kind: .text))
        XCTAssertNil(QuizQuestionSummary.summarize(headlines: [], fallback: "   ", kind: .text))
    }
}
