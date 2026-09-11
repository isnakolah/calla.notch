import XCTest
@testable import IntelligenceCore

final class QuizQuestionGateTests: XCTestCase {
    func testQuestionAnchorPassesImmediately() {
        XCTAssertEqual(
            QuizQuestionGate.classify(
                ocr: "freecodecamp question 2 which of the following is true",
                anchors: ["question 2"]),
            .question)
    }

    func testDirectQuestionAndChoicePromptsPassLocally() {
        XCTAssertEqual(
            QuizQuestionGate.classify(ocr: "Which value is correct", anchors: []),
            .question)
        XCTAssertEqual(
            QuizQuestionGate.classify(ocr: "Select all correct answers below", anchors: []),
            .question)
    }

    func testOrdinaryStablePageWaitsWithoutCouncil() {
        XCTAssertEqual(
            QuizQuestionGate.classify(
                ocr: "Welcome to your dashboard recent activity courses profile and account settings",
                anchors: []),
            .notQuestion)
    }

    func testADeclarativeStemWithUnlabelledOptionsIsNotRefused() {
        // Taken from a session where nothing was ever answered. The stem is a
        // statement, the options are radio buttons that OCR as nothing, and the
        // reading is imperfect — "volcanlc acllv5ty". No interrogative, no prompt
        // phrase, twenty-three words, so the old gate called it prose and the
        // council never saw it. Refusing here is the one mistake that costs the
        // reader the answer with nothing on screen to explain it.
        XCTAssertNotEqual(
            QuizQuestionGate.classify(
                ocr: "historical temperatures of earth s atmosphere can be inferred from the "
                    + "analysis of tree rings and microwave radiation ice cores anth511s "
                    + "volcanlc acllv5ty",
                anchors: []),
            .notQuestion)
    }

    func testADeclarativeStemWithLetteredOptionsIsAQuestion() {
        XCTAssertEqual(
            QuizQuestionGate.classify(
                ocr: "the time complexity of the loop below is "
                    + "a o n log n b o n squared c o n d o log n",
                anchors: []),
            .question)
    }

    func testTheScreensWorthSkippingAreStillSkipped() {
        for page in ["you scored 8 out of 10 on this lesson review your answers below",
                     "account settings notifications appearance language and region",
                     "sign in to continue with your saved progress and streak"] {
            XCTAssertEqual(QuizQuestionGate.classify(ocr: page, anchors: []), .notQuestion, page)
        }
    }

    func testSparseAndImageOnlyFramesRemainConservative() {
        XCTAssertEqual(QuizQuestionGate.classify(ocr: "", anchors: []), .uncertain)
        XCTAssertEqual(QuizQuestionGate.classify(ocr: "2 2", anchors: []), .uncertain)
    }
}
