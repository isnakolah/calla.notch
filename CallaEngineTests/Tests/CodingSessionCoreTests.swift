import Foundation
import XCTest
import CallaContracts
@testable import CallaEngineValidation

final class CodingSessionCoreTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("coding-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testMirrorIncludesSavedAndUntrackedFilesButWithholdsSecretsAndVCS() throws {
        let source = scratch.appendingPathComponent("source")
        let mirror = scratch.appendingPathComponent("mirror")
        let work = scratch.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: source.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("tracked".utf8).write(to: source.appendingPathComponent("main.swift"))
        try Data("untracked".utf8).write(to: source.appendingPathComponent("notes.txt"))
        try Data("secret".utf8).write(to: source.appendingPathComponent(".env"))
        try Data("safe".utf8).write(to: source.appendingPathComponent(".env.example"))
        try Data("git".utf8).write(to: source.appendingPathComponent(".git/config"))

        let manifest = try CodingShadowProject.prepare(source: source, mirror: mirror, work: work)

        XCTAssertTrue(FileManager.default.fileExists(atPath: mirror.appendingPathComponent("main.swift").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("notes.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirror.appendingPathComponent(".env.example").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.appendingPathComponent(".env").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.appendingPathComponent(".git").path))
        XCTAssertTrue(manifest.withheld.contains(".env"))
    }

    func testExternalSymlinkIsWithheldAndInternalSymlinkIsPreserved() throws {
        let source = scratch.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: source.appendingPathComponent("inside.txt"))
        try Data("outside".utf8).write(to: scratch.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("inside-link"), withDestinationURL: source.appendingPathComponent("inside.txt"))
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("outside-link"), withDestinationURL: scratch.appendingPathComponent("outside"))

        let mirror = scratch.appendingPathComponent("mirror")
        let work = scratch.appendingPathComponent("work")
        let manifest = try CodingShadowProject.prepare(source: source, mirror: mirror, work: work)
        XCTAssertTrue(manifest.externalSymlinks.contains("outside-link"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.appendingPathComponent("outside-link").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: mirror.appendingPathComponent("inside-link").path), mirror.appendingPathComponent("inside.txt").path)
    }

    func testDigestChangesWhenSavedContentChanges() throws {
        let source = scratch.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("main.py")
        try Data("one".utf8).write(to: file)
        let first = try CodingShadowProject.inspect(source: source)
        try Data("two".utf8).write(to: file, options: .atomic)
        let second = try CodingShadowProject.inspect(source: source)
        XCTAssertNotEqual(first.revision, second.revision)
        XCTAssertEqual(CodingShadowProject.detectedLanguages(second), ["Python"])
    }

    func testRunnerPolicyRejectsEscapesAndPrivilegedTools() throws {
        let work = scratch.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        XCTAssertNoThrow(try CodingCommandPolicy.validate(command: "swift test", relativeCWD: ".", work: work))
        XCTAssertThrowsError(try CodingCommandPolicy.validate(command: "sudo make install", relativeCWD: ".", work: work))
        XCTAssertThrowsError(try CodingCommandPolicy.validate(command: "pwd", relativeCWD: "../source", work: work))
    }

    func testMentioningACommandDoesNotExecuteIt() {
        for text in ["How do I run the tests?", "I already run the tests.",
                     "She asked me to run the tests.", "I don't want to run the tests.",
                     "I said stop that earlier."] {
            XCTAssertEqual(CodingCueClassifier.classify(text: text, speaker: .me,
                confidence: 1, hasPendingRun: true, runActive: true), .steer, text)
        }
        XCTAssertEqual(CodingCueClassifier.classify(text: "Okay, let’s run the tests.",
            speaker: .me, confidence: 1, hasPendingRun: true, runActive: false), .run)
    }

    func testOnlyCandidateHighConfidenceCueRuns() {
        XCTAssertEqual(CodingCueClassifier.classify(text: "let me run it", speaker: .me,
                                                    confidence: 0.95, hasPendingRun: true, runActive: false), .run)
        XCTAssertEqual(CodingCueClassifier.classify(text: "let me run it", speaker: .them,
                                                    confidence: 0.99, hasPendingRun: true, runActive: false), .steer)
        XCTAssertEqual(CodingCueClassifier.classify(text: "let me run it", speaker: .me,
                                                    confidence: 0.5, hasPendingRun: true, runActive: false), .illuminateRun)
        XCTAssertEqual(CodingCueClassifier.classify(text: "don't run it", speaker: .me,
                                                    confidence: 0.99, hasPendingRun: true, runActive: false), .steer)
        XCTAssertEqual(CodingCueClassifier.classify(text: "stop that", speaker: .me,
                                                    confidence: 0.9, hasPendingRun: false, runActive: true), .cancel)
    }

    func testReconcileRetainsCompatibleExperiment() throws {
        let source = scratch.appendingPathComponent("source")
        let mirror = scratch.appendingPathComponent("mirror")
        let work = scratch.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("one\ntwo\nthree\n".utf8).write(to: source.appendingPathComponent("value.txt"))
        _ = try CodingShadowProject.prepare(source: source, mirror: mirror, work: work)
        try Data("agent\ntwo\nthree\n".utf8).write(to: work.appendingPathComponent("value.txt"))
        try Data("one\ntwo\ncandidate\n".utf8).write(to: source.appendingPathComponent("value.txt"))

        let result = try CodingShadowProject.reconcile(source: source, mirror: mirror, work: work)

        XCTAssertEqual(result.outcome, .retainedExperiments)
        XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("value.txt")),
                       "agent\ntwo\ncandidate\n")
    }

    func testReconcileResetsOnConflictingHunk() throws {
        let source = scratch.appendingPathComponent("source")
        let mirror = scratch.appendingPathComponent("mirror")
        let work = scratch.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("base\n".utf8).write(to: source.appendingPathComponent("value.txt"))
        _ = try CodingShadowProject.prepare(source: source, mirror: mirror, work: work)
        try Data("agent\n".utf8).write(to: work.appendingPathComponent("value.txt"))
        try Data("candidate\n".utf8).write(to: source.appendingPathComponent("value.txt"))

        let result = try CodingShadowProject.reconcile(source: source, mirror: mirror, work: work)

        XCTAssertEqual(result.outcome, .conflict)
        XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("value.txt")), "candidate\n")
    }
}

