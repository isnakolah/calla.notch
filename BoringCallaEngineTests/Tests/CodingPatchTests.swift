import CallaContracts
import XCTest
@testable import CallaNotchPresentation

private func patch(_ lines: [(CodingPatchLineKind, String, Int?)],
                   startLine: Int? = nil,
                   notes: [(Int, String)] = []) -> CodingPatch {
    CodingPatch(startLine: startLine,
                lines: lines.map { CodingPatchLine(kind: $0.0, text: $0.1, note: $0.2) },
                notes: notes.map { CodingPatchNote(id: $0.0, text: $0.1) })
}

final class CodingPatchLimitsTests: XCTestCase {
    func testAStepThatChangesNothingIsNotAStep() {
        let all = patch([(.context, "a", nil), (.context, "b", nil)])
        XCTAssertTrue(CodingPatchLimits.problems(with: all).contains(.changesNothing))
        XCTAssertEqual(CodingPatchLimits.problems(with: CodingPatch()), [.empty])
    }

    func testTooMuchContextIsAProblem() {
        let padded = patch([(.context, "1", nil), (.context, "2", nil), (.context, "3", nil),
                            (.context, "4", nil), (.add, "new", nil)])
        XCTAssertTrue(CodingPatchLimits.problems(with: padded).contains(.tooMuchContext))
    }

    func testANoteMustBeAnchoredAndOnAChangedLine() {
        let orphan = patch([(.add, "new", nil)], notes: [(1, "why")])
        XCTAssertTrue(CodingPatchLimits.problems(with: orphan).contains(.noteNotAnchored))

        let onContext = patch([(.context, "old", 1), (.add, "new", nil)], notes: [(1, "why")])
        XCTAssertTrue(CodingPatchLimits.problems(with: onContext).contains(.noteOnUnchangedLine))
    }

    /// Trimming rather than rejecting: a step that is one context line too long
    /// is still the step, and a blank panel mid-interview is the worst outcome
    /// on offer.
    func testNormalisingDropsTheOutermostContextFirst() {
        var lines: [(CodingPatchLineKind, String, Int?)] = [(.context, "top", nil)]
        lines += (0..<11).map { (.add, "add \($0)", nil) }
        lines += [(.context, "bottom", nil)]

        let result = CodingPatchLimits.normalised(patch(lines))
        XCTAssertEqual(result.lines.count, CodingPatchLimits.maximumLines)
        XCTAssertEqual(result.addedLineCount, 11)
        XCTAssertFalse(result.lines.contains { $0.text == "top" })
    }

    func testANoteWhoseTextWasDroppedLeavesNoMarkerBehind() {
        let over = patch([(.add, "a", 1), (.add, "b", 2), (.add, "c", 3)],
                         notes: [(1, "one"), (2, "two"), (3, "three")])
        let result = CodingPatchLimits.normalised(over)
        XCTAssertEqual(result.notes.count, CodingPatchLimits.maximumNotes)
        XCTAssertNil(result.lines.last?.note, "a marker pointing at a dropped note")
        XCTAssertEqual(Set(result.lines.compactMap(\.note)), Set(result.notes.map(\.id)))
    }

    func testLongNotesAreCutRatherThanDropped() {
        let long = String(repeating: "x", count: 200)
        let result = CodingPatchLimits.normalised(patch([(.add, "a", 1)], notes: [(1, long)]))
        XCTAssertEqual(result.notes.first?.text.count, CodingPatchLimits.maximumNoteCharacters)
    }

    /// The pacing budget the claim guard applies to `code` has to reach the
    /// patch too — it is the thing the panel actually draws.
    func testTrimmingToABudgetKeepsTheFirstAddsAndDropsTrailingContext() {
        let big = patch([(.context, "head", nil), (.add, "1", nil), (.add, "2", nil),
                         (.add, "3", nil), (.context, "tail", nil)], startLine: 10)
        let cut = CodingPatchLimits.trimmed(big, toAddedLines: 2)
        XCTAssertEqual(cut.addedLineCount, 2)
        XCTAssertFalse(cut.lines.contains { $0.text == "tail" })
        XCTAssertTrue(cut.lines.contains { $0.text == "head" }, "context that locates the change stays")
    }

