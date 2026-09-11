import Foundation

/// Every fact the published Wave spec states about the supplied libraries, and
/// the probe that checks the installed ones actually behave that way.
///
/// The spec is a fixed document, so these are assertions rather than guesses.
/// What preparation is for is finding where the shipped library departs from
/// its own documentation — a difference found on Sunday is a question for the
/// interviewer, and the same difference found at 12:40 on Monday is a bug hunt
/// with someone watching.
///
/// The expectations live here, next to the wire contracts, rather than inside
/// the engine's probe string: the prompt pack tells the model these facts, the
/// probe checks them, and a test holds the two to the same table.
public enum WaveSpecConformance {
    /// What a probed expression should produce.
    public enum Outcome: Equatable, Sendable {
        /// `repr()` of the value, or `str()` where the published example is a
        /// string rather than a repr.
        case value(String)
        /// The exception type name the spec says is raised.
        case raises(String)
    }

    public struct Expectation: Equatable, Sendable, Identifiable {
        /// Stable key, so a report row can be matched across runs.
        public let id: String
        /// The Python expression, evaluated as written.
        public let source: String
        public let expect: Outcome
        /// Which library the fact belongs to, for the report's sections.
        public let group: String

        public init(id: String, source: String, expect: Outcome, group: String) {
            self.id = id
            self.source = source
            self.expect = expect
            self.group = group
        }
    }

    private static func value(_ id: String, _ source: String, _ expected: String,
                              group: String) -> Expectation {
        Expectation(id: id, source: source, expect: .value(expected), group: group)
    }

    private static func raises(_ id: String, _ source: String, _ error: String,
                               group: String) -> Expectation {
        Expectation(id: id, source: source, expect: .raises(error), group: group)
    }

    // MARK: - sheet.formula

    /// The eighteen published `parse` examples, verbatim.
    ///
    /// `parse` takes the expression without its leading `=`, returns a string
    /// for a reference or literal and a list for an operator or call. Note the
    /// five that are easy to get wrong: a quoted literal comes back unquoted, a
    /// negative number stays inside its leaf, subtraction nests on the left,
    /// `*` already binds tighter than `+` in the tree, and a call result is not
    /// always three elements.
    public static let parseExamples: [Expectation] = [
        value("parse.reference", "parse('A1')", "'A1'", group: "sheet.formula"),
        value("parse.date", "parse('2018-01-01')", "'2018-01-01'", group: "sheet.formula"),
        value("parse.scientific", "parse('6.02e23')", "'6.02e23'", group: "sheet.formula"),
        value("parse.bareLiteral", "parse('miscellaneousliteral')",
              "'miscellaneousliteral'", group: "sheet.formula"),
        value("parse.quotedLiteral", "parse('\"string with spaces\"')",
              "'string with spaces'", group: "sheet.formula"),
        value("parse.add", "parse('A1 + A2')", "['+', 'A1', 'A2']", group: "sheet.formula"),
        value("parse.negativeLeft", "parse('-1 + 2')", "['+', '-1', '2']", group: "sheet.formula"),
        value("parse.negativeRight", "parse('2 + -1')", "['+', '2', '-1']", group: "sheet.formula"),
        value("parse.leftAssociative", "parse('A1 - A2 - A3')",
              "['-', ['-', 'A1', 'A2'], 'A3']", group: "sheet.formula"),
        value("parse.parenthesised", "parse('A1 - (A2 - A3)')",
              "['-', 'A1', ['-', 'A2', 'A3']]", group: "sheet.formula"),
        value("parse.precedence", "parse('A1 + A2 * A3')",
              "['+', 'A1', ['*', 'A2', 'A3']]", group: "sheet.formula"),
        value("parse.sumRange", "parse('sum(A1:A2)')", "['sum', 'A1:A2']", group: "sheet.formula"),
        value("parse.sumArity", "parse('sum(A1:A2, A3, A4)')",
              "['sum', 'A1:A2', 'A3', 'A4']", group: "sheet.formula"),
        value("parse.nestedCall", "parse('sqrt((1+1))')",
              "['sqrt', ['+', '1', '1']]", group: "sheet.formula"),
        value("parse.callInOperand", "parse('A1 + sqrt(A2 + A3)')",
              "['+', 'A1', ['sqrt', ['+', 'A2', 'A3']]]", group: "sheet.formula"),
        raises("parse.invalidCall", "parse('a1:b1(1, 2, 3)')", "ParseError", group: "sheet.formula"),
        raises("parse.trailingOperator", "parse('1 + ')", "ParseError", group: "sheet.formula"),
        raises("parse.empty", "parse('')", "ParseError", group: "sheet.formula"),
    ]

    // MARK: - sheet.models.Range