/// The bug that stopped Live Coding from ever starting.
///
/// The app is sandboxed and mints a security-scoped bookmark; the engine that
/// resolves it is not sandboxed. `.withSecurityScope` from an unsandboxed
/// process fails outright rather than degrading, and the notch reported it as
/// "The project folder could not be prepared".
final class CodingFolderBookmarkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coding-bookmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAPlainBookmarkResolvesToItsFolder() throws {
        let bookmark = try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                  relativeTo: nil)
        let resolved = try CodingFolderBookmark.resolve(bookmark)
        XCTAssertEqual(resolved.url.resolvingSymlinksInPath().standardizedFileURL,
                       directory.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: resolved.url.path))
    }

    /// This test process is unsandboxed, exactly like the engine — so a resolve
    /// that insists on security scope is the failure being guarded against.
    func testSecurityScopeAloneFailsInAnUnsandboxedProcessButResolveStillSucceeds() throws {
        let bookmark = try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                  relativeTo: nil)
        var stale = false
        XCTAssertThrowsError(
            try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                    relativeTo: nil, bookmarkDataIsStale: &stale),
            "if this ever stops throwing, the fallback is no longer load-bearing")
        XCTAssertNoThrow(try CodingFolderBookmark.resolve(bookmark))
    }

    func testGarbageIsStillAnError() {
        XCTAssertThrowsError(try CodingFolderBookmark.resolve(Data("not a bookmark".utf8)))
    }
}

final class CodingRevisionStabilityTests: XCTestCase {
    func testPrivateCopiesPreserveRevisionForInternalAbsoluteSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("value".utf8).write(to: source.appendingPathComponent("main.py"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link.py"), withDestinationURL: source.appendingPathComponent("main.py"))
        let mirror = root.appendingPathComponent("mirror"), work = root.appendingPathComponent("work")
        let manifest = try CodingShadowProject.prepare(source: source, mirror: mirror, work: work)
        XCTAssertEqual(try CodingShadowProject.inspect(source: mirror).revision, manifest.revision)
        XCTAssertEqual(try CodingShadowProject.inspect(source: work).revision, manifest.revision)
    }

    func testUnchangedSavedFilesHaveStableRevisionAcrossInspections() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for i in 0..<10 { try Data("value \(i)".utf8).write(to: folder.appendingPathComponent("file\(i).py")) }
        let first = try CodingShadowProject.inspect(source: folder)
        for _ in 0..<20 { XCTAssertEqual(try CodingShadowProject.inspect(source: folder).revision, first.revision) }
    }
}
