import CallaContracts
@testable import CallaNotchPresentation
import XCTest

final class CallaQuizPresentationTests: XCTestCase {
    private func answer(_ id: String, text: String = "B", confidence: Int = 90,
                        question: String? = nil) -> QuizFinalAnswer {
        QuizFinalAnswer(id: id, sessionID: "session-abcdefgh",
                        questionID: question ?? "question-\(id)", questionGeneration: 1,
                        kind: .singleChoice, answer: text, confidence: confidence,
                        verified: true)
    }

    private func snapshot(_ state: QuizSessionState, answer: QuizFinalAnswer? = nil,
                          answers: [QuizFinalAnswer]? = nil, failure: String? = nil,
                          scrollPrompt: QuizCommandKind? = nil) -> QuizSessionSnapshot {
        QuizSessionSnapshot(sessionID: "session-abcdefgh", state: state, answer: answer,
                           answers: answers, scrollPrompt: scrollPrompt, failure: failure)
    }

    // MARK: - Stage ladder

    func testFailedStateIsReportedRatherThanReadingAsHealthy() {
        // The old ladder had no `.failed` branch, so a failed session fell
        // through to "Watching for next question…".
        let stage = CallaQuizPresentation.stage(
            for: snapshot(.failed, failure: "AGY authentication is required"))
        XCTAssertEqual(stage, .failed("AGY authentication is required"))
    }

    func testFailedStateWithoutDetailStillReportsFailure() {
        XCTAssertEqual(CallaQuizPresentation.stage(for: snapshot(.failed)),
                       .failed("Quiz stopped unexpectedly"))
    }

    func testLifecycleWinsOverAPresentAnswer() {
        // Every one of these was unreachable when `answer != nil` was checked
        // first — including `.paused`, whose Resume button was the only way back.
        let shown = answer("a1")
        XCTAssertEqual(CallaQuizPresentation.stage(for: snapshot(.stopping, answer: shown)),
                       .stopping)
        XCTAssertEqual(CallaQuizPresentation.stage(for: snapshot(.paused, answer: shown,
                                                                failure: "Target lost")),
                       .paused("Target lost"))
        XCTAssertEqual(CallaQuizPresentation.stage(for: snapshot(.failed, answer: shown,
                                                                failure: "Host died")),
                       .failed("Host died"))
        XCTAssertEqual(CallaQuizPresentation.stage(for: snapshot(.solving, answer: shown)),
                       .working("Reasoning…"))
    }

    func testBlankFailureTextIsNotShownAsAPausedReason() {
        XCTAssertEqual(CallaQuizPresentation.stage(for: snapshot(.paused, failure: "   ")),
                       .paused(nil))
    }

    func testCollectingCarriesTheScrollDirection() {
        XCTAssertEqual(
            CallaQuizPresentation.stage(for: snapshot(.collecting, scrollPrompt: .scrollDown)),
            .collecting(.scrollDown))
    }

    func testWatchingWithoutAnAnswerIsWatching() {
        XCTAssertEqual(CallaQuizPresentation.stage(for: snapshot(.watching)), .watching)
        XCTAssertEqual(CallaQuizPresentation.stage(for: snapshot(.watching, answer: answer("a1"))),
                       .answered)
    }

    func testTargetLabelFallsBackToTheApplicationName() {
        let target = QuizWindowTarget(processID: 42, windowID: 7, bundleID: "com.example.app",
                                      applicationName: "Example", windowTitle: "   ",
                                      pixelWidth: 800, pixelHeight: 600)
        XCTAssertEqual(CallaQuizPresentation.targetLabel(for: target), "Example")
        XCTAssertEqual(CallaQuizPresentation.targetLabel(for: nil), "No target window")
    }

    // MARK: - Code answers

    func testFencedCodeLosesItsFencesAndKeepsItsLanguage() {
        let parsed = CallaQuizPresentation.code(from: """
        ```python
        class Solution(object):
            def minimumDeletions(self, nums):
                return 1
        ```
        """)
        XCTAssertEqual(parsed.language, "python")
        XCTAssertFalse(parsed.body.contains("```"))
        XCTAssertTrue(parsed.body.hasPrefix("class Solution(object):"))
        XCTAssertTrue(parsed.body.hasSuffix("return 1"))
        // Indentation is the code; it has to survive exactly.
        XCTAssertEqual(parsed.lines[1], "    def minimumDeletions(self, nums):")
    }

