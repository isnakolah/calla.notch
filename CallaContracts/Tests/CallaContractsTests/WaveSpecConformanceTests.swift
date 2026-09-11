import Foundation
import Testing
@testable import CallaContracts

/// The probe is generated from the same table the prompt pack states, so these
/// hold the generator to the published spec rather than to itself.
struct WaveSpecConformanceTests {
    @Test func publishedParseExamplesAreAllPresent() {
        // Eighteen in the published document; a dropped row is a fact the model
        // would be told and the probe would never check.
        #expect(WaveSpecConformance.parseExamples.count == 18)
        let sources = Set(WaveSpecConformance.parseExamples.map(\.source))
        #expect(sources.count == 18)
    }

    @Test func loadBearingExamplesKeepTheirPublishedShape() {
        func expectation(_ id: String) -> WaveSpecConformance.Expectation? {
            WaveSpecConformance.all.first { $0.id == id }
        }
        // A quoted literal comes back unquoted.
        #expect(expectation("parse.quotedLiteral")?.expect == .value("'string with spaces'"))
        // The sign stays inside the leaf; there is no unary node.
        #expect(expectation("parse.negativeLeft")?.expect == .value("['+', '-1', '2']"))
        // Subtraction nests on the left.
        #expect(expectation("parse.leftAssociative")?.expect
                == .value("['-', ['-', 'A1', 'A2'], 'A3']"))
        // Multiplication binds tighter, and the tree already says so.
        #expect(expectation("parse.precedence")?.expect == .value("['+', 'A1', ['*', 'A2', 'A3']]"))
        // Four elements. Anything unpacking op/left/right breaks here.
        #expect(expectation("parse.sumArity")?.expect == .value("['sum', 'A1:A2', 'A3', 'A4']"))
        // Ranges are inclusive and row-major.
        #expect(expectation("range.indicesRowMajor")?.expect
                == .value("['A1', 'B1', 'A2', 'B2', 'A3', 'B3']"))
        // Reversed endpoints normalise.
        #expect(expectation("range.reorderedFirst")?.expect == .value("'A1'"))
        // Index.parse is case-insensitive and zero-indexed.
        #expect(expectation("index.parseCaseInsensitive")?.expect == .value("(9, 27)"))
    }

    @Test func everyDocumentedFailureNamesItsException() {
        let raising = WaveSpecConformance.all.filter {
            if case .raises = $0.expect { return true }
            return false
        }
        #expect(raising.count == 5)
        #expect(raising.filter { $0.expect == .raises("ParseError") }.count == 3)
        #expect(raising.filter { $0.expect == .raises("ValueError") }.count == 2)
    }

    @Test func probeScriptCoversEveryExpectation() {
        let script = WaveSpecConformance.probeScript()
        for expectation in WaveSpecConformance.all {
            #expect(script.contains("\"\(expectation.id)\""),
                    "probe omits \(expectation.id)")
            #expect(script.contains(expectation.source), "probe omits \(expectation.source)")
        }
        // Isolated per case: one raising expression must not end the run.
        #expect(script.contains("except Exception as error:"))
    }

    @Test func matchingProbeOutputReportsNoDifference() throws {
        var cases: [String: Any] = [:]
        for expectation in WaveSpecConformance.all {
            switch expectation.expect {
            case let .value(text): cases[expectation.id] = ["value": text]
            case let .raises(error): cases[expectation.id] = ["raised": error]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["cases": cases])
        let rows = WaveSpecConformance.rows(fromProbeJSON: data)
        #expect(rows.count == WaveSpecConformance.all.count)
        #expect(WaveSpecConformance.differences(rows).isEmpty)
        #expect(WaveSpecConformance.report(rows: rows)
            .contains("All \(rows.count) documented facts that could be checked hold"))
    }

    /// Before the part 2 bundle arrives `sheet.formula` does not exist. Its
    /// eighteen facts are unchecked, not eighteen departures from the spec —
    /// and the report has to lead with the reason rather than printing a wall
    /// of NameError above it.
    @Test func aMissingModuleIsReportedAsMissingRatherThanAsEighteenFailures() throws {
        var cases: [String: Any] = [:]
        for expectation in WaveSpecConformance.all {
            switch expectation.group {
            case "sheet.formula":
                cases[expectation.id] = ["raised": "NameError"]
            default:
                switch expectation.expect {
                case let .value(text): cases[expectation.id] = ["value": text]
                case let .raises(error): cases[expectation.id] = ["raised": error]
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "cases": cases,
            "import_formula": "ModuleNotFoundError: No module named 'sheet.formula'",
        ])
        let outcome = WaveSpecConformance.result(fromProbeJSON: data)
        #expect(outcome.missingModules["sheet.formula"] != nil)
        // Not differences: they were never checked.
        #expect(WaveSpecConformance.differences(outcome.rows).isEmpty)
        let report = WaveSpecConformance.report(outcome)
        #expect(report.contains("`sheet.formula` is not installed."))
        #expect(report.contains("18 documented fact(s) could not be checked"))
        #expect(report.contains("sheet.formula: not installed"))
        // The libraries that are installed still get a real verdict.
        #expect(report.contains("sheet.models.Range: 11/11 as documented"))
        #expect(report.contains("sheet.models.Index: 12/12 as documented"))
        // And no wall of NameError rows.
        #expect(!report.contains("raised NameError"))
    }

    /// A module that imported fine still reports real departures.
    @Test func aMissingModuleDoesNotMaskADifferenceElsewhere() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "cases": ["range.indicesRowMajor": ["value": "['A1', 'A2', 'A3', 'B1', 'B2', 'B3']"]],
            "import_formula": "ModuleNotFoundError: No module named 'sheet.formula'",
        ])
        let outcome = WaveSpecConformance.result(fromProbeJSON: data)
        let bad = WaveSpecConformance.differences(outcome.rows)
        #expect(bad.contains { $0.expectation.id == "range.indicesRowMajor" })
        #expect(!bad.contains { $0.expectation.group == "sheet.formula" })
    }

    @Test func aDivergentLibraryIsReportedAsADifference() throws {
        // The shipped parser keeps the quotes: exactly the kind of departure
        // preparation exists to find.
        let data = try JSONSerialization.data(withJSONObject: [
            "cases": ["parse.quotedLiteral": ["value": "'\"string with spaces\"'"]]
        ])
        let rows = WaveSpecConformance.rows(fromProbeJSON: data)
        let quoted = try #require(rows.first { $0.expectation.id == "parse.quotedLiteral" })
        #expect(!quoted.matches)
        let report = WaveSpecConformance.report(rows: rows)
        #expect(report.contains("do **not** hold"))
        #expect(report.contains("parse('\"string with spaces\"')"))
    }

    @Test func aCaseTheProbeNeverReportedIsNotAPass() throws {
        // A probe that could not import the library reports nothing. That has
        // to read as unconfirmed, never as conformance.
        let data = try JSONSerialization.data(withJSONObject: ["cases": [String: Any]()])
        let rows = WaveSpecConformance.rows(fromProbeJSON: data)
        #expect(WaveSpecConformance.differences(rows).count == rows.count)
        #expect(rows.allSatisfy { $0.actual == "not reported" })
    }

    @Test func wrongExceptionTypeIsADifference() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "cases": ["parse.empty": ["raised": "ValueError"]]
        ])
        let rows = WaveSpecConformance.rows(fromProbeJSON: data)
        let empty = try #require(rows.first { $0.expectation.id == "parse.empty" })
        #expect(!empty.matches)
        #expect(empty.actual == "raised ValueError")
    }
}

