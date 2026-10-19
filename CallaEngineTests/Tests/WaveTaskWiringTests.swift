import CallaContracts
import Foundation
import Testing
@testable import CallaEngineValidation

/// The six tasks, and whether each one's acceptance actually reaches the model.
struct WaveTaskAcceptanceTests {
    @Test func everyLadderTaskResolvesItsOwnChecks() {
        // Keyed on the pending item's id, which is the ladder id verbatim.
        for entry in WaveInterviewState.ladder {
            let resolved = CodingSessionController.checks(forPendingID: entry.id)
            #expect(resolved == entry.checks, "\(entry.id) resolved the wrong list")
            #expect(!resolved.isEmpty)
        }
    }

    /// The bug this replaces: the checks came from the ladder *cursor*, which
    /// never moves, so every task after the first was given the cell-reference
    /// list while being told to code something else.
    @Test func laterTasksDoNotInheritTheFirstTasksChecks() {
        let references = CodingSessionController.checks(forPendingID: "references")
        for id in ["literals", "numeric", "sum", "dates", "sqrt"] {
            #expect(CodingSessionController.checks(forPendingID: id) != references,
                    "\(id) still resolves the references checks")
        }
    }

    @Test func acceptanceNamesTheTasksOwnCases() {
        let sum = CodingSessionController.acceptance(forPendingID: "sum")
        #expect(sum.contains("SUM in capitals"))
        #expect(sum.contains("not deduplicated"))
        // And not another task's.
        #expect(!sum.contains("neither hangs nor crashes"))

        let dates = CodingSessionController.acceptance(forPendingID: "dates")
        #expect(dates.contains("date + date rejected"))
        #expect(!dates.contains("SUM in capitals"))
    }

    @Test func anUnknownPendingIDContributesNothingRatherThanTheWrongThing() {
        // The generic seed is `basic`, which is not a ladder task.
        #expect(CodingSessionController.checks(forPendingID: "basic").isEmpty)
        #expect(CodingSessionController.acceptance(forPendingID: "basic").isEmpty)
        #expect(CodingSessionController.acceptanceSuffix(forPendingID: "basic").isEmpty)
    }
}

/// A check has to run where the package is, or no task can ever be evidenced.
struct WaveCheckDirectoryTests {
    private func tree(_ paths: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("check-cwd-\(UUID().uuidString)", isDirectory: true)
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        return root
    }

    @Test func aSubdirectoryProjectSuppliesTheWorkingDirectory() throws {
        // This interview's shape: the repo root for git, the package one down.
        let root = try tree(["Makefile", "examples/1.csv",
                             "python/sheet/__init__.py", "python/requirements-dev.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        let resolved = CodingSessionController.pythonRoot(in: root)
        #expect(resolved == root.appendingPathComponent("python"))
        #expect(CodingSessionController.relativePath(resolved, under: root) == "python")
    }

    @Test func aRootLevelProjectNeedsNoWorkingDirectory() throws {
        let root = try tree(["sheet/__init__.py", "pyproject.toml"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CodingSessionController.pythonRoot(in: root) == root)
    }
}

/// The first check offered has to be one this project can actually run.
struct WaveSuggestedCommandTests {
    private func manifest(_ paths: [String]) -> CodingSnapshotManifest {
        CodingSnapshotManifest(
            revision: "r",
            entries: paths.map { .init(path: $0, kind: "file", size: 0, digest: "d") },
            withheld: [], externalSymlinks: [], totalBytes: 0)
    }

    @Test func aPythonProjectOneLevelDownIsOffered() {
        // Previously matched nothing at all: no root-level pyproject.toml, so
        // the session opened with no runnable check.
        let plans = CodingShadowProject.suggestedCommands(
            manifest(["Makefile", "python/pytest.ini", "python/sheet/engine.py"]))
        let pytest = plans.first { $0.displayedCommand.contains("pytest") }
        #expect(pytest?.relativeCWD == "python")
    }

    @Test func aMakefileTargetIsOfferedOnlyOnce() {
        let plans = CodingShadowProject.suggestedCommands(manifest(["Makefile"]))
        #expect(plans.filter { $0.displayedCommand.hasPrefix("make ") }.count == 1)
    }

    @Test func aTreeWithNothingRecognisableOffersNothing() {
        #expect(CodingShadowProject.suggestedCommands(manifest(["README.md"])).isEmpty)
    }
}

/// The map the model reads instead of rediscovering the project live.
struct WaveProjectMapTests {
    @Test func theMapNamesModulesTheirExportsAndTheirPrivateHelpers() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("map-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("python/sheet")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try """
        __all__ = ["Spreadsheet"]


        class Spreadsheet:
            def get_formatted(self, index: Index) -> str:
                return ""

            def _evaluate(self, index: Index, visited: FrozenSet[Index]) -> CellValue:
                return None
        """.write(to: package.appendingPathComponent("engine.py"), atomically: true, encoding: .utf8)

        let map = CodingSessionController.projectMap(
            root: root.appendingPathComponent("python"), workRoot: root)
        #expect(map.contains("Python package root: `python`"))
        #expect(map.contains("`__all__ = [\"Spreadsheet\"]`"))
        #expect(map.contains("class Spreadsheet"))
        #expect(map.contains("def get_formatted(self, index: Index) -> str"))
        // The private helper is the whole point: a step has to name it.
        #expect(map.contains("def _evaluate(self, index: Index, visited: FrozenSet[Index]) -> CellValue"))
        // Signatures only — never a body, because this runs against a tree that
        // may already contain part-2 work.
        #expect(!map.contains("return \"\""))
        #expect(!map.contains("return None"))
    }

    @Test func aTreeWithNoPackageSaysSoRatherThanInventingOne() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let map = CodingSessionController.projectMap(root: root, workRoot: root)
        #expect(map.contains("No `sheet` package found."))
    }
}
