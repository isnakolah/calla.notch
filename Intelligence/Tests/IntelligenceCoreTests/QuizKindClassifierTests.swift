import CallaContracts
@testable import IntelligenceCore
import XCTest

/// OCR reaching the classifier is already normalised: lower-cased, punctuation
/// flattened to spaces, and — the part that matters — **newlines removed**.
/// `QuizFrameObservation.normalizeOCR` ends with a whitespace split, so `B) Paris`
/// on its own line arrives as ` b paris ` in one long line.
///
/// These fixtures therefore go through `normalizeOCR` rather than being written as
/// pre-normalised multi-line strings, which is what let an earlier version of the
/// classifier pass its tests while never detecting an option block in production.
final class QuizKindClassifierTests: XCTestCase {
    private func normalized(_ raw: String) -> String {
        QuizFrameObservation.normalizeOCR(raw)
    }

    func testTheRealPipelineStillFindsOptionsAfterNewlinesAreStripped() {
        let page = normalized("""
        Question 2 of 10
        Which of the following statements is true?
        A) All trees are arborescences
        B) No arborescence is a tree
        C) All arborescences are DAGs
        D) Every DAG is a tree
        """)
        XCTAssertFalse(page.contains("\n"), "normalizeOCR removes newlines")
        XCTAssertEqual(QuizKindClassifier.classify(ocr: page), .singleChoice)
    }

    func testAProseParagraphFullOfArticlesIsNotAnOptionBlock() {
        // "in **a** cell" is the same shape as a label. What makes a block is the
        // run: a, then b, then c. This fixture is deliberately non-coding prose —
        // an earlier version used a LeetCode paragraph, which is coding-problem
        // prose and rightly classifies as code.
        let page = normalized("""
        Describe the process by which a plant converts light into chemical energy.
        A chloroplast is the organelle in which this happens, and the reaction
        requires water drawn up through the roots.
        Explain in your own words why the process stops in darkness.
        """)
        XCTAssertEqual(QuizKindClassifier.classify(ocr: page), .text)
    }

    func testFlattenedTrueFalseOptionsAreStillBoolean() {
        let page = normalized("""
        A DAG may contain a cycle
        A) True
        B) False
        """)
        XCTAssertEqual(QuizKindClassifier.classify(ocr: page), .boolean)
    }

    func testOptionBlockBeatsPhrasing() {
        // The old ladder checked "function" before any option detection, so this
        // multiple-choice question became `.code` — a kind that can never be
        // settled by voter unanimity, so it always paid for the arbiter.
        let ocr = """
        which statement about a function is true
        a it must return a value
        b it may take no arguments
        c it cannot be nested
        """
        XCTAssertEqual(QuizKindClassifier.classify(ocr: ocr), .singleChoice)
    }

    func testSelectAllMakesItMultipleChoice() {
        let ocr = """
        select all that apply
        a alpha
        b beta
        c gamma
        """
        XCTAssertEqual(QuizKindClassifier.classify(ocr: ocr), .multipleChoice)
    }

    func testNumberedOptionsAreRecognised() {
        let ocr = """
        pick the capital
        1 paris
        2 lyon
        3 nice
        """
        XCTAssertEqual(QuizKindClassifier.classify(ocr: ocr), .singleChoice)
    }

    func testTrueFalseOptionsCanonicaliseAsBoolean() {
        // Options that *are* true and false need boolean canonicalisation, or a
        // voter answering "True" and one answering "A" read as disagreement.
        let ocr = """
        a dag may contain a cycle
        a true
        b false
        """
        XCTAssertEqual(QuizKindClassifier.classify(ocr: ocr), .boolean)
    }

    func testProseStartingWithTheArticleAIsNotAnOptionBlock() {
        // A single leading letter plus a space is also how prose opens a sentence
        // with "a", which is why one label is never a block.
        let ocr = """
        a tree is a connected acyclic graph
        explain why every arborescence is also a dag
        """
        XCTAssertEqual(QuizKindClassifier.classify(ocr: ocr), .text)
    }

    func testAStemThatLooksLikeAnOptionDoesNotStealItsLabel() {
        // "a dag may contain a cycle" parses as label `a`, and used to claim the
        // slot before the real `a true` below it was ever read — which cost the
        // question its boolean canonicalisation.
        let ocr = """
        a dag may contain a cycle
        a true
        b false
        """
        XCTAssertEqual(QuizKindClassifier.classify(ocr: ocr), .boolean)
    }

    func testTrailingChromeBelowTheOptionsIsIgnored() {
        let ocr = """
        which is acyclic
        a a tree
        b a cyclic graph
        submit answer
        question 2 of 10
        """
        XCTAssertEqual(QuizKindClassifier.classify(ocr: ocr), .singleChoice)
    }

    func testNonContiguousLabelsAreNotAnOptionBlock() {
        let ocr = """
        describe the algorithm
        b something
        d something else
        """
        XCTAssertEqual(QuizKindClassifier.classify(ocr: ocr), .text)
    }

    func testEmptyOCRIsAScreenshotQuestion() {
        XCTAssertEqual(QuizKindClassifier.classify(ocr: ""), .image)
        XCTAssertEqual(QuizKindClassifier.classify(ocr: "   \n  "), .image)
    }