    /// Checked through `str()` wherever the published example prints an `Index`,
    /// because that example shows a dataclass repr and a repr is formatting the
    /// library is free to change. `str(Index)` is documented behaviour.
    public static let rangeExamples: [Expectation] = [
        value("range.str", "str(Range(Index.parse('A1'), Index.parse('B2')))",
              "'A1:B2'", group: "sheet.models.Range"),
        value("range.width", "Range.parse('A1:B3').width", "2", group: "sheet.models.Range"),
        value("range.height", "Range.parse('A1:B3').height", "3", group: "sheet.models.Range"),
        value("range.indicesRowMajor", "[str(i) for i in Range.parse('A1:B3').indices]",
              "['A1', 'B1', 'A2', 'B2', 'A3', 'B3']", group: "sheet.models.Range"),
        value("range.row", "[str(i) for i in Range.parse('A1:C3').row(1)]",
              "['A2', 'B2', 'C2']", group: "sheet.models.Range"),
        value("range.containsLast", "Range.parse('B2:C3').contains(Index.parse('C3'))",
              "True", group: "sheet.models.Range"),
        value("range.containsBelow", "Range.parse('B2:C3').contains(Index.parse('C4'))",
              "False", group: "sheet.models.Range"),
        value("range.containsRight", "Range.parse('B2:C3').contains(Index.parse('D3'))",
              "False", group: "sheet.models.Range"),
        value("range.reorderedFirst", "str(Range(Index(1, 0), Index(0, 1)).first)",
              "'A1'", group: "sheet.models.Range"),
        value("range.reorderedLast", "str(Range(Index(1, 0), Index(0, 1)).last)",
              "'B2'", group: "sheet.models.Range"),
        raises("range.invalid", "Range.parse('not a range')", "ValueError",
               group: "sheet.models.Range"),
    ]

    // MARK: - sheet.models.Index

    public static let indexExamples: [Expectation] = [
        value("index.parseOrigin", "(Index.parse('A1').row, Index.parse('A1').col)",
              "(0, 0)", group: "sheet.models.Index"),
        value("index.parseCaseInsensitive", "(Index.parse('bb10').row, Index.parse('bb10').col)",
              "(9, 27)", group: "sheet.models.Index"),
        value("index.str", "str(Index(9, 27))", "'BB10'", group: "sheet.models.Index"),
        value("index.rowLabel", "Index(1, 1).row_label", "'2'", group: "sheet.models.Index"),
        value("index.columnSingle", "Index(57, 1).column_label", "'B'", group: "sheet.models.Index"),
        value("index.columnDouble", "Index(57, 27).column_label", "'BB'", group: "sheet.models.Index"),
        value("index.columnTriple", "Index(57, 53).column_label", "'BBB'", group: "sheet.models.Index"),
        value("index.addIndex", "str(Index(0, 0) + Index(2, 3))", "'D3'", group: "sheet.models.Index"),
        value("index.addTuple", "str(Index(0, 0) + (2, 3))", "'D3'", group: "sheet.models.Index"),
        value("index.max", "str(Index(1, 2).max((2, 1)))", "'C3'", group: "sheet.models.Index"),
        value("index.min", "str(Index(1, 2).min((2, 1)))", "'B2'", group: "sheet.models.Index"),
        raises("index.invalid", "Index.parse('not an index')", "ValueError",
               group: "sheet.models.Index"),
    ]

    /// One probe over every documented fact, in reading order.
    public static var all: [Expectation] { parseExamples + rangeExamples + indexExamples }

