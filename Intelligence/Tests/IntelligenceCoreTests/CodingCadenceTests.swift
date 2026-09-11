import CallaContracts
import XCTest
@testable import IntelligenceCore

/// Pacing is the difference between a copilot that helps and one that gets the
/// candidate caught. These pin the rules that keep a move candidate-sized.
final class CodingCadenceTests: XCTestCase {

    private func facts(phase: CodingPhase, code: Bool = false, passing: Bool = false,
                       failing: Bool = false, pending: Bool = false,
                       elapsed: Double? = nil) -> CodingCadenceFacts {
        CodingCadenceFacts(phase: phase, hasCode: code, hasPassingRun: passing,
                           hasFailingRun: failing, hasPendingRun: pending,
                           elapsedFraction: elapsed)
    }

    /// The rule that stops a finished function appearing at once.
    func testAnEmptyFileGetsASkeletonBeforeAnyBody() {
        let allowed = CodingCadence.allowed(facts(phase: .implementing, code: false))
        XCTAssertEqual(allowed.first, .skeleton)
        XCTAssertFalse(allowed.contains(.fillOne))
    }

    func testOnceThereIsCodeTheNextStepFillsOnePart() {
        let allowed = CodingCadence.allowed(facts(phase: .implementing, code: true))
        XCTAssertEqual(allowed.first, .fillOne)
        XCTAssertFalse(allowed.contains(.skeleton))
    }

    /// Rewriting for speed before it is correct is the classic interview
    /// mistake, so the ladder must make it unreachable.
    func testOptimisingIsUnreachableUntilSomethingPasses() {
        XCTAssertFalse(CodingCadence.permits(.optimise, facts(phase: .verifying, passing: false)))
        XCTAssertTrue(CodingCadence.permits(.optimise, facts(phase: .verifying, code: true, passing: true)))
    }

    func testAFailingCheckOutranksTheLadder() {
        let allowed = CodingCadence.allowed(facts(phase: .verifying, passing: true, failing: true))
        XCTAssertEqual(allowed.first, .fillOne)
        XCTAssertFalse(allowed.contains(.optimise))
    }

    func testVerifyNeedsSomethingStagedToRun() {
        XCTAssertFalse(CodingCadence.permits(.verify, facts(phase: .implementing, code: true, pending: false)))
        XCTAssertTrue(CodingCadence.permits(.verify, facts(phase: .implementing, code: true, pending: true)))
    }

    func testWordsOnlyIncrementsCarryNoCodeBudget() {
        for increment in [CodingIncrement.clarify, .sketch, .verify, .narrate] {
            XCTAssertEqual(increment.maximumAddedLines, 0, "\(increment)")
            XCTAssertFalse(increment.allowsCode, "\(increment)")
        }
    }

    // MARK: - Trimming

    private func diff(addedLines: Int, hunks: Int = 1) -> String {
        var out = ["diff --git a/s.py b/s.py", "--- a/s.py", "+++ b/s.py"]
        let per = max(1, addedLines / hunks)
        for hunk in 0 ..< hunks {
            out.append("@@ -\(hunk * 10),1 +\(hunk * 10),\(per) @@")
            out.append(" context")
            for line in 0 ..< per { out.append("+    line\(hunk)_\(line)") }
        }
        return out.joined(separator: "\n")
    }

    func testASolutionSizedDiffIsCutBackToAHunk() {
        let whole = diff(addedLines: 40, hunks: 4)
        XCTAssertEqual(CodingCadence.addedLines(in: whole), 40)
        let trimmed = CodingCadence.trim(diff: whole, to: .fillOne)
        XCTAssertTrue(trimmed.withheld)
        XCTAssertLessThanOrEqual(CodingCadence.addedLines(in: trimmed.diff),
                                 CodingIncrement.fillOne.maximumAddedLines)
        // Still a usable patch, not a severed one.
        XCTAssertTrue(trimmed.diff.contains("@@"))
        XCTAssertTrue(trimmed.diff.contains("+++ b/s.py"))
    }

    func testADiffInsideTheBudgetIsUntouched() {
        let small = diff(addedLines: 5)
        let trimmed = CodingCadence.trim(diff: small, to: .fillOne)
        XCTAssertFalse(trimmed.withheld)
        XCTAssertEqual(trimmed.diff, small)
    }

    func testTheFileHeaderIsNotCountedAsAnAddedLine() {
        XCTAssertEqual(CodingCadence.addedLines(in: "+++ b/x\n+one\n+two"), 2)
    }
}