    func testTrimmingUnderBudgetChangesNothing() {
        let small = patch([(.add, "1", nil)])
        XCTAssertEqual(CodingPatchLimits.trimmed(small, toAddedLines: 5), small)
    }

    /// What copying a step puts on the pasteboard is the file as the step
    /// leaves it — the removed lines are the point of removing them.
    func testCopyableTextLeavesOutWhatTheStepRemoves() {
        let step = patch([(.context, "keep", nil), (.remove, "gone", nil), (.add, "new", nil)])
        XCTAssertEqual(step.copyableText, "keep\nnew")
    }
}

final class CodingPatchPresentationTests: XCTestCase {
    /// The numbering decision: context and removed lines carry their number in
    /// the file as it stands, because the reader has to find them in their own
    /// editor. Added lines are not in the file yet and carry none.
    func testAddedLinesHaveNoFileNumber() {
        let display = CodingPatchPresentation.display(for: patch([
            (.context, "a", nil), (.add, "b", nil), (.remove, "c", nil), (.context, "d", nil)
        ], startLine: 116))

        XCTAssertEqual(display.rows.map(\.number), [116, nil, 117, 118])
        XCTAssertEqual(display.linesAbove, 115)
        XCTAssertTrue(display.hasChanges)
        XCTAssertEqual(display.addedCount, 1)
        XCTAssertEqual(display.removedCount, 1)
    }

    func testAnUnanchoredPatchNumbersNothing() {
        let display = CodingPatchPresentation.display(for: patch([(.context, "a", nil), (.add, "b", nil)]))
        XCTAssertEqual(display.rows.map(\.number), [nil, nil])
        XCTAssertNil(display.linesAbove)
    }

    func testTheAnchorSuppliesTheStartLineWhenThePatchDoesNot() {
        let display = CodingPatchPresentation.display(
            for: patch([(.context, "a", nil), (.add, "b", nil)]),
            anchor: CodingFileAnchor(path: "engine/sheet.py", symbol: "set", line: 42))
        XCTAssertEqual(display.rows.first?.number, 42)
    }

    /// A move published before patches existed. Everything is context, because
    /// nothing is known about what is new — and the view must not dim it all.
    func testLegacyCodeIsAllContextAndClaimsNoChanges() {
        let display = CodingPatchPresentation.display(forPlainCode: "one\ntwo\nthree")
        XCTAssertEqual(display.rows.count, 3)
        XCTAssertTrue(display.rows.allSatisfy { $0.kind == .context })
        XCTAssertFalse(display.hasChanges)
    }

    func testAMoveWithNeitherPatchNorCodeDrawsNothing() {
        let move = CodingMove(ordinal: 1, sourceRevision: "r", kind: .explanation, say: "words only")
        XCTAssertNil(CodingPatchPresentation.display(for: move))
        XCTAssertNil(CodingPatchPresentation.copyableText(for: move))
    }

    func testAPatchWinsOverTheBlobWhenBothArePresent() {
        let move = CodingMove(ordinal: 1, sourceRevision: "r", kind: .edit,
                              code: "stale", patch: patch([(.add, "fresh", nil)]))
        XCTAssertEqual(CodingPatchPresentation.display(for: move)?.rows.first?.text, "fresh")
        XCTAssertEqual(CodingPatchPresentation.copyableText(for: move), "fresh")
    }

    func testPlacementTrimsToWhatIsKnown() {
        XCTAssertNil(CodingPatchPresentation.placement(for: nil))
        XCTAssertEqual(
            CodingPatchPresentation.placement(for: CodingFileAnchor(path: "a/b/sheet.py"), short: true),
            "sheet.py")
        XCTAssertEqual(
            CodingPatchPresentation.placement(for: CodingFileAnchor(path: "a/b/sheet.py", symbol: "set", line: 42)),
            "a/b/sheet.py · set · 42")
    }

    /// Notes survive the trip from contract to display, and stay attached to
    /// the line they were about.
    func testNotesStayAnchoredThroughLayout() {
        let display = CodingPatchPresentation.display(for: patch(
            [(.context, "a", nil), (.add, "b", 1)], startLine: 5, notes: [(1, "why b")]))
        XCTAssertEqual(display.notes.map(\.text), ["why b"])
        XCTAssertEqual(display.rows.first(where: { $0.note != nil })?.text, "b")
    }
}