    /// Groups in the order the report prints them.
    public static var groups: [String] {
        var seen = Set<String>()
        return all.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    // MARK: - The probe

    /// The Python the shadow runner executes.
    ///
    /// Generated from the table above rather than written alongside it, so the
    /// probe cannot drift from the expectations the pack states. Each case is
    /// isolated: one expression that raises must not stop the rest, because a
    /// library missing one method is exactly the situation the report is for.
    public static func probeScript() -> String {
        var lines = [
            "import json, sys",
            "results = {\"python\": sys.version, \"cases\": {}}",
            "try:",
            "    from sheet.formula import parse, ParseError",
            "except Exception as error:",
            "    results[\"import_formula\"] = type(error).__name__ + \": \" + str(error)",
            "try:",
            "    from sheet.models import Index, Range",
            "except Exception as error:",
            "    results[\"import_models\"] = type(error).__name__ + \": \" + str(error)",
            // Bounded so one pathological repr cannot spend the runner's whole
            // output budget and truncate the JSON for every case after it. Every
            // documented value is well under this, so a bound cannot turn a
            // match into a difference.
            "LIMIT = 400",
            "def probe(key, thunk):",
            "    try:",
            "        results[\"cases\"][key] = {\"value\": repr(thunk())[:LIMIT]}",
            "    except Exception as error:",
            "        results[\"cases\"][key] = {\"raised\": type(error).__name__,",
            "                                  \"detail\": str(error)[:LIMIT]}",
        ]
        for expectation in all {
            lines.append("probe(\(quoted(expectation.id)), lambda: \(expectation.source))")
        }
        lines.append("print(json.dumps(results, indent=2))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A Python string literal for a value this file controls.
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - The report

    public struct Row: Equatable, Sendable {
        public let expectation: Expectation
        /// What the installed library actually produced: a repr, or the name of
        /// the exception it raised.
        public let actual: String
        public let matches: Bool
        /// Whether the module this fact belongs to could not be imported at all.
        ///
        /// Distinct from a difference on purpose. Before the part 2 bundle
        /// arrives `sheet.formula` does not exist, and reporting its eighteen
        /// facts as eighteen departures from the spec is a wall of red that says
        /// nothing — the one useful sentence is that the library is not
        /// installed yet.
        public var unavailable = false
    }

    /// One probe run, with the module-level failures that explain it.
    public struct Result: Equatable, Sendable {
        public var rows: [Row]
        /// Module name to the import error, for whatever failed to import.
        public var missingModules: [String: String]
    }

    /// Which JSON key reports which module's import.
    private static let importKeys = ["import_formula": "sheet.formula",
                                     "import_models": "sheet.models"]

    /// Compares one probe run against the table.
    ///
    /// A case the probe never reported is a difference, not a pass — a probe
    /// that failed to import the library must not read as conformance.
    public static func result(fromProbeJSON data: Data) -> Result {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let cases = object?["cases"] as? [String: Any] ?? [:]
        var missing: [String: String] = [:]
        for (key, module) in importKeys {
            if let failure = object?[key] as? String { missing[module] = failure }
        }
        let rows = all.map { expectation -> Row in
            // A fact whose module never imported was not checked; it did not fail.
            let unavailable = missing.keys.contains { expectation.group.hasPrefix($0) }
            guard let entry = cases[expectation.id] as? [String: Any] else {
                return Row(expectation: expectation, actual: "not reported",
                           matches: false, unavailable: unavailable)
            }
            if let raised = entry["raised"] as? String {
                return Row(expectation: expectation, actual: "raised \(raised)",
                           matches: expectation.expect == .raises(raised),
                           unavailable: unavailable)
            }
            let value = entry["value"] as? String ?? "no value"
            return Row(expectation: expectation, actual: value,
                       matches: expectation.expect == .value(value),
                       unavailable: unavailable)
        }
        return Result(rows: rows, missingModules: missing)
    }

    public static func rows(fromProbeJSON data: Data) -> [Row] {
        result(fromProbeJSON: data).rows
    }

    /// The differences, which are the point of running this at all. A fact from
    /// a module that is not installed is not one of them.
    public static func differences(_ rows: [Row]) -> [Row] {
        rows.filter { !$0.matches && !$0.unavailable }
    }

    /// A markdown report for `library-probe.md`.
    ///
    /// Differences first and in full; matches collapsed to a count per library.
    /// A hundred green rows in a context pack is a hundred lines the model reads
    /// instead of the six that matter.
    public static func report(_ result: Result) -> String {
        let rows = result.rows
        var out = "# Library conformance · published spec versus installed\n\n"
        // Leads with what is not installed. Before the part 2 bundle arrives
        // this is the whole story, and printing eighteen NameErrors above it
        // buries the one line that explains them.
        for (module, failure) in result.missingModules.sorted(by: { $0.key < $1.key }) {
            let unchecked = rows.filter { $0.expectation.group.hasPrefix(module) }.count
            out += "**`\(module)` is not installed.** \(unchecked) documented fact(s) "
            out += "could not be checked — `\(failure)`.\n"
            if module == "sheet.formula" {
                out += "Expected before the supplied part 2 bundle is imported. "
                out += "Attach it and Prepare again.\n"
            }
            out += "\n"
        }
        let checked = rows.filter { !$0.unavailable }
        let bad = differences(rows)
        if checked.isEmpty {
            out += "Nothing else was checked.\n"
        } else if bad.isEmpty {
            out += "All \(checked.count) documented facts that could be checked hold "
            out += "on the installed libraries.\n"
        } else {
            out += "\(bad.count) of \(checked.count) checked facts do **not** hold. "
            out += "The installed library wins; each row below is a question worth asking.\n\n"
            out += "| fact | expected | actual |\n|---|---|---|\n"
            for row in bad {
                let expected: String
                switch row.expectation.expect {
                case let .value(text): expected = text
                case let .raises(error): expected = "raises \(error)"
                }
                out += "| `\(row.expectation.source)` | `\(expected)` | `\(row.actual)` |\n"
            }
        }
        out += "\n"
        for group in groups {
            let inGroup = rows.filter { $0.expectation.group == group }
            if inGroup.contains(where: \.unavailable) {
                out += "- \(group): not installed\n"
                continue
            }
            let held = inGroup.filter(\.matches).count
            out += "- \(group): \(held)/\(inGroup.count) as documented\n"
        }
        return out
    }

    /// Kept for callers that only have rows. Prefer `report(_:)`, which can say
    /// *why* a whole group is missing.
    public static func report(rows: [Row]) -> String {
        report(Result(rows: rows, missingModules: [:]))
    }
}