    /// A LeetCode page classifies as `.text`, so the kind cannot be what decides
    /// whether an answer is drawn as code.
    func testFencedPythonIsRecognisedAsCodeWhateverTheKindSaid() {
        let answer = QuizFinalAnswer(id: "a1", sessionID: "session-abcdefgh",
                                     questionID: "q1", questionGeneration: 1,
                                     kind: .text,
                                     answer: "```python\nclass Solution(object):\n    def f(self):\n        return 1\n```",
                                     confidence: 50, verified: true)
        XCTAssertTrue(CallaQuizPresentation.looksLikeCode(answer.answer))
        XCTAssertEqual(CallaQuizPresentation.copyableText(for: answer),
                       "class Solution(object):\n    def f(self):\n        return 1")
    }

    func testUnfencedCodeIsStillRecognised() {
        XCTAssertTrue(CallaQuizPresentation.looksLikeCode(
            "def solve(nums):\n    total = 0\n    return total"))
    }

    func testProseIsNotMistakenForCode() {
        XCTAssertFalse(CallaQuizPresentation.looksLikeCode(
            "The minimum number of deletions is five.\nRemove two from the front and three from the back."))
        XCTAssertFalse(CallaQuizPresentation.looksLikeCode("B — Paris"))
    }

    func testAnUnfencedAnswerIsLeftAlone() {
        let parsed = CallaQuizPresentation.code(from: "return len(nums)")
        XCTAssertNil(parsed.language)
        XCTAssertEqual(parsed.body, "return len(nums)")
    }

    func testAFenceWithNoLanguageStillUnwraps() {
        let parsed = CallaQuizPresentation.code(from: "```\nprint(1)\n```")
        XCTAssertNil(parsed.language)
        XCTAssertEqual(parsed.body, "print(1)")
    }

    func testAnUnterminatedFenceIsStillShown() {
        // Better a body with no closing fence than nothing at all.
        let parsed = CallaQuizPresentation.code(from: "```swift\nlet x = 1")
        XCTAssertEqual(parsed.language, "swift")
        XCTAssertEqual(parsed.body, "let x = 1")
    }

    func testCopyingCodeNeverPutsFencesOnThePasteboard() {
        let answer = QuizFinalAnswer(id: "a1", sessionID: "session-abcdefgh",
                                     questionID: "q1", questionGeneration: 1, kind: .code,
                                     answer: "```python\nprint(1)\n```", confidence: 90,
                                     verified: true)
        XCTAssertEqual(CallaQuizPresentation.copyableText(for: answer), "print(1)")
    }

    func testCopyingANonCodeAnswerIsUnchanged() {
        let answer = QuizFinalAnswer(id: "a1", sessionID: "session-abcdefgh",
                                     questionID: "q1", questionGeneration: 1, kind: .singleChoice,
                                     answer: "B — Paris", confidence: 90, verified: true)
        XCTAssertEqual(CallaQuizPresentation.copyableText(for: answer), "B — Paris")
    }

    private func roles(_ line: String) -> [CallaQuizPresentation.CodeTokenRole] {
        CallaQuizPresentation.tokenize(line).map(\.role)
    }

    func testTokenizerFindsKeywordsStringsNumbersAndComments() {
        let tokens = CallaQuizPresentation.tokenize("return 42  # done")
        XCTAssertEqual(tokens.first?.role, .keyword)
        XCTAssertTrue(tokens.contains { $0.role == .number && $0.text == "42" })
        XCTAssertTrue(tokens.contains { $0.role == .comment && $0.text.contains("done") })
    }

    func testTokenizerKeepsTheLineIntact() {
        // Whatever the colouring, joining the runs must give the line back —
        // otherwise the code on screen is not the code the model wrote.
        for line in ["    def minimumDeletions(self, nums):",
                     "x = 'a' + \"b\"  # mix",
                     "if n <= 10**5 and not seen:",
                     "        \"\"\"docstring\"\"\"",
                     ""] {
            XCTAssertEqual(CallaQuizPresentation.tokenize(line).map(\.text).joined(), line)
        }
    }