    func testPhrasingFallbacksWithoutAnOptionBlock() {
        XCTAssertEqual(QuizKindClassifier.classify(ocr: "true or false a dag is acyclic"), .boolean)
        XCTAssertEqual(QuizKindClassifier.classify(ocr: "write a function that reverses a list"), .code)
        XCTAssertEqual(QuizKindClassifier.classify(ocr: "calculate the total cost in dollars"), .numeric)
        XCTAssertEqual(QuizKindClassifier.classify(ocr: "how many edges does the tree have"), .numeric)
    }

    func testDiagramNeedsAPointerNotJustTheWord() {
        // "image" used to match anywhere, so any question mentioning one became
        // `.diagram`.
        XCTAssertEqual(QuizKindClassifier.classify(ocr: "which image format is lossless"), .text)
        XCTAssertEqual(QuizKindClassifier.classify(ocr: "in the diagram above which node is the root"),
                       .diagram)
    }

    /// LeetCode 2091, as the page actually reads.
    ///
    /// Two ways this page fools a classifier: `Example 1` / `Example 2` /
    /// `Example 3` is a perfectly good ascending numbered run, and the prose is
    /// full of standalone articles. It is prose, and has to stay prose.
    func testALeetCodeProblemIsProseNotAnOptionBlock() {
        let page = normalized("""
        2091. Removing Minimum and Maximum From Array
        Medium   Topics   Companies   Hint
        You are given a 0-indexed array of distinct integers nums.
        There is an element in nums that has the lowest value and an element that
        has the highest value. We call them the minimum and maximum respectively.
        Return the minimum number of deletions it would take to remove both the
        minimum and maximum element from the array.
        Example 1:
        Input: nums = [2,10,7,5,4,1,8,6]
        Output: 5
        Explanation:
        The minimum element in the array is nums[5], which is 1.
        Example 2:
        Input: nums = [0,-4,19,1,8,-2,-3,5]
        Output: 3
        Example 3:
        Input: nums = [101]
        Output: 1
        Constraints:
        1 <= nums.length <= 10^5
        The integers in nums are distinct.
        class Solution(object):
            def minimumDeletions(self, nums):
        """)
        // Code, so it reaches the Open council rather than the fast Choice one.
        XCTAssertEqual(QuizKindClassifier.classify(ocr: page), .code)
        XCTAssertEqual(QuizMode.mode(for: .code), .open)
    }

    /// The page furniture around a coding problem outranks anything that looks
    /// like an option run, because that run is the numbered examples.
    func testNumberedExamplesOnACodingPageNeverReadAsOptions() {
        let page = normalized("""
        2091. Removing Minimum and Maximum From Array
        Return the minimum number of deletions.
        Example 1:
        Input: nums = [2,10,7]
        Output: 5
        Example 2:
        Input: nums = [0,-4,19]
        Output: 3
        Example 3:
        Input: nums = [101]
        Output: 1
        Constraints:
        1 <= nums.length <= 10^5
        Testcase   Test Result
        """)
        XCTAssertEqual(QuizKindClassifier.classify(ocr: page), .code)
    }

    func testAChoiceQuestionMentioningAFunctionIsStillAChoice() {
        // One passing mention of code is not a coding problem.
        let page = normalized("""
        Which statement about a Python function is true?
        A) It must return a value
        B) It may take no arguments
        C) It cannot be nested
        """)
        XCTAssertEqual(QuizKindClassifier.classify(ocr: page), .singleChoice)
    }

    func testACodingQuestionWithLetteredOptionsIsStillAMultipleChoice() {
        // Being *about* code does not make a question open-ended. This one is
        // dense with coding-page landmarks — "time complexity", "space
        // complexity", "return the" — and used to be classified `.code`, which
        // routes it to the Open council: a deep bench plus a refinement pass, to
        // pick one of four letters.
        let page = normalized("""
        What is the time complexity of the function below, which will return the
        merged list? Assume it uses O(1) space complexity for its accumulator.
        A) O(N + M) time, O(1) space
        B) O(N * M) time, O(N) space
        C) O(log N) time, O(1) space
        D) O(N^2) time, O(N) space
        """)
        XCTAssertEqual(QuizKindClassifier.classify(ocr: page), .singleChoice)
        XCTAssertEqual(QuizMode.mode(for: .singleChoice), .choice)
    }

    func testALeetCodeProblemIsStillCodeDespiteItsNumberedExamples() {
        // The other side of the same decision, and the reason the two are
        // separated by label shape rather than by order. `Example 1` / `Example
        // 2` / `Example 3` is a perfectly good ascending *numbered* run; letting
        // it win would tell the council to expect a letter and clear the panel.
        let page = normalized("""
        Given a 0-indexed array nums, return the number of pairs.
        Example 1
        Input nums = [1,2,3]
        Expected output 2
        Example 2
        Input nums = [4,5]
        Expected output 0
        Example 3
        Input nums = []
        Expected output 0
        Constraints: 1 <= nums.length <= 10^5
        """)
        XCTAssertEqual(QuizKindClassifier.classify(ocr: page), .code)
    }

    func testTheFrozenFixtureQuestionClassifiesAsSingleChoice() {
        let ocr = """
        question 2 of 10
        which of the following statements is true
        a all trees are arborescences
        b no arborescence is a tree
        c all arborescences are dags
        d every dag is a tree
        """
        XCTAssertEqual(QuizKindClassifier.classify(ocr: ocr), .singleChoice)
        // And that kind is one unanimity can settle without the arbiter, which is
        // the whole point of getting it right.
        XCTAssertTrue(QuizEnsembleResolver.canPublishWithoutArbiter(kind: .singleChoice))
    }
}
