import Foundation
import Testing
@testable import CallaEngineValidation

/// Preparation copies the *repository*, because material intake needs the git
/// root — `git clone` refuses a subdirectory outright. The Python package is
/// somewhere inside it, and for this interview it is one level down.
struct WavePythonRootTests {
    /// Resolved, because `/var` is a symlink to `/private/var` on macOS and
    /// directory enumeration hands back the resolved form.
    private func makeTree(_ paths: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("python-root-\(UUID().uuidString)", isDirectory: true)
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        return root
    }

    @Test func theRootWinsWhenThePackageIsThere() throws {
        let root = try makeTree(["sheet/__init__.py", "requirements.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CodingSessionController.pythonRoot(in: root) == root)
    }

    @Test func aPackageOneLevelDownIsFound() throws {
        // The actual layout: repo root holds README, examples, javascript and
        // python; only `python/` is importable.
        let root = try makeTree(["README.md", "examples/1-basic.csv",
                                 "javascript/index.js",
                                 "python/sheet/__init__.py",
                                 "python/requirements-dev.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CodingSessionController.pythonRoot(in: root)
                == root.appendingPathComponent("python"))
    }

    @Test func aProjectFileAloneIsEnough() throws {
        let root = try makeTree(["docs/notes.md", "service/pyproject.toml"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CodingSessionController.pythonRoot(in: root)
                == root.appendingPathComponent("service"))
    }

    @Test func aTreeWithNoPythonFallsBackToTheRoot() throws {
        // Never wander: an unrecognised tree prepares where it always did.
        let root = try makeTree(["README.md", "src/main.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CodingSessionController.pythonRoot(in: root) == root)
    }

    @Test func theChoiceIsStableAcrossRuns() throws {
        // Two candidates, and the answer must not depend on directory order.
        let root = try makeTree(["alpha/setup.py", "beta/pyproject.toml"])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = CodingSessionController.pythonRoot(in: root)
        for _ in 0..<5 { #expect(CodingSessionController.pythonRoot(in: root) == first) }
        #expect(first == root.appendingPathComponent("alpha"))
    }

    @Test func theReportNamesTheSubdirectoryRelatively() throws {
        let root = URL(fileURLWithPath: "/tmp/repo")
        #expect(CodingSessionController.relativePath(root.appendingPathComponent("python"),
                                                    under: root) == "python")
    }
}