    func testStringsAreNotMistakenForCode() {
        let tokens = CallaQuizPresentation.tokenize("s = \"return if\"")
        // The keywords inside the literal stay part of the string.
        XCTAssertTrue(tokens.contains { $0.role == .string && $0.text == "\"return if\"" })
        XCTAssertFalse(tokens.contains { $0.role == .keyword && $0.text == "if" })
    }

    func testIndentationSurvivesTokenizing() {
        let line = "        return 1"
        XCTAssertEqual(CallaQuizPresentation.tokenize(line).map(\.text).joined(), line)
    }

    // MARK: - Answer navigation

    func testEmptyHistoryHasNothingToShow() {
        let position = CallaQuizPresentation.position(.latest, history: [])
        XCTAssertNil(position.answer)
        XCTAssertNil(position.label)
        XCTAssertFalse(position.canGoBack)
        XCTAssertFalse(position.canGoForward)
    }

    func testFollowingShowsTheNewestAnswer() {
        let history = [answer("a1"), answer("a2"), answer("a3")]
        let position = CallaQuizPresentation.position(.latest, history: history)
        XCTAssertEqual(position.answer?.id, "a3")
        XCTAssertEqual(position.label, "3 / 3")
        XCTAssertFalse(position.hasNewer)
    }

    func testASingleAnswerIsNotNumbered() {
        XCTAssertNil(CallaQuizPresentation.position(.latest, history: [answer("a1")]).label)
    }

    func testSteppingBackAndForwardWalksTheHistory() {
        let history = [answer("a1"), answer("a2"), answer("a3")]
        var cursor = CallaQuizPresentation.back(.latest, history: history)
        XCTAssertEqual(CallaQuizPresentation.position(cursor, history: history).answer?.id, "a2")
        cursor = CallaQuizPresentation.back(cursor, history: history)
        XCTAssertEqual(CallaQuizPresentation.position(cursor, history: history).answer?.id, "a1")
        // Already at the oldest: no further movement, and no wrap-around.
        cursor = CallaQuizPresentation.back(cursor, history: history)
        XCTAssertEqual(CallaQuizPresentation.position(cursor, history: history).answer?.id, "a1")
        cursor = CallaQuizPresentation.forward(cursor, history: history)
        XCTAssertEqual(CallaQuizPresentation.position(cursor, history: history).answer?.id, "a2")
    }

    func testReachingTheEndResumesFollowing() {
        let history = [answer("a1"), answer("a2")]
        let back = CallaQuizPresentation.back(.latest, history: history)
        XCTAssertFalse(back.isFollowingLatest)
        let forward = CallaQuizPresentation.forward(back, history: history)
        XCTAssertTrue(forward.isFollowingLatest)
    }

    func testANewAnswerDoesNotYankAReaderWhoSteppedBack() {
        // The rule that makes this feel calm: browsing an earlier answer is not
        // interrupted, it is only advertised.
        let history = [answer("a1"), answer("a2")]
        let cursor = CallaQuizPresentation.back(.latest, history: history)
        let grown = history + [answer("a3")]
        let position = CallaQuizPresentation.position(cursor, history: grown)
        XCTAssertEqual(position.answer?.id, "a1")
        XCTAssertTrue(position.hasNewer)
        XCTAssertEqual(position.label, "1 / 3")
    }

    func testFollowingReaderDoesAdvanceToANewAnswer() {
        let history = [answer("a1")]
        let grown = history + [answer("a2")]
        XCTAssertEqual(CallaQuizPresentation.position(.latest, history: grown).answer?.id, "a2")
    }

    func testACursorOntoATrimmedAnswerSnapsToLatest() {
        // The history is capped and trims from the front, so a held id can
        // vanish. Reconciling makes that one deliberate move.
        let cursor = CallaQuizPresentation.Cursor(answerID: "gone")
        let history = [answer("a2"), answer("a3")]
        XCTAssertEqual(CallaQuizPresentation.reconcile(cursor, history: history), .latest)
        XCTAssertEqual(CallaQuizPresentation.position(cursor, history: history).answer?.id, "a3")
    }

    func testReconcileKeepsAStillPresentCursor() {
        let cursor = CallaQuizPresentation.Cursor(answerID: "a2")
        let history = [answer("a2"), answer("a3")]
        XCTAssertEqual(CallaQuizPresentation.reconcile(cursor, history: history), cursor)
    }
}
