import Foundation
import Testing
import CallaContracts
@testable import IntelligenceCore

/// The pack tells the model the published facts; `WaveSpecConformance` checks
/// them against the installed libraries. These two have to be the same facts.
///
/// Nothing else catches a drift between them: a wrong expected value in the pack
/// is prose the model believes, and the probe would happily report conformance
/// against the right table while the model reads the wrong one.
struct WavePackSpecTests {
    private func packFile(_ name: String) throws -> String {
        let root = try #require(PromptPack.bundledRoot, "prompt resources are not bundled")
        let url = root.appendingPathComponent("coding/wave-v1/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func everyPublishedParseExampleAppearsInTheSpecFile() throws {
        let spec = try packFile("spec.md")
        for expectation in WaveSpecConformance.parseExamples {
            #expect(spec.contains(expectation.source),
                    "spec.md never shows \(expectation.source)")
            switch expectation.expect {
            case let .value(text):
                #expect(spec.contains(text), "spec.md never shows the result \(text)")
            case let .raises(error):
                #expect(spec.contains(error), "spec.md never names \(error)")
            }
        }
    }

    @Test func theRangeAndIndexSurfacesAreDocumented() throws {
        let spec = try packFile("spec.md")
        let baseline = try packFile("part1-baseline.md")
        for member in ["Range.parse", "contains", "height", "width", "indices", "row(i)"] {
            #expect(spec.contains(member), "spec.md never mentions \(member)")
        }
        for member in ["Index.parse", "row_label", "column_label", "get_formatted",
                       "get_raw", "set_format"] {
            #expect(baseline.contains(member), "part1-baseline.md never mentions \(member)")
        }
    }

    @Test func theSpecKeepsTheFactsThatAreEasiestToGetWrong() throws {
        let spec = try packFile("spec.md")
        // Ranges are inclusive, and the row-major order of `indices` is what
        // sum's expansion depends on.
        #expect(spec.contains("inclusive"))
        #expect(spec.contains("A1, B1, A2, B2, A3, B3"))
        // Variable arity, stated as a warning rather than left to the example.
        #expect(spec.contains("not always three elements"))
        // Case-insensitive function names, and the operator-spacing conflict.
        #expect(spec.lowercased().contains("case-insensitive"))
        #expect(spec.contains("sqrt((1+1))"))
        // Circular references are a requirement, not a nicety.
        #expect(spec.contains("circular"))
    }

    @Test func theBriefCarriesTheInterviewersOwnRanking() throws {
        let brief = try packFile("brief.md")
        #expect(brief.contains("High quality design"))
        #expect(brief.contains("User-friendly details"))
        #expect(brief.contains("Speed"))
        // The things worth not spending two hours on.
        #expect(brief.contains("Not graded"))
        #expect(brief.contains("docstrings"))
    }

    @Test func theFlowStatesEveryLadderStepsAcceptance() throws {
        let flow = try packFile("flow.md")
        for step in WaveInterviewState.ladder {
            #expect(flow.lowercased().contains(step.id.lowercased()),
                    "flow.md never names the \(step.id) step")
        }
        // The checks the state carries are the checks the flow prints.
        #expect(flow.contains("neither hang nor crash"))
        #expect(flow.contains("case-insensitive"))
        #expect(flow.contains("not always three elements"))
    }

    @Test func partOneBaselineWarnsThatPrintIsSwallowed() throws {
        let baseline = try packFile("part1-baseline.md")
        // A debugging move that reaches for print produces nothing under the
        // curses UI, and costs a minute of a two-hour interview to discover.
        #expect(baseline.contains("spreadsheet.log"))
        #expect(baseline.contains("print()"))
    }

    /// An explanation that does not say where the code lives is half an
    /// answer — and one that spells out the path and line in the sentence is
    /// clutter, because the panel already shows both.
    @Test func explanationsAreAnchoredButNotVerbose() throws {
        let root = try #require(PromptPack.bundledRoot)
        let agents = try String(contentsOf: root.appendingPathComponent("coding/agents.md"),
                                encoding: .utf8)
        let lane = try String(contentsOf: root.appendingPathComponent("coding/lanes/move.md"),
                              encoding: .utf8)

        // Anchored, and not only for edits.
        #expect(agents.contains("Every explanation"))
        #expect(lane.contains("Always set `file`"))
        #expect(lane.contains("as much as for an edit"))

        // The symbol in the sentence, the path and line in the anchor.
        #expect(lane.contains("symbol only"))
        #expect(lane.contains("Never spell out the path or the line there"))
        #expect(agents.contains("never the path or the line"))

        // A wrong anchor is worse than none.
        #expect(lane.contains("Never invent a path"))
        #expect(agents.contains("rather than guessing"))
    }

    @Test func thePackDoesNotShipAnyExerciseSolution() throws {
        // The brief forbids retrieving completed part 2 solutions; the pack
        // itself must not be the thing that leaks one.
        for name in ["spec.md", "flow.md", "brief.md", "part1-baseline.md",
                     "codebase-and-interfaces.md", "intents.md"] {
            let text = try packFile(name)
            #expect(!text.contains("def evaluate"), "\(name) ships an implementation")
            #expect(!text.contains("```python"), "\(name) ships a python block")
        }
    }
}
