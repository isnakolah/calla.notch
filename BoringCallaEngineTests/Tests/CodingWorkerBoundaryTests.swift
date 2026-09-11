import Foundation
import IntelligenceCore
import XCTest
@testable import CallaEngineValidation

final class CodingWorkerBoundaryTests: XCTestCase {
    func testReadOnlyAndCoderWriteBoundariesIncludingSourceSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coding-boundary-" + UUID().uuidString)
        let workspace = CodingWorkspace(root: root.appendingPathComponent("private"))
        let source = root.appendingPathComponent("source")
        let home = root.appendingPathComponent("home")
        for directory in [source, home, workspace.workURL, workspace.contextURL, workspace.twinURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = source.appendingPathComponent("main.py")
        try Data("original".utf8).write(to: sourceFile)
        let escape = workspace.workURL.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: sourceFile)
        func write(_ file: URL, readOnly: Bool) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", CodingAgyWorker.sandboxProfile(workspace: workspace, isolatedHome: home, readOnly: readOnly),
                                 "/bin/sh", "-c", "echo changed > \"$1\"", "boundary-test", file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
        XCTAssertNotEqual(try write(sourceFile, readOnly: false), 0)
        XCTAssertNotEqual(try write(escape, readOnly: false), 0)
        XCTAssertNotEqual(try write(workspace.contextURL.appendingPathComponent("facts"), readOnly: false), 0)
        XCTAssertNotEqual(try write(workspace.workURL.appendingPathComponent("proposal"), readOnly: true), 0)
        XCTAssertEqual(try write(workspace.workURL.appendingPathComponent("proposal"), readOnly: false), 0)
        XCTAssertEqual(try String(contentsOf: sourceFile), "original")
    }
}