/// The published task order, and what each step has to handle.
struct WaveLadderTests {
    @Test func ladderFollowsThePublishedOrder() {
        #expect(WaveInterviewState.ladder.map(\.id)
                == ["references", "literals", "numeric", "sum", "dates", "sqrt"])
    }

    @Test func everyStepStatesItsAcceptance() {
        let state = WaveInterviewState(sessionID: "code-1:1", sourceRevision: "abc")
        #expect(state.tasks.allSatisfy { !$0.checks.isEmpty })
        #expect(state.currentTaskID == "references")
        // The spec names the cycle case explicitly; it is a check, not a footnote.
        let references = state.tasks.first { $0.id == "references" }
        #expect(references?.checks.contains { $0.contains("hangs") } == true)
        // sum's variable arity and the no-deduplication rule are both stated.
        let sum = state.tasks.first { $0.id == "sum" }
        #expect(sum?.checks.contains { $0.contains("deduplicated") } == true)
    }

    @Test func aTaskSnapshotWithoutChecksStillDecodes() throws {
        // Sessions sealed by an earlier build have no `checks` key.
        let json = Data("""
        {"id":"sum","title":"sum","evidence":[],"completed":false}
        """.utf8)
        let task = try JSONDecoder().decode(WaveTaskState.self, from: json)
        #expect(task.id == "sum")
        #expect(task.checks.isEmpty)
    }
}
