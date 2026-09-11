import CallaContracts
import Foundation
import Testing
@testable import CallaNotchPresentation

/// Sentences taken verbatim from the live panel.
struct CodingProseSpanTests {
    private func code(_ sentence: String) -> [String] {
        CodingProseSpan.spans(in: sentence).filter(\.isCode).map(\.text)
    }

    private func roundTrips(_ sentence: String) -> Bool {
        CodingProseSpan.spans(in: sentence).map(\.text).joined() == sentence
    }

    @Test func theHeadlineFromTheScreenshotSplitsIntoItsParts() {
        let sentence = "Raw text is stored verbatim in self._raw: '=A1' at B1, '12' at A1."
        #expect(code(sentence) == ["self._raw", "'=A1'", "B1", "'12'", "A1"])
        // Nothing is dropped or duplicated: the words still read as the sentence.
        #expect(roundTrips(sentence))
    }

    @Test func callsAndFormatsAreCode() {
        let sentence = "self._evaluate(B1) follows the reference to A1, returning value 12."
        #expect(code(sentence) == ["self._evaluate(B1)", "A1", "12"])
        let second = "render() in get_formatted formats 12 as '12.00' using B1's format."
        #expect(code(second) == ["render()", "get_formatted", "12", "'12.00'", "B1"])
        #expect(roundTrips(sentence) && roundTrips(second))
    }

    @Test func literalsDatesAndScientificNumbers() {
        #expect(code("Literals like 6.02e23 or 2018-01-01 are leaves.")
                == ["6.02e23", "2018-01-01"])
        // The date is taken whole rather than as a year minus two numbers.
        let spans = CodingProseSpan.spans(in: "2018-01-01")
        #expect(spans.count == 1)
        #expect(spans.first?.role == .number)
    }

    @Test func rangesAndTheLibrarySurface() {
        #expect(code("Expand A1:B3 with Range.indices before summing.")
                == ["A1:B3", "Range.indices"])
        #expect(code("sum(A1:B2, C3) has a variable tail.") == ["sum(A1:B2, C3)"])
    }

    @Test func ordinaryProseIsLeftAlone() {
        // The failure worth avoiding is highlighting half a sentence: an
        // English word is never a symbol, however technical it sounds.
        for sentence in [
            "Talk through the example before writing anything.",
            "Start with the simplest correct approach and say why.",
            "Ask whether blanks inside a range should be skipped.",
        ] {
            #expect(code(sentence).isEmpty, "highlighted prose in: \(sentence)")
            #expect(!CodingProseSpan.containsCode(sentence))
        }
    }

    @Test func punctuationStaysOutsideTheSpan() {
        // "A1." must not carry the full stop into the code face.
        let spans = CodingProseSpan.spans(in: "Follow the reference to A1.")
        #expect(spans.last?.text == ".")
        #expect(spans.last?.role == .text)
        #expect(spans.first(where: \.isCode)?.text == "A1")
    }

    @Test func rolesDriveTheColour() {
        func role(_ s: String) -> CodingProseSpan.Role? {
            CodingProseSpan.spans(in: s).first { $0.isCode }?.role
        }
        #expect(role("value is '12.00' here") == .string)
        #expect(role("value is 12 here") == .number)
        #expect(role("call render() here") == .identifier)
        #expect(role("cell B1 here") == .identifier)
    }

    @Test func everySentenceRoundTripsExactly() {
        // Whatever the rule does, the reader must still get their sentence.
        for sentence in [
            "", "A1", "no code at all", "'unterminated", "a(b)c", "12.00.34",
            "self._raw: '=A1' at B1, '12' at A1.",
            "Nested sqrt((1+1)) evaluates its operand first.",
        ] {
            #expect(roundTrips(sentence), "lost text in: \(sentence)")
        }
    }
}

/// The panel's reasoning box, and where a words-only step says it lands.
@Suite
struct CodingStepPresentationTests {

    // MARK: - Reasoning as a list

    @Test func theScreenshotsReasoningBecomesTwoPoints() {
        let why = """
        For reference nodes, recursively evaluate the target cell while maintaining a visited set to detect cycles
        Return the resolved value or format it using the existing format pipeline
        """
        let lines = CodingPatchPresentation.reasoningLines(why)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("For reference nodes"))
        #expect(lines[1].hasPrefix("Return the resolved value"))
    }

    /// One point is not a list, and a coder's paragraph of justification is not
    /// one either — both stay prose.
    @Test func aSingleParagraphStaysOneBlock() {
        let why = "Keep the interface simple and verify each slice before expanding it."
        #expect(CodingPatchPresentation.reasoningLines(why) == [why])
    }

    @Test func aModelsOwnBulletsAreNotDrawnTwice() {
        let why = "- Parse the formula first\n* Then resolve references\n• Finally format\n"
        #expect(CodingPatchPresentation.reasoningLines(why)
            == ["Parse the formula first", "Then resolve references", "Finally format"])
    }

    @Test func blankLinesAndPaddingDoNotBecomeEmptyBullets() {
        #expect(CodingPatchPresentation.reasoningLines("\n  first  \n\n\n  second\n  ")
            == ["first", "second"])
        #expect(CodingPatchPresentation.reasoningLines("").isEmpty)
        #expect(CodingPatchPresentation.reasoningLines("   \n  ").isEmpty)
    }

    /// A dotted path must survive: splitting on sentence boundaries would cut
    /// `sheet.formula.parse` in half.
    @Test func dottedPathsAndDatesSurviveIntact() {
        let why = "Call sheet.formula.parse on the raw text. It returns an AST node."
        #expect(CodingPatchPresentation.reasoningLines(why) == [why])
        #expect(CodingPatchPresentation.reasoningLines("Dates like 2018-01-01 parse as literals")
            == ["Dates like 2018-01-01 parse as literals"])
    }

    // MARK: - Where the step lands

    @Test func placementNamesTheFileAndTheSymbol() {
        let anchor = CodingFileAnchor(path: "sheet/formula.py", symbol: "_evaluate", line: 42)
        #expect(CodingPatchPresentation.placement(for: anchor, short: true)
            == "formula.py · _evaluate · 42")
        #expect(CodingPatchPresentation.placement(for: anchor)
            == "sheet/formula.py · _evaluate · 42")
        #expect(CodingPatchPresentation.placement(for: CodingFileAnchor(path: "main.py"),
                                                  short: true) == "main.py")
        #expect(CodingPatchPresentation.placement(for: nil) == nil)
    }
}
